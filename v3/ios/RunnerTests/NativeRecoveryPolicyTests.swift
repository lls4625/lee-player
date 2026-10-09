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

final class LibraryTransactionTests: XCTestCase {
  private let fm = FileManager.default
  private var temporary: URL!
  private var root: URL { temporary.appendingPathComponent("Documents", isDirectory: true) }
  private var support: URL { temporary.appendingPathComponent("Support", isDirectory: true) }
  private let recordA: [String: Any] = ["position": 45.0, "duration": 120.0, "favorite": true]
  private let recordB: [String: Any] = ["position": 80.0, "duration": 180.0, "favorite": false]

  override func setUpWithError() throws {
    temporary = fm.temporaryDirectory.appendingPathComponent("LibraryTransactions-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    _ = ImportStagingStore.shared.recoverSynchronously(in: support)
    try? fm.removeItem(at: temporary)
  }

  private func library() throws -> CourseLibrary {
    let library = try CourseLibrary(root: root, support: support)
    let ready = expectation(description: "Initial library record load")
    library.recordStore.afterInitialLoad { ready.fulfill() }
    wait(for: [ready], timeout: 5)
    return library
  }

  private func writeJSON(_ object: [String: Any], name: String = "library.json") throws {
    try JSONSerialization.data(withJSONObject: object).write(to: support.appendingPathComponent(name), options: .atomic)
  }

  private func document() throws -> [String: Any] {
    try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: support.appendingPathComponent("library.json"))) as? [String: Any])
  }

  private func makeTrash(token: String, path: String, content: String = "A") throws -> URL {
    let directory = support.appendingPathComponent("Trash/" + token)
    try fm.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data(path.utf8).write(to: directory.appendingPathComponent("original.txt"))
    try Data(content.utf8).write(to: directory.appendingPathComponent("content"))
    return directory
  }

  private func assertRecord(_ records: LibraryRecordStore.Records, path: String,
                            position: Double, favorite: Bool, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(records[path]?["position"] as? Double, position, file: file, line: line)
    XCTAssertEqual(records[path]?["favorite"] as? Bool, favorite, file: file, line: line)
  }

  func testSameNameImportsAndRecyclesKeepIndependentHistoriesAcrossRestart() throws {
    let initial = try library()
    try Data("A".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try initial.recordStore.mutate { $0["lesson.mp4"] = recordA }
    let tokenA = try initial.trash(path: "lesson.mp4")
    XCTAssertNil(initial.recordStore.snapshot["lesson.mp4"])

    let sources = temporary.appendingPathComponent("Sources")
    try fm.createDirectory(at: sources, withIntermediateDirectories: true)
    let sourceB = sources.appendingPathComponent("lesson.mp4")
    try Data("B".utf8).write(to: sourceB)
    XCTAssertEqual(try initial.importFiles([sourceB], parent: "", cancellation: initial.beginImport(),
                                          progress: { _, _, _ in }), ["lesson.mp4"])
    XCTAssertNil(initial.recordStore.snapshot["lesson.mp4"], "B must not inherit A's position or favorite")
    try initial.recordStore.mutate { $0["lesson.mp4"] = recordB }
    let tokenB = try initial.trash(path: "lesson.mp4")

    let restarted = try library()
    XCTAssertNil(restarted.recordStore.status)
    try restarted.restore(token: tokenA)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("lesson.mp4"), encoding: .utf8), "A")
    assertRecord(restarted.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    _ = try restarted.move(path: "lesson.mp4", parent: "", name: "A.mp4")
    try restarted.restore(token: tokenB)
    XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("lesson.mp4"), encoding: .utf8), "B")
    assertRecord(restarted.recordStore.snapshot, path: "lesson.mp4", position: 80, favorite: false)
    assertRecord(restarted.recordStore.snapshot, path: "A.mp4", position: 45, favorite: true)
  }

  func testFolderTrashMovesEntireRecordSubtreeAndPurgeKeepsReplacementRecords() throws {
    let library = try library()
    try fm.createDirectory(at: root.appendingPathComponent("Course/Sub"), withIntermediateDirectories: true)
    try Data("A".utf8).write(to: root.appendingPathComponent("Course/Sub/lesson.mp4"))
    try Data("other".utf8).write(to: root.appendingPathComponent("Course-Other.mp4"))
    try library.recordStore.mutate {
      $0["Course/Sub/lesson.mp4"] = recordA
      $0["Course-Other.mp4"] = recordB
    }
    let token = try library.trash(path: "Course")
    XCTAssertNil(library.recordStore.snapshot["Course/Sub/lesson.mp4"])
    assertRecord(library.recordStore.snapshot, path: "Course-Other.mp4", position: 80, favorite: false)
    try library.restore(token: token)
    assertRecord(library.recordStore.snapshot, path: "Course/Sub/lesson.mp4", position: 45, favorite: true)
    _ = try library.trash(path: "Course")
    try fm.createDirectory(at: root.appendingPathComponent("Course/Sub"), withIntermediateDirectories: true)
    try Data("B".utf8).write(to: root.appendingPathComponent("Course/Sub/lesson.mp4"))
    try library.recordStore.mutate { $0["Course/Sub/lesson.mp4"] = recordB }
    try library.emptyTrash()
    assertRecord(library.recordStore.snapshot, path: "Course/Sub/lesson.mp4", position: 80, favorite: false)
    XCTAssertTrue(try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords).isEmpty)
  }

  func testRecycleRecoveryCommitsRecordsAndArchiveTogetherAfterFileMoved() throws {
    let token = UUID().uuidString
    _ = try makeTrash(token: token, path: "lesson.mp4")
    try writeJSON(["version": 2, "records": ["lesson.mp4": recordA], "trashRecords": [:]])
    try writeJSON(["version": 2, "kind": "move", "source": "root/lesson.mp4",
                   "destination": "support/Trash/\(token)/content", "records": [:],
                   "trashRecords": [token: ["lesson.mp4": recordA]]], name: "library-operation.json")
    let recovered = try library()
    XCTAssertNil(recovered.recordStore.status)
    XCTAssertNil(recovered.recordStore.snapshot["lesson.mp4"])
    XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("library-operation.json").path))
    try recovered.restore(token: token)
    assertRecord(recovered.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
  }

  func testRecycleRecoveryBeforeFileMoveRetainsLiveRecords() throws {
    let token = UUID().uuidString
    try Data("A".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try writeJSON(["version": 2, "records": ["lesson.mp4": recordA], "trashRecords": [:]])
    try writeJSON(["version": 2, "kind": "move", "source": "root/lesson.mp4",
                   "destination": "support/Trash/\(token)/content", "records": [:],
                   "trashRecords": [token: ["lesson.mp4": recordA]]], name: "library-operation.json")
    let recovered = try library()
    XCTAssertNil(recovered.recordStore.status)
    assertRecord(recovered.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    XCTAssertTrue(try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords).isEmpty)
  }

  func testRestoreRecoveryAfterFileMoveKeepsOtherTokenIsolated() throws {
    let tokenA = UUID().uuidString, tokenB = UUID().uuidString
    _ = try makeTrash(token: tokenB, path: "lesson.mp4", content: "B")
    try Data("A".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try writeJSON(["version": 2, "records": [:], "trashRecords": [
      tokenA: ["lesson.mp4": recordA], tokenB: ["lesson.mp4": recordB],
    ]])
    try writeJSON(["version": 2, "kind": "move", "source": "support/Trash/\(tokenA)/content",
                   "destination": "root/lesson.mp4", "records": ["lesson.mp4": recordA],
                   "trashRecords": [tokenB: ["lesson.mp4": recordB]]], name: "library-operation.json")
    let recovered = try library()
    XCTAssertNil(recovered.recordStore.status)
    assertRecord(recovered.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    let archived = try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords)
    XCTAssertNil(archived[tokenA])
    assertRecord(archived[tokenB] ?? [:], path: "lesson.mp4", position: 80, favorite: false)
  }

  func testInterruptedPurgeRecoveryRemovesOnlySelectedArchive() throws {
    let token = UUID().uuidString
    _ = try makeTrash(token: token, path: "lesson.mp4")
    try Data("B".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try writeJSON(["version": 2, "records": ["lesson.mp4": recordB],
                   "trashRecords": [token: ["lesson.mp4": recordA]]])
    try writeJSON(["version": 2, "kind": "purge", "source": "support/Trash/\(token)",
                   "destination": "", "records": ["lesson.mp4": recordB], "trashRecords": [:]],
                  name: "library-operation.json")
    let recovered = try library()
    XCTAssertNil(recovered.recordStore.status)
    assertRecord(recovered.recordStore.snapshot, path: "lesson.mp4", position: 80, favorite: false)
    XCTAssertFalse(fm.fileExists(atPath: support.appendingPathComponent("Trash/" + token).path))
    XCTAssertTrue(try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords).isEmpty)
  }

  func testV1JournalRecoveryMigratesLegacyTrashBeforeAllowingSameNameImport() throws {
    let token = UUID().uuidString
    _ = try makeTrash(token: token, path: "lesson.mp4")
    try writeJSON(["version": 1, "records": ["lesson.mp4": recordA]])
    try writeJSON(["version": 1, "kind": "move", "source": "root/lesson.mp4",
                   "destination": "support/Trash/\(token)/content", "records": ["lesson.mp4": recordA]],
                  name: "library-operation.json")
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"])
    try migrated.restore(token: token)
    assertRecord(migrated.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    XCTAssertEqual(try document()["version"] as? Int, 2)
  }

  func testLegacyMigrationResumesAfterRecoveryCommitWasInterrupted() throws {
    let token = UUID().uuidString
    _ = try makeTrash(token: token, path: "lesson.mp4")
    try writeJSON(["version": 2, "records": ["lesson.mp4": recordA],
                   "trashRecords": [:], "legacyTrashPending": true])
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"])
    XCTAssertEqual(try document()["legacyTrashPending"] as? Bool, false)
    try migrated.restore(token: token)
    assertRecord(migrated.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
  }

  func testUnversionedDataKeepsLiveHistoryAndExactMigrationBackup() throws {
    try Data("A".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    let original = try JSONSerialization.data(withJSONObject: ["lesson.mp4": recordA])
    try original.write(to: support.appendingPathComponent("library.json"))
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    assertRecord(migrated.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    let backups = try fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("library-legacy-") }
    XCTAssertEqual(backups.count, 1)
    XCTAssertEqual(try Data(contentsOf: XCTUnwrap(backups.first)), original)
  }

  func testAmbiguousLegacyTrashDoesNotAssignOneHistoryToTwoFiles() throws {
    let tokenA = UUID().uuidString, tokenB = UUID().uuidString
    _ = try makeTrash(token: tokenA, path: "lesson.mp4")
    _ = try makeTrash(token: tokenB, path: "lesson.mp4", content: "B")
    try writeJSON(["version": 1, "records": ["lesson.mp4": recordB]])
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"])
    let archived = try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords)
    XCTAssertTrue(archived[tokenA]?.isEmpty == true)
    XCTAssertTrue(archived[tokenB]?.isEmpty == true)
    try migrated.restore(token: tokenA)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"], "Unknown legacy ownership must not be guessed")
  }

  func testUpgradeDoesNotAssignTrashedAHistoryToNeverPlayedLiveB() throws {
    let token = UUID().uuidString
    _ = try makeTrash(token: token, path: "lesson.mp4", content: "ORIGINAL_A")
    try Data("NEW_B_NEVER_PLAYED".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try Data("unrelated".utf8).write(to: root.appendingPathComponent("other.mp4"))
    // This is the state the old app leaves after A (45 seconds/favorite) is
    // recycled and B is imported under its name without ever being played.
    try writeJSON(["version": 1, "records": ["lesson.mp4": recordA, "other.mp4": recordB]])
    let original = try Data(contentsOf: support.appendingPathComponent("library.json"))
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"])
    assertRecord(migrated.recordStore.snapshot, path: "other.mp4", position: 80, favorite: false)
    let archived = try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords)
    XCTAssertTrue(archived[token]?.isEmpty == true, "Neither owner is knowable from old path-only storage")
    let backups = try fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("library-legacy-") }
    XCTAssertEqual(backups.count, 2)
    for backup in backups { XCTAssertEqual(try Data(contentsOf: backup), original) }
    _ = try migrated.move(path: "lesson.mp4", parent: "", name: "B.mp4")
    try migrated.restore(token: token)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"])
    XCTAssertNil(migrated.recordStore.snapshot["B.mp4"])
    assertRecord(migrated.recordStore.snapshot, path: "other.mp4", position: 80, favorite: false)
  }

  func testLiveLegacyConflictBackupRetainsNewerJournalStateAcrossRestart() throws {
    let token = UUID().uuidString
    _ = try makeTrash(token: token, path: "lesson.mp4", content: "A")
    try Data("B".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try Data("other".utf8).write(to: root.appendingPathComponent("other.mp4"))
    try writeJSON(["version": 1, "records": ["lesson.mp4": recordA, "old-other.mp4": recordA]])
    try writeJSON(["version": 1, "kind": "move", "source": "root/old-other.mp4",
                   "destination": "root/other.mp4", "records": ["lesson.mp4": recordB, "other.mp4": recordA]],
                  name: "library-operation.json")
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"])
    assertRecord(migrated.recordStore.snapshot, path: "other.mp4", position: 45, favorite: true)
    let backup = try XCTUnwrap(fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix("library-legacy-ambiguous-") })
    let originalBackup = try Data(contentsOf: backup)
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBackup) as? [String: Any])
    assertRecord(try XCTUnwrap(saved["records"] as? LibraryRecordStore.Records),
                 path: "lesson.mp4", position: 80, favorite: false)
    let restarted = try library()
    XCTAssertNil(restarted.recordStore.status)
    XCTAssertNil(restarted.recordStore.snapshot["lesson.mp4"])
    assertRecord(restarted.recordStore.snapshot, path: "other.mp4", position: 45, favorite: true)
    let archived = try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords)
    XCTAssertTrue(archived[token]?.isEmpty == true)
    XCTAssertEqual(try Data(contentsOf: backup), originalBackup)
  }

  func testLegacyFolderMigrationIsolatesConflictsButPreservesUnrelatedLiveChildren() throws {
    let token = UUID().uuidString
    let directory = support.appendingPathComponent("Trash/" + token)
    try fm.createDirectory(at: directory.appendingPathComponent("content/Sub"), withIntermediateDirectories: true)
    try Data("Course".utf8).write(to: directory.appendingPathComponent("original.txt"))
    for name in ["lesson.mp4", "second.mp4"] {
      try Data("A".utf8).write(to: directory.appendingPathComponent("content/Sub/" + name))
    }
    try fm.createDirectory(at: root.appendingPathComponent("Course/Sub"), withIntermediateDirectories: true)
    try Data("B".utf8).write(to: root.appendingPathComponent("Course/Sub/lesson.mp4"))
    try Data("new child".utf8).write(to: root.appendingPathComponent("Course/Sub/new.mp4"))
    try Data("unrelated".utf8).write(to: root.appendingPathComponent("Course-Other.mp4"))
    try writeJSON(["version": 1, "records": [
      "Course/Sub/lesson.mp4": recordB, "Course/Sub/second.mp4": recordA,
      "Course/Sub/new.mp4": recordB, "Course-Other.mp4": recordA,
    ]])
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    XCTAssertNil(migrated.recordStore.snapshot["Course/Sub/lesson.mp4"], "The old format cannot prove that this record belongs to the replacement")
    assertRecord(migrated.recordStore.snapshot, path: "Course/Sub/new.mp4", position: 80, favorite: false)
    assertRecord(migrated.recordStore.snapshot, path: "Course-Other.mp4", position: 45, favorite: true)
    XCTAssertNil(migrated.recordStore.snapshot["Course/Sub/second.mp4"])
    XCTAssertThrowsError(try migrated.restore(token: token))
    let replacementToken = try migrated.trash(path: "Course")
    try migrated.restore(token: token)
    assertRecord(migrated.recordStore.snapshot, path: "Course/Sub/second.mp4", position: 45, favorite: true)
    XCTAssertNil(migrated.recordStore.snapshot["Course/Sub/lesson.mp4"])
    let archived = try XCTUnwrap(document()["trashRecords"] as? LibraryRecordStore.TrashRecords)
    XCTAssertNil(archived[replacementToken]?["Course/Sub/lesson.mp4"])
    assertRecord(archived[replacementToken] ?? [:], path: "Course/Sub/new.mp4", position: 80, favorite: false)
    let backup = try XCTUnwrap(fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix("library-legacy-ambiguous-") })
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
    assertRecord(try XCTUnwrap(saved["records"] as? LibraryRecordStore.Records),
                 path: "Course/Sub/lesson.mp4", position: 80, favorite: false)
  }

  func testMigrationFailureRetainsOriginalDataBlocksWritesAndRetriesSafely() throws {
    try Data("A".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try writeJSON(["version": 1, "records": ["lesson.mp4": recordA]])
    let original = try Data(contentsOf: support.appendingPathComponent("library.json"))
    let brokenTrash = support.appendingPathComponent("Trash")
    try Data("not a directory".utf8).write(to: brokenTrash)
    let failed = try library()
    XCTAssertEqual(failed.recordStore.status, "library_records_unavailable")
    XCTAssertThrowsError(try failed.recordStore.mutate { $0.removeAll() })
    XCTAssertEqual(try Data(contentsOf: support.appendingPathComponent("library.json")), original)
    assertRecord(failed.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    try fm.removeItem(at: brokenTrash)
    failed.recordStore.retryStorage()
    // The synchronous mutation is queued behind the retry and is also proof
    // that migration finished before normal writes were permitted again.
    try failed.recordStore.mutate { _ in }
    XCTAssertNil(failed.recordStore.status)
    assertRecord(failed.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    XCTAssertEqual(try document()["version"] as? Int, 2)
  }

  func testFailedRecordCommitAfterRecycleKeepsJournalAndRecoversArchive() throws {
    let original = try library()
    try Data("A".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    try original.recordStore.mutate { $0["lesson.mp4"] = recordA }
    let recordFile = support.appendingPathComponent("library.json")
    let committed = try Data(contentsOf: recordFile)
    try fm.removeItem(at: recordFile)
    try fm.createDirectory(at: recordFile, withIntermediateDirectories: false)
    XCTAssertThrowsError(try original.trash(path: "lesson.mp4"))
    XCTAssertEqual(original.recordStore.status, "library_records_recovery")
    XCTAssertNil(original.recordStore.snapshot["lesson.mp4"])
    let token = try XCTUnwrap(original.trashList().first?["token"] as? String)
    XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("library-operation.json").path))
    try fm.removeItem(at: recordFile)
    try committed.write(to: recordFile)
    let recovered = try library()
    XCTAssertNil(recovered.recordStore.status)
    try recovered.restore(token: token)
    assertRecord(recovered.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
  }

  func testAmbiguousLegacyBackupIncludesNewerRecoveredJournalProgress() throws {
    let tokenA = UUID().uuidString, tokenB = UUID().uuidString
    _ = try makeTrash(token: tokenA, path: "lesson.mp4")
    _ = try makeTrash(token: tokenB, path: "lesson.mp4", content: "B")
    try writeJSON(["version": 1, "records": ["lesson.mp4": recordA]])
    try writeJSON(["version": 1, "kind": "move", "source": "root/lesson.mp4",
                   "destination": "support/Trash/\(tokenB)/content", "records": ["lesson.mp4": recordB]],
                  name: "library-operation.json")
    let migrated = try library()
    XCTAssertNil(migrated.recordStore.status)
    XCTAssertNil(migrated.recordStore.snapshot["lesson.mp4"])
    let backup = try XCTUnwrap(fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .first { $0.lastPathComponent.hasPrefix("library-legacy-ambiguous-") })
    let saved = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: backup)) as? [String: Any])
    assertRecord(try XCTUnwrap(saved["records"] as? LibraryRecordStore.Records),
                 path: "lesson.mp4", position: 80, favorite: false)
  }

  func testMalformedArchiveAndUnresolvedJournalBlockMutationsWithoutLosingData() throws {
    let token = UUID().uuidString
    try Data("A".utf8).write(to: root.appendingPathComponent("lesson.mp4"))
    _ = try makeTrash(token: token, path: "lesson.mp4", content: "B")
    try writeJSON(["version": 2, "records": ["lesson.mp4": recordA], "trashRecords": [:]])
    try writeJSON(["version": 2, "kind": "move", "source": "root/lesson.mp4",
                   "destination": "support/Trash/\(token)/content", "records": [:],
                   "trashRecords": [token: ["lesson.mp4": recordA]]], name: "library-operation.json")
    let failed = try library()
    XCTAssertEqual(failed.recordStore.status, "library_records_recovery")
    XCTAssertThrowsError(try failed.recordStore.mutate { $0.removeAll() })
    assertRecord(failed.recordStore.snapshot, path: "lesson.mp4", position: 45, favorite: true)
    XCTAssertTrue(fm.fileExists(atPath: support.appendingPathComponent("library-operation.json").path))

    try fm.removeItem(at: support.appendingPathComponent("library-operation.json"))
    try writeJSON(["version": 2, "records": ["lesson.mp4": recordA], "trashRecords": ["invalid-token": [:]]])
    let corrupt = try library()
    XCTAssertEqual(corrupt.recordStore.status, "library_records_corrupt")
    XCTAssertThrowsError(try corrupt.recordStore.mutate { $0.removeAll() })
  }
}

