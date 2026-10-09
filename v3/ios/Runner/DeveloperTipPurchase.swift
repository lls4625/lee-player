import Flutter
import StoreKit
import UIKit

/// All file mutations are serialized here without suspension between read and write.
private actor TipLedger {
  struct Entry: Codable, Sendable {
    var productId: String
    var created: Double
    var presentation: String
    var page: String?
    var requestId: String?
    var finished = false
  }
  struct Request: Codable, Sendable {
    var productId: String
    var status: String
  }
  private struct Document: Codable {
    var version = 1
    var transactions: [String: Entry] = [:]
    var requests: [String: Request] = [:]
  }
  enum Failure: Error { case corrupt, missing }
  private var document: Document?
  private var loadedOnce = false
  private var committedData: Data?
  private var generation = 0

  private func location() throws -> URL {
    let root = try FileManager.default.url(for: .applicationSupportDirectory,
      in: .userDomainMask, appropriateFor: nil, create: true)
    return root.appendingPathComponent("developer-tip-ledger-v1.json")
  }

  private func save(_ next: Document) throws {
    let url = try location()
    if let committedData {
      // Do not overwrite externally removed, truncated or rolled-back records.
      do {
        guard try Data(contentsOf: url) == committedData else { throw Failure.corrupt }
      } catch let error as NSError where error.domain == NSCocoaErrorDomain
        && error.code == NSFileReadNoSuchFileError {
        throw Failure.missing
      }
    }
    let data = try JSONEncoder().encode(next)
    try data.write(to: url, options: .atomic)
    committedData = data
    document = next
    generation += 1
    loadedOnce = true
  }

  func load() throws {
    if document != nil { return }
    let url = try location()
    let data: Data
    do {
      data = try Data(contentsOf: url)
    } catch let error as NSError where error.domain == NSCocoaErrorDomain
      && error.code == NSFileReadNoSuchFileError {
      guard !loadedOnce,
        !UserDefaults.standard.bool(forKey: "developer_tip.ledger_created") else {
        throw Failure.missing
      }
      var migrated = Document()
      for id in UserDefaults.standard.stringArray(
        forKey: "developer_tip.delivered_transaction_ids") ?? [] {
        migrated.transactions[id] = Entry(productId: "", created: 0,
          presentation: "legacyConsumed", page: nil)
      }
      try save(migrated)
      UserDefaults.standard.set(true, forKey: "developer_tip.ledger_created")
      return
    }
    var decoded: Document
    do {
      decoded = try JSONDecoder().decode(Document.self, from: data)
      guard decoded.version == 1,
        decoded.transactions.values.allSatisfy({
          ["pending", "claimed", "legacyConsumed", "suppressed"].contains($0.presentation)
        }) else { throw Failure.corrupt }
    } catch { throw Failure.corrupt }
    // Page sessions and active calls cannot survive a cold start.
    for id in Array(decoded.transactions.keys) { decoded.transactions[id]?.page = nil }
    for id in Array(decoded.requests.keys) where decoded.requests[id]?.status == "purchasing" {
      decoded.requests[id]?.status = "unresolved"
    }
    try save(decoded)
    UserDefaults.standard.set(true, forKey: "developer_tip.ledger_created")
  }

  private func current() throws -> Document {
    try load()
    guard let document else { throw Failure.corrupt }
    return document
  }

  func acceptRequest(_ id: String, product: String) throws -> Bool {
    var next = try current()
    if next.requests[id] != nil { return false }
    next.requests[id] = Request(productId: product, status: "purchasing")
    try save(next)
    return true
  }

  func requestResult(_ id: String, status: String) throws {
    var next = try current()
    if let transaction = next.transactions.values.first(where: { $0.requestId == id }) {
      next.requests[id]?.status = transaction.presentation == "suppressed" ? "unresolved" : "succeeded"
    } else {
      next.requests[id]?.status = status
    }
    try save(next)
  }

  func requestSnapshot() throws -> (Int, [String: Request]) {
    let value = try current()
    return (generation, value.requests)
  }

  func record(_ id: String, product: String, page: String?, revoked: Bool,
              request: String?) throws {
    var next = try current()
    if next.transactions[id] == nil {
      next.transactions[id] = Entry(productId: product,
        created: Date().timeIntervalSince1970,
        presentation: revoked ? "suppressed" : "pending", page: page)
    }
    if revoked { next.transactions[id]?.presentation = "suppressed" }
    if let request { next.transactions[id]?.requestId = request }
    let associatedRequest = request ?? next.transactions[id]?.requestId
    if let associatedRequest {
      next.requests[associatedRequest]?.status =
        next.transactions[id]?.presentation == "suppressed" ? "unresolved" : "succeeded"
    }
    if associatedRequest == nil && !revoked {
      for key in Array(next.requests.keys) where next.requests[key]?.status == "awaitingApproval"
        && next.requests[key]?.productId == product {
        next.requests[key]?.status = "unresolved"
      }
    }
    try save(next)
  }

  func finishObserved(_ id: String) throws {
    var next = try current()
    next.transactions[id]?.finished = true
    try save(next)
  }

  func pending() throws -> [(String, Entry)] {
    try current().transactions.filter { $0.value.presentation == "pending" }
      .sorted { $0.value.created == $1.value.created
        ? $0.key < $1.key : $0.value.created < $1.value.created }
      .map { ($0.key, $0.value) }
  }

  func claim(_ id: String) throws -> Entry? {
    var next = try current()
    guard let entry = next.transactions[id], entry.presentation == "pending" else { return nil }
    next.transactions[id]?.presentation = "claimed"
    try save(next)
    return entry
  }

  func retirePage(_ page: String) throws {
    var next = try current()
    var changed = false
    for id in Array(next.transactions.keys) where next.transactions[id]?.page == page {
      next.transactions[id]?.page = nil
      changed = true
    }
    if changed { try save(next) }
  }

  // Exercises an actual atomic write before allowing payments again after an I/O error.
  func recover() throws {
    let next = try current()
    try save(next)
  }
}

