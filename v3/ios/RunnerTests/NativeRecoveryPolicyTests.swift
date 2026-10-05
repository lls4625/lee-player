import XCTest
@testable import Runner

final class NativeRecoveryPolicyTests: XCTestCase {
  private var temporary: URL!

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("LeiPlayerTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporary)
  }

  func testAudioRecoveryHasThreeRetriesThenTerminalState() {
    XCTAssertEqual(AudioRecoveryRetryPolicy.delay(forAttempt: 0), 0.25)
    XCTAssertEqual(AudioRecoveryRetryPolicy.delay(forAttempt: 1), 0.75)
    XCTAssertEqual(AudioRecoveryRetryPolicy.delay(forAttempt: 2), 1.5)
    XCTAssertNil(AudioRecoveryRetryPolicy.delay(forAttempt: 3))
  }

  func testPiPRestoreRequiresExactPendingToken() {
    let token = UUID()
    XCTAssertTrue(PlayerBridge.matchesPiPRestoreToken(
      expected: token, received: token.uuidString))
    XCTAssertFalse(PlayerBridge.matchesPiPRestoreToken(
      expected: token, received: UUID().uuidString))
    XCTAssertFalse(PlayerBridge.matchesPiPRestoreToken(
      expected: token, received: nil))
    XCTAssertFalse(PlayerBridge.matchesPiPRestoreToken(
      expected: nil, received: token.uuidString))
  }

  func testPiPAbortRequiresExactEngineAndRequestPair() {
    XCTAssertTrue(PlaybackService.matchesPiPAbort(
      engineID: "engine-b", requestID: "request-b",
      currentEngineID: "engine-b", currentRequestID: "request-b"))
    XCTAssertFalse(PlaybackService.matchesPiPAbort(
      engineID: "engine-a", requestID: "request-b",
      currentEngineID: "engine-b", currentRequestID: "request-b"))
    XCTAssertFalse(PlaybackService.matchesPiPAbort(
      engineID: "engine-b", requestID: "request-a",
      currentEngineID: "engine-b", currentRequestID: "request-b"))
  }

  func testScanKeepsHealthyEntriesWhenUnsupportedSymlinkExists() throws {
    let root = temporary.appendingPathComponent("Documents", isDirectory: true)
    let support = temporary.appendingPathComponent("Support", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: root.appendingPathComponent("healthy.mp3"))
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent("broken.mp3"),
      withDestinationURL: root.appendingPathComponent("missing-target"))

    let library = try CourseLibrary(root: root, support: support)
    let snapshot = try library.scanSnapshot()
    let items = snapshot.items

    XCTAssertTrue(items.contains { $0["path"] as? String == "healthy.mp3" })
    XCTAssertFalse(items.contains { $0["path"] as? String == "broken.mp3" })
    XCTAssertTrue(snapshot.protectionPaths.contains("healthy.mp3"))
    XCTAssertFalse(snapshot.protectionPaths.contains("broken.mp3"))
    XCTAssertTrue(snapshot.warnings.contains {
      $0["code"] as? String == "symbolic_link_unsupported"
        && $0["path"] as? String == "broken.mp3"
    })
  }
}