final class ImportStagingRecoveryTests: XCTestCase {
  private let fm = FileManager.default
  private var temporary: URL!
  private var root: URL { temporary.appendingPathComponent("Documents", isDirectory: true) }
  private var support: URL { temporary.appendingPathComponent("Support", isDirectory: true) }

  override func setUpWithError() throws {
    temporary = fm.temporaryDirectory.appendingPathComponent("ImportRecovery-\(UUID().uuidString)")
    try fm.createDirectory(at: root, withIntermediateDirectories: true)
    try fm.createDirectory(at: support, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    _ = ImportStagingStore.shared.recoverSynchronously(in: support)
    try? fm.removeItem(at: temporary)
  }

  private func orphan(name: String = "Import-" + UUID().uuidString, in directory: URL? = nil) throws -> URL {
    let path = (directory ?? support).appendingPathComponent(name, isDirectory: true)
    try fm.createDirectory(at: path, withIntermediateDirectories: true)
    try Data(repeating: 3, count: 4096).write(to: path.appendingPathComponent("selection"))
    return path
  }

  func testStartupRecoversPriorProcessStagesEvenWhenRecordRecoveryFails() throws {
    let abandoned = try orphan()
    try Data("corrupt library".utf8).write(to: support.appendingPathComponent("library.json"))
    let library = try CourseLibrary(root: root, support: support)
    let ready = expectation(description: "Failed record recovery has completed")
    library.recordStore.afterInitialLoad { ready.fulfill() }
    wait(for: [ready], timeout: 5)
    XCTAssertEqual(library.recordStore.status, "library_records_corrupt")
    // Drain the shared staging queue via a different private directory. This
    // must not clean Support again, or it would hide missing startup recovery.
    let barrierSupport = temporary.appendingPathComponent("BarrierSupport")
    try fm.createDirectory(at: barrierSupport, withIntermediateDirectories: true)
    let barrier = try ImportStagingStore.shared.begin(in: barrierSupport)
    ImportStagingStore.shared.finish(barrier)
    XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
  }

  func testRecoveryAndNewImportNeverRemoveActiveStageAcrossLibraryInstances() throws {
    let active = try ImportStagingStore.shared.begin(in: support)
    defer { ImportStagingStore.shared.finish(active) }
    try Data("still copying".utf8).write(to: active.appendingPathComponent("selection"))
    _ = try CourseLibrary(root: root, support: support)
    let abandoned = try orphan()
    let second = try ImportStagingStore.shared.begin(in: support)
    defer { ImportStagingStore.shared.finish(second) }
    XCTAssertTrue(fm.fileExists(atPath: active.appendingPathComponent("selection").path))
    XCTAssertTrue(fm.fileExists(atPath: second.path))
    XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
  }

  func testRecoveryAcceptsSupportURLWithoutDirectoryHint() throws {
    let abandoned = try orphan()
    let unhinted = temporary.appendingPathComponent("Support")
    XCTAssertTrue(ImportStagingStore.shared.recoverSynchronously(in: unhinted).isEmpty)
    XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
  }

  func testActiveStageIsRecognizedThroughSymlinkedSupportPath() throws {
    let linkedSupport = temporary.appendingPathComponent("LinkedSupport")
    try fm.createSymbolicLink(at: linkedSupport, withDestinationURL: support)
    let active = try ImportStagingStore.shared.begin(in: linkedSupport)
    defer { ImportStagingStore.shared.finish(active) }
    XCTAssertTrue(ImportStagingStore.shared.recoverSynchronously(in: support).isEmpty)
    XCTAssertTrue(fm.fileExists(atPath: active.path))
  }

  func testRecoveryLeavesUserMediaUnknownNamesFilesTrashAndSymlinkTargetsAlone() throws {
    let userMedia = try orphan(in: root)
    let unrelated = try orphan(name: "Import-user-notes")
    let trash = try orphan(name: "Trash")
    let file = support.appendingPathComponent("Import-" + UUID().uuidString)
    try Data("ordinary file".utf8).write(to: file)
    let link = support.appendingPathComponent("Import-" + UUID().uuidString)
    try fm.createSymbolicLink(at: link, withDestinationURL: userMedia)
    let abandoned = try orphan()
    XCTAssertTrue(ImportStagingStore.shared.recoverSynchronously(in: support).isEmpty)
    XCTAssertFalse(fm.fileExists(atPath: abandoned.path))
    for preserved in [userMedia, unrelated, trash, file, link] {
      XCTAssertTrue(fm.fileExists(atPath: preserved.path), preserved.path)
    }
  }

  func testFailedCleanupContinuesAndNextImportRetriesIt() throws {
    let blocked = try orphan(), other = try orphan()
    var shouldFail = true
    let staging = ImportStagingStore { url in
      if url == blocked && shouldFail {
        throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
      }
      try FileManager.default.removeItem(at: url)
    }
    XCTAssertEqual(staging.recoverSynchronously(in: support), [blocked])
    XCTAssertTrue(fm.fileExists(atPath: blocked.path))
    XCTAssertFalse(fm.fileExists(atPath: other.path), "A failed removal must not skip other abandoned stages")
    shouldFail = false
    let active = try staging.begin(in: support)
    XCTAssertFalse(fm.fileExists(atPath: blocked.path))
    XCTAssertTrue(fm.fileExists(atPath: active.path))
    staging.finish(active)
    XCTAssertFalse(fm.fileExists(atPath: active.path))
  }

  func testFailedFinishBecomesRecoverableWithoutDeletingOtherActiveStage() throws {
    var shouldFail = true
    let staging = ImportStagingStore { url in
      if shouldFail { throw NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError) }
      try FileManager.default.removeItem(at: url)
    }
    let completed = try staging.begin(in: support)
    staging.finish(completed)
    XCTAssertTrue(fm.fileExists(atPath: completed.path))
    shouldFail = false
    let active = try staging.begin(in: support)
    defer { staging.finish(active) }
    XCTAssertFalse(fm.fileExists(atPath: completed.path))
    XCTAssertTrue(staging.recoverSynchronously(in: support).isEmpty)
    XCTAssertTrue(fm.fileExists(atPath: active.path))
  }