@MainActor
final class DeveloperTipPurchase {
  private static let ids = ["small", "medium", "large", "xlarge", "premium", "strong"]
    .map { "vip.ichiki.javalee.leeplayer.tip.\($0)" }
  private let channel: FlutterMethodChannel
  private let ledger = TipLedger()
  private let instance = UUID().uuidString
  private var products: [String: Product] = [:]
  private var revision = 0
  private var storage = "initializing"
  private var lastStorageDiagnostic: String?
  private var catalogError: String?
  private var verificationPending = false
  private var operationInProgress = false
  private var page: String?
  private var pageToken: String?
  private var pageClient: String?
  private var retiredPageClients: Set<String> = []
  private var pageSequence = -1
  private var requests: [String: TipLedger.Request] = [:]
  private var requestGeneration = -1
  private var recoveryTask: Task<Void, Never>?
  private var updatesTask: Task<Void, Never>?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "lei.player/developer_tip", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      Task { @MainActor [weak self] in
        guard let self else {
          result(FlutterError(code: "purchase_service_unavailable", message: nil, details: nil))
          return
        }
        await self.handle(call, result: result)
      }
    }
    updatesTask = Task { [weak self] in
      for await value in StoreKit.Transaction.updates {
        if Task.isCancelled { return }
        await self?.receive(value)
      }
    }
    recover(coldStart: true)
  }

  private func snapshot() -> [String: Any] {
    var state: [String: Any] = [
      "serviceInstanceId": instance, "revision": revision,
      "canPay": AppStore.canMakePayments, "storage": storage,
      "busy": operationInProgress,
      "products": Self.ids.compactMap { id -> [String: String]? in
        guard let product = products[id] else { return nil }
        return ["id": id, "name": product.displayName, "price": product.displayPrice]
      },
      "hasUnresolved": verificationPending || requests.values.contains {
        ["purchasing", "awaitingApproval", "unresolved"].contains($0.status)
      },
      "awaitingApproval": requests.values.contains { $0.status == "awaitingApproval" },
      "requestStates": requests.mapValues { $0.status },
    ]
    if let catalogError { state["messageCode"] = catalogError }
    if verificationPending { state["messageCode"] = "purchase_verification_failed" }
    return state
  }

  private func publish() {
    revision += 1
    channel.invokeMethod("state", arguments: snapshot())
  }

  private func storageFailure(_ error: Error) {
    storage = error is TipLedger.Failure ? "corrupted" : "temporarilyUnavailable"
    let nativeError = error as NSError
    let diagnostic = "\(nativeError.domain):\(nativeError.code)"
    if diagnostic != lastStorageDiagnostic {
      NSLog("Developer tip ledger v1 error: %@", diagnostic)
      lastStorageDiagnostic = diagnostic
    }
    publish()
  }

  private func refreshRequests() async throws {
    let (generation, value) = try await ledger.requestSnapshot()
    guard generation >= requestGeneration else { return }
    requestGeneration = generation
    requests = value
  }

  private func recover(coldStart: Bool = false) {
    guard recoveryTask == nil else { return }
    recoveryTask = Task { [weak self] in
      guard let self else { return }
      defer { self.recoveryTask = nil }
      do {
        try await self.ledger.recover()
        try await self.refreshRequests()
        self.storage = "healthy"
        self.publish()
        for await value in StoreKit.Transaction.unfinished {
          if Task.isCancelled { return }
          await self.receive(value, recovery: coldStart)
        }
        self.channel.invokeMethod("feedbackAvailable", arguments: nil)
      } catch { self.storageFailure(error) }
    }
  }

  private func receive(_ value: VerificationResult<StoreKit.Transaction>,
                       request: String? = nil, recovery: Bool = false) async {
    switch value {
    case .verified(let transaction):
      guard Self.ids.contains(transaction.productID), transaction.productType == .consumable else { return }
      let revoked = transaction.revocationDate != nil
      let visiblePage = !recovery && UIApplication.shared.applicationState != .background ? pageToken : nil
      do {
        try await ledger.record(String(transaction.id), product: transaction.productID,
          page: visiblePage, revoked: revoked, request: request)
        try await refreshRequests()
        storage = "healthy"
        verificationPending = false
        if revoked { channel.invokeMethod("feedbackRevoked", arguments: String(transaction.id)) }
        publish()
        await transaction.finish()
        try await ledger.finishObserved(String(transaction.id))
        channel.invokeMethod("feedbackAvailable", arguments: nil)
      } catch { storageFailure(error) }
    case .unverified(let transaction, _):
      guard Self.ids.contains(transaction.productID), transaction.productType == .consumable else { return }
      verificationPending = true
      if let request {
        do {
          try await ledger.requestResult(request, status: "unresolved")
          try await refreshRequests()
        } catch { storageFailure(error) }
      }
      publish()
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    do {
      switch call.method {
      case "refresh":
        // Payment restrictions may have changed outside the app.
        publish()
        result(snapshot())
      case "reconcile":
        recover()
        await recoveryTask?.value
        result(snapshot())
      case "setPage":
        guard let args = call.arguments as? [String: Any],
          let client = args["client"] as? String,
          let sequence = args["sequence"] as? Int,
          !retiredPageClients.contains(client) else { result(nil); return }
        if client != pageClient {
          if let pageClient { retiredPageClients.insert(pageClient) }
          pageClient = client
          pageSequence = -1
        }
        guard sequence > pageSequence else { result(nil); return }
        pageSequence = sequence
        let previous = page
        let previousToken = pageToken
        page = args["page"] as? String
        if previous != page {
          pageToken = page == nil ? nil : UUID().uuidString
          if let previousToken { try await ledger.retirePage(previousToken) }
        }
        result(nil)
      case "listPendingFeedback":
        guard storage == "healthy" else { result([]); return }
        let pending = try await ledger.pending()
        result(pending.map { ["transactionId": $0.0] })
      case "claimFeedback":
        guard storage == "healthy", UIApplication.shared.applicationState == .active,
          let args = call.arguments as? [String: Any], let id = args["transactionId"] as? String else {
          result(nil); return
        }
        let consumerPage = args["page"] as? String
        let currentPage = page
        let currentToken = pageToken
        guard let entry = try await ledger.claim(id) else { result(nil); return }
        result(["transactionId": id, "productId": entry.productId,
          "animated": entry.page != nil && entry.page == currentToken
            && consumerPage != nil && consumerPage == currentPage])
      case "loadProducts":
        do {
          let listed = try await Product.products(for: Self.ids)
          products = Dictionary(uniqueKeysWithValues: listed.filter {
            Self.ids.contains($0.id) && $0.type == .consumable
          }.map { ($0.id, $0) })
          catalogError = products.isEmpty ? "purchase_products_unavailable" : nil
        } catch { catalogError = "purchase_products_load_failed" }
        publish()
        result(snapshot())
      case "purchase":
        guard storage == "healthy", !operationInProgress else {
          result(FlutterError(code: storage == "healthy" ? "purchase_busy" : "tip_storage_error",
            message: nil, details: nil)); return
        }
        guard let args = call.arguments as? [String: Any],
          let id = args["productId"] as? String, let request = args["requestId"] as? String,
          let product = products[id], !request.isEmpty else {
          result(FlutterError(code: "purchase_product_invalid", message: nil, details: nil)); return
        }
        guard AppStore.canMakePayments else {
          result(FlutterError(code: "purchase_restricted", message: nil, details: nil)); return
        }
        operationInProgress = true
        publish()
        defer { operationInProgress = false; publish() }
        guard try await ledger.acceptRequest(request, product: id) else {
          result(snapshot()); return
        }
        try await refreshRequests()
        var outcome = "unresolved"
        do {
          switch try await product.purchase() {
          case .success(let verification):
            await receive(verification, request: request)
            outcome = requests[request]?.status == "succeeded" ? "succeeded" : "unresolved"
          case .pending: outcome = "awaitingApproval"
          case .userCancelled: outcome = "cancelled"
          @unknown default: outcome = "unresolved"
          }
        } catch {
          // Failure to return a result is not proof that no payment happened.
          outcome = "unresolved"
        }
        try await ledger.requestResult(request, status: outcome)
        try await refreshRequests()
        operationInProgress = false
        publish()
        var response = snapshot()
        response["outcome"] = outcome
        result(response)
      default: result(FlutterMethodNotImplemented)
      }
    } catch {
      storageFailure(error)
      result(FlutterError(code: "tip_storage_error", message: nil, details: nil))
    }
  }

  deinit { updatesTask?.cancel(); recoveryTask?.cancel() }
}
