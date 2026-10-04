import Flutter
import StoreKit

/// StoreKit 2 service for voluntary, repeatable consumable tips.
@MainActor
final class DeveloperTipPurchase {
  private struct Tip {
    let id: String
  }

  private static let tips = [
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.small"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.medium"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.large"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.xlarge"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.premium"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.strong"),
  ]
  private static let deliveredKey = "developer_tip.delivered_transaction_ids"

  private let channel: FlutterMethodChannel
  private var products: [String: Product] = [:]
  private var revision = 0
  private var messageCode: String?
  private var celebration: [String: String]?
  private var operationInProgress = false
  private var updatesTask: Task<Void, Never>?
  private var unfinishedTask: Task<Void, Never>?

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
    unfinishedTask = Task { [weak self] in
      for await value in StoreKit.Transaction.unfinished {
        if Task.isCancelled { return }
        await self?.receive(value)
      }
    }
  }

  private func snapshot() -> [String: Any] {
    let listed = Self.tips.compactMap { tip -> [String: String]? in
      guard let product = products[tip.id] else { return nil }
      return ["id": tip.id, "name": product.displayName, "price": product.displayPrice]
    }
    var state: [String: Any] = [
      "revision": revision,
      "canPay": AppStore.canMakePayments,
      "products": listed,
    ]
    if let messageCode { state["messageCode"] = messageCode }
    if let celebration { state["celebration"] = celebration }
    return state
  }

  private func publish() {
    revision += 1
    channel.invokeMethod("state", arguments: snapshot())
  }

  private func isTip(_ transaction: StoreKit.Transaction) -> Bool {
    Self.tips.contains(where: { $0.id == transaction.productID })
      && transaction.productType == .consumable
  }

  private func deliveredIDs() -> Set<String> {
    Set(UserDefaults.standard.stringArray(forKey: Self.deliveredKey) ?? [])
  }

  private func recordDelivery(_ id: UInt64) -> Bool {
    var ids = deliveredIDs()
    guard ids.insert(String(id)).inserted else { return false }
    UserDefaults.standard.set(Array(ids.suffix(512)), forKey: Self.deliveredKey)
    return true
  }

  private func receive(_ value: VerificationResult<StoreKit.Transaction>) async {
    switch value {
    case .verified(let transaction):
      guard isTip(transaction) else { return }
      messageCode = nil
      if recordDelivery(transaction.id) {
        celebration = [
          "productId": transaction.productID,
          "transactionId": String(transaction.id),
        ]
        publish()
      }
      await transaction.finish()
    case .unverified(let transaction, _):
      guard isTip(transaction) else { return }
      messageCode = "purchase_verification_failed"
      publish()
    }
  }

  private func loadProducts() async throws {
    let requested = try await Product.products(for: Self.tips.map(\.id))
    products = Dictionary(uniqueKeysWithValues: requested.compactMap { product in
      guard Self.tips.contains(where: { $0.id == product.id }), product.type == .consumable else {
        return nil
      }
      return (product.id, product)
    })
    if products.isEmpty {
      messageCode = "purchase_products_unavailable"
    } else if !AppStore.canMakePayments {
      messageCode = "purchase_restricted"
    } else {
      messageCode = nil
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    switch call.method {
    case "refresh":
      result(snapshot())
    case "loadProducts":
      do {
        celebration = nil
        try await loadProducts()
        publish()
        result(snapshot())
      } catch {
        products = [:]
        messageCode = "purchase_products_load_failed"
        publish()
        result(FlutterError(
          code: "purchase_products_load_failed",
          message: nil,
          details: ["technicalDetail": String(describing: error)]))
      }
    case "purchase":
      guard !operationInProgress else {
        result(FlutterError(code: "purchase_busy", message: nil, details: nil))
        return
      }
      guard let id = call.arguments as? String,
        let product = products[id],
        Self.tips.contains(where: { $0.id == id }) else {
        result(FlutterError(code: "purchase_product_invalid", message: nil, details: nil))
        return
      }
      guard AppStore.canMakePayments else {
        result(FlutterError(code: "purchase_restricted", message: nil, details: nil))
        return
      }
      operationInProgress = true
      defer { operationInProgress = false }
      messageCode = nil
      celebration = nil
      do {
        switch try await product.purchase() {
        case .success(let value): await receive(value)
        case .pending: messageCode = "purchase_pending"
        case .userCancelled: messageCode = "purchase_cancelled"
        @unknown default: messageCode = "purchase_incomplete"
        }
        publish()
        result(snapshot())
      } catch {
        messageCode = "purchase_failed"
        publish()
        result(FlutterError(
          code: "purchase_failed",
          message: nil,
          details: ["technicalDetail": String(describing: error)]))
      }
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  deinit {
    updatesTask?.cancel()
    unfinishedTask?.cancel()
  }
}