  func testCancelledAndFailedImportsRemoveTheirOwnStages() throws {
    let library = try CourseLibrary(root: root, support: support)
    let cancelled = library.beginImport()
    cancelled.cancel()
    XCTAssertThrowsError(try library.importFiles([root.appendingPathComponent("missing.mp4")],
      parent: "", cancellation: cancelled, progress: { _, _, _ in }))
    XCTAssertThrowsError(try library.importFiles([root.appendingPathComponent("missing.mp4")],
      parent: "", cancellation: library.beginImport(), progress: { _, _, _ in }))
    let stages = try fm.contentsOfDirectory(at: support, includingPropertiesForKeys: nil)
      .filter { $0.lastPathComponent.hasPrefix("Import-") }
    XCTAssertTrue(stages.isEmpty)
  }
}

final class ExtraBoundaryTests: XCTestCase {
  func testUnicodeFolderImportCancellationAndReentry() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let library = try CourseLibrary(root: base.appendingPathComponent("Documents"), support: base.appendingPathComponent("Support"))
    let source = base.appendingPathComponent("源目录_日本語")
    try FileManager.default.createDirectory(at: source.appendingPathComponent("单元 1/空文件夹"), withIntermediateDirectories: true)
    let bytes = Data(repeating: 47, count: 3 * 1024 * 1024)
    try bytes.write(to: source.appendingPathComponent("单元 1/video.mp4"))
    let cancellation = library.beginImport()
    XCTAssertThrowsError(try library.importFiles([source], parent: "", cancellation: cancellation) { _, done, total in
      if done > 0 && done < total { cancellation.cancel() }
    }) { error in
      XCTAssertEqual((error as? LibraryFailure)?.code, "import_partial_failure")
      XCTAssertEqual((error as? LibraryFailure)?.args["reasonCode"] as? String, "import_cancelled")
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(source.lastPathComponent).path))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.support.path).contains(where: {$0.hasPrefix("Import-")}))
    let paths = try library.importFiles([source], parent: "", cancellation: library.beginImport()) { _,_,_ in }
    XCTAssertEqual(paths, [source.lastPathComponent])
    XCTAssertEqual(try Data(contentsOf: library.root.appendingPathComponent(paths[0] + "/单元 1/video.mp4")), bytes)
    XCTAssertTrue(FileManager.default.fileExists(atPath: library.root.appendingPathComponent(paths[0] + "/单元 1/空文件夹").path))
    let second = try library.importFiles([source], parent: "", cancellation: library.beginImport()) { _,_,_ in }
    XCTAssertEqual(second, [source.lastPathComponent + " (2)"])
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.support.path).contains(where: {$0.hasPrefix("Import-")}))
  }
  func testPartialSelectionKeepsCompletedItemAndCleansFailedStage() throws {
    let base = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: base) }
    let library = try CourseLibrary(root: base.appendingPathComponent("Documents"), support: base.appendingPathComponent("Support"))
    let source = base.appendingPathComponent("first.mp4")
    try Data("complete".utf8).write(to: source)
    XCTAssertThrowsError(try library.importFiles([source, base.appendingPathComponent("missing.mp4")], parent: "", cancellation: library.beginImport()) { _,_,_ in }) { error in
      XCTAssertEqual((error as? LibraryFailure)?.args["completed"] as? Int, 1)
      XCTAssertEqual((error as? LibraryFailure)?.args["reasonCode"] as? String, "selected_file_unavailable")
    }
    XCTAssertEqual(try Data(contentsOf: library.root.appendingPathComponent("first.mp4")), Data("complete".utf8))
    XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: library.support.path).contains(where: {$0.hasPrefix("Import-")}))
  }
}
