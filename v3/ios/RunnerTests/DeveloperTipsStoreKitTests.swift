import StoreKit
import StoreKitTest
import XCTest

final class DeveloperTipsStoreKitTests: XCTestCase {
  private let expectedIDs: Set<String> = [
    "vip.ichiki.javalee.leeplayer.tip.small",
    "vip.ichiki.javalee.leeplayer.tip.medium",
    "vip.ichiki.javalee.leeplayer.tip.large",
    "vip.ichiki.javalee.leeplayer.tip.xlarge",
    "vip.ichiki.javalee.leeplayer.tip.premium",
    "vip.ichiki.javalee.leeplayer.tip.strong",
  ]

  func testLoadsProductsAndCompletesLocalConsumableTransaction() async throws {
    let bundle = Bundle(for: Self.self)
    let configuration = try XCTUnwrap(
      bundle.url(forResource: "DeveloperTips", withExtension: "storekit")
    )
    let session = try SKTestSession(contentsOf: configuration)
    session.disableDialogs = true
    session.clearTransactions()
    defer { session.clearTransactions() }

    let products = try await Product.products(for: expectedIDs)
    XCTAssertEqual(Set(products.map(\.id)), expectedIDs)
    XCTAssertTrue(products.allSatisfy { $0.type == .consumable })

    let productID = "vip.ichiki.javalee.leeplayer.tip.small"
    let product = try XCTUnwrap(products.first { $0.id == productID })
    let result = try await product.purchase()
    guard case .success(.verified(let transaction)) = result else {
      return XCTFail("Expected a locally verified StoreKit transaction, got \(result)")
    }
    XCTAssertEqual(transaction.productID, productID)
    XCTAssertEqual(session.allTransactions().count, 1)
    await transaction.finish()
  }
}
