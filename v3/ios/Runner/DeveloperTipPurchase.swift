import Flutter
import StoreKit

/// StoreKit 2 service for voluntary, repeatable consumable tips.
@MainActor
final class DeveloperTipPurchase {
  private struct Tip {
    let id: String
    let name: String
  }

  private static let tips = [
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.small", name: "一份鼓励"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.medium", name: "暖心支持"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.large", name: "特别支持"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.xlarge", name: "大力支持"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.premium", name: "顶级鼓励"),
    Tip(id: "vip.ichiki.javalee.leeplayer.tip.strong", name: "夯"),
  ]
  private static let deliveredKey = "developer_tip.delivered_transaction_ids"

  private let channel: FlutterMethodChannel
  private var products: [String: Product] = [:]
  private var revision = 0
  private var message: String?
  private var thanks: String?
  private var celebration: [String: String]?
  private var operationInProgress = false
  private var updatesTask: Task<Void, Never>?
  private var unfinishedTask: Task<Void, Never>?

  init(messenger: FlutterBinaryMessenger) {
    channel = FlutterMethodChannel(name: "lei.player/developer_tip", binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      Task { @MainActor [weak self] in
        guard let self else {
          result(FlutterError(code: "unavailable", message: "打赏服务暂不可用", details: nil))
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
    if let message { state["message"] = message }
    if let thanks { state["thanks"] = thanks }
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
      message = nil
      if recordDelivery(transaction.id) {
        let name = Self.tips.first(where: { $0.id == transaction.productID })?.name ?? "支持"
        thanks = "感谢你的「\(name)」！"
        celebration = [
          "productId": transaction.productID,
          "transactionId": String(transaction.id),
        ]
        publish()
      }
      await transaction.finish()
    case .unverified(let transaction, _):
      guard isTip(transaction) else { return }
      message = "购买验证失败，请稍后重试"
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
      message = "商品暂不可用，请稍后重新加载"
    } else if !AppStore.canMakePayments {
      message = "当前设备不允许购买"
    } else {
      message = nil
    }
  }

  private func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) async {
    switch call.method {
    case "refresh":
      result(snapshot())
    case "loadProducts":
      do {
        thanks = nil
        celebration = nil
        try await loadProducts()
        publish()
        result(snapshot())
      } catch {
        products = [:]
        message = "商品加载失败，请检查网络后重试"
        publish()
        result(FlutterError(code: "products", message: message, details: String(describing: error)))
      }
    case "purchase":
      guard !operationInProgress else {
        result(FlutterError(code: "busy", message: "正在处理购买，请稍候", details: nil))
        return
      }
      guard let id = call.arguments as? String,
        let product = products[id],
        Self.tips.contains(where: { $0.id == id }) else {
        result(FlutterError(code: "product", message: "请先重新加载商品", details: nil))
        return
      }
      guard AppStore.canMakePayments else {
        result(FlutterError(code: "restricted", message: "当前设备不允许购买", details: nil))
        return
      }
      operationInProgress = true
      defer { operationInProgress = false }
      message = nil
      thanks = nil
      celebration = nil
      do {
        switch try await product.purchase() {
        case .success(let value): await receive(value)
        case .pending: message = "购买待批准，批准后会自动完成感谢"
        case .userCancelled: message = "已取消打赏"
        @unknown default: message = "购买尚未完成，请稍后重试"
        }
        publish()
        result(snapshot())
      } catch {
        message = "购买失败，请稍后重试"
        publish()
        result(FlutterError(code: "purchase", message: message, details: String(describing: error)))
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
