import XCTest
import AVFoundation
@testable import Runner

private final class PlaybackTestTransport {
  var requestedSeeks: [Double] = []
  var holdSeeks = false
  var holdSubtitles = false
  var seeks: [(seconds: Double, finish: (Bool) -> Void)] = []
  var subtitles: [(Bool) -> Void] = []

  func send(_ method: String, _ arguments: [String: Any], _ finish: @escaping (Bool) -> Void) {
    if method == "seek" { requestedSeeks.append(arguments["seconds"] as? Double ?? -1) }
    if method == "seek", holdSeeks {
      seeks.append((arguments["seconds"] as? Double ?? -1, finish))
    } else if method == "subtitle", holdSubtitles {
      subtitles.append(finish)
    } else {
      finish(true)
    }
  }
}

final class PlaybackSessionTests: XCTestCase {
  private var temporary: URL!
  private var library: CourseLibrary!
  private var testTransport: PlaybackTestTransport!
  private var savedDefaults: [String: Any] = [:]
  private let preferenceKeys = ["playback.rememberProgress", "playback.smartIntro", "playback.continuous"]

  override func setUpWithError() throws {
    for key in preferenceKeys {
      if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
    }
    UserDefaults.standard.set(true, forKey: "playback.rememberProgress")
    UserDefaults.standard.set(false, forKey: "playback.smartIntro")
    UserDefaults.standard.set(false, forKey: "playback.continuous")
    temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("LeiPlayerPlaybackTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    for key in preferenceKeys {
      if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    savedDefaults.removeAll()
    try? FileManager.default.removeItem(at: temporary)
  }

  private func makeService(_ transport: PlaybackTestTransport, remember: Bool = true,
                           resume: Bool = false, prepare: Bool = true,
                           record: [String: Any] = [:]) throws -> PlaybackService {
    testTransport = transport
    UserDefaults.standard.set(remember, forKey: "playback.rememberProgress")
    let root = temporary.appendingPathComponent("Documents", isDirectory: true)
    let support = temporary.appendingPathComponent("Support", isDirectory: true)
    library = try CourseLibrary(root: root, support: support)
    for path in ["a.mkv", "b.mkv", "captions.srt"] {
      try Data("1\n00:00:00,000 --> 00:00:05,000\nCaption\n".utf8)
        .write(to: root.appendingPathComponent(path))
    }
    let loaded = expectation(description: "records loaded")
    library.recordStore.afterInitialLoad { loaded.fulfill() }
    wait(for: [loaded], timeout: 2)
    if !record.isEmpty { library.recordStore.updateProgress(path: "a.mkv", fields: record) }
    let service = PlaybackService(library: library)
    service.mediaKitTransport = { method, arguments, completion in
      transport.send(method, arguments, completion)
    }
    try service.open(paths: ["a.mkv", "b.mkv"], selected: 0, resume: resume)
    waitUntil { service.mediaKitEngineId != nil }
    if prepare { prepareCurrent(service) }
    return service
  }

  private func prepareCurrent(_ service: PlaybackService) {
    waitUntil { service.mediaKitEngineId != nil }
    service.pause()
    let previousSeeks = testTransport.requestedSeeks.count
    service.receiveMediaKitState([
      "engineId": service.mediaKitEngineId!, "ready": true,
      "duration": 120.0, "position": 0.0, "seekable": true, "playing": false,
    ])
    waitUntil { self.testTransport.requestedSeeks.count > previousSeeks }
    drainMainQueue()
  }

  private func drainMainQueue() {
    let drained = expectation(description: "main callbacks settled")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
  }

  private func waitUntil(_ predicate: @escaping () -> Bool) {
    let ready = expectation(description: "playback condition reached")
    let deadline = ProcessInfo.processInfo.systemUptime + 2
    func check() {
      if predicate() { ready.fulfill() }
      else if ProcessInfo.processInfo.systemUptime >= deadline {
        XCTFail("Playback condition did not become true")
        ready.fulfill()
      } else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.01, execute: check) }
    }
    check()
    wait(for: [ready], timeout: 3)
  }

  private func record() -> [String: Any] {
    let read = expectation(description: "queued progress read")
    var result: [String: Any] = [:]
    library.recordStore.readPlaybackRecord(path: "a.mkv") { result = $0; read.fulfill() }
    wait(for: [read], timeout: 2)
    return result
  }

  private func configure(_ service: PlaybackService, remember: Bool) {
    var result: String?
    service.requestConfiguration(["rememberProgress": remember]) { result = $0 }
    XCTAssertNil(result)
    XCTAssertEqual(service.snapshot()["rememberProgress"] as? Bool, remember)
  }

  private func position(_ value: Double, in service: PlaybackService, ended: Bool = false) {
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!,
      "position": value, "ended": ended])
  }

  private func assertProgress(_ actual: [String: Any], position: Double, duration: Double = 120,
                              origin: Double = 0, completed: Bool = false,
                              file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(actual["position"] as? Double, position, file: file, line: line)
    XCTAssertEqual(actual["duration"] as? Double, duration, file: file, line: line)
    XCTAssertEqual(actual["timelineOrigin"] as? Double, origin, file: file, line: line)
    XCTAssertEqual(actual["completed"] as? Bool, completed, file: file, line: line)
  }

  func testDisablingCapturesFinalPositionAndOffPreservesAllProgressFields() throws {
    let service = try makeService(PlaybackTestTransport())
    position(23, in: service)
    configure(service, remember: false)
    assertProgress(record(), position: 23)
    position(78, in: service)
    service.persist(); service.pause()
    assertProgress(record(), position: 23)
    XCTAssertNotNil(record()["lastPlayed"])
  }

  func testDisablingDuringSeekSavesPreSeekStablePositionNotPreview() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    position(26, in: service)
    transport.holdSeeks = true
    service.seek(80)
    position(70, in: service)
    configure(service, remember: false)
    assertProgress(record(), position: 26)
    position(80, in: service)
    (try XCTUnwrap(transport.seeks.first)).finish(true)
    assertProgress(record(), position: 26)
  }

  func testEnablingCurrentReadySessionRecordsCurrentPositionWithoutSeeking() throws {
    let transport = PlaybackTestTransport()
    let historical: [String: Any] = ["position": 60.0, "duration": 100.0,
      "timelineOrigin": 2.0, "completed": true, "favorite": true]
    let service = try makeService(transport, remember: false, record: historical)
    position(19, in: service)
    let count = transport.requestedSeeks.count
    configure(service, remember: true)
    assertProgress(record(), position: 19)
    XCTAssertEqual(transport.requestedSeeks.count, count)
    XCTAssertEqual(record()["favorite"] as? Bool, true)
  }

  func testOpeningWhileOffCannotResumeHistoryWhenEnabledDuringLoading() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, remember: false, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0])
    configure(service, remember: true)
    XCTAssertEqual(record()["position"] as? Double, 60)
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, false)
    prepareCurrent(service)
    XCTAssertEqual(transport.requestedSeeks, [0])
    assertProgress(record(), position: 0)
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, true)
  }

  func testDisablingThenEnablingBeforeReadyRevokesThisOpensHistoricalResume() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0])
    configure(service, remember: false)
    configure(service, remember: true)
    prepareCurrent(service)
    XCTAssertEqual(transport.requestedSeeks, [0])
  }

  func testOffOnDuringHeldHistoricalSeekSupersedesOldAcknowledgmentWithZeroStart() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0, "completed": false])
    transport.holdSeeks = true
    prepareCurrent(service)
    XCTAssertEqual((try XCTUnwrap(transport.seeks.first)).seconds, 60)
    configure(service, remember: false)
    configure(service, remember: true)
    position(60, in: service)
    (try XCTUnwrap(transport.seeks.first)).finish(true)
    drainMainQueue()
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, false)
    XCTAssertEqual((try XCTUnwrap(transport.seeks.dropFirst().first)).seconds, 0)
    assertProgress(record(), position: 60)
    position(0, in: service)
    (try XCTUnwrap(transport.seeks.dropFirst().first)).finish(true)
    drainMainQueue()
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, true)
    assertProgress(record(), position: 0)
  }

  func testOffInvalidatesHistoricalSuccessAlreadyQueuedForMainDelivery() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0, "completed": false])
    transport.holdSeeks = true
    prepareCurrent(service)
    position(60, in: service)
    (try XCTUnwrap(transport.seeks.first)).finish(true) // finishStart's success is now queued on main.
    configure(service, remember: false)
    configure(service, remember: true)
    drainMainQueue()
    XCTAssertEqual((try XCTUnwrap(transport.seeks.dropFirst().first)).seconds, 0)
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, false)
    assertProgress(record(), position: 60)
    position(0, in: service)
    (try XCTUnwrap(transport.seeks.dropFirst().first)).finish(true)
    drainMainQueue()
    assertProgress(record(), position: 0)
  }

  func testPauseDuringInitialSeekStillEstablishesValidProgressAfterAcknowledgment() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0])
    transport.holdSeeks = true
    prepareCurrent(service)
    service.pause()
    position(60, in: service)
    (try XCTUnwrap(transport.seeks.first)).finish(true)
    drainMainQueue()
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, true)
    assertProgress(record(), position: 60)
  }

  func testHeadphoneRemovalDuringInitialSeekPreservesPositioningAcknowledgment() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0])
    transport.holdSeeks = true
    prepareCurrent(service)
    NotificationCenter.default.post(name: AVAudioSession.routeChangeNotification, object: nil,
      userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue])
    drainMainQueue()
    position(60, in: service)
    (try XCTUnwrap(transport.seeks.first)).finish(true)
    drainMainQueue()
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, true)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    assertProgress(record(), position: 60)
  }

  func testManualSeekSupersedesQueuedHistoricalRecordRead() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0])
    service.pause()
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "ready": true,
      "duration": 120.0, "position": 0.0, "seekable": true, "playing": false])
    // No main run-loop turn between readiness/read enqueue and explicit seek.
    position(18, in: service)
    service.seek(18)
    _ = record()
    drainMainQueue()
    XCTAssertEqual(transport.requestedSeeks, [18])
    assertProgress(record(), position: 18)
  }

  func testNonSeekableMetadataThenFailurePreservesHistory() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 100.0, "timelineOrigin": 5.0, "completed": false])
    service.pause()
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "ready": true,
      "duration": 120.0, "position": 0.0, "seekable": false, "playing": false])
    waitUntil { service.snapshot()["engineNotice"] as? String == "media_not_seekable" }
    service.persist()
    configure(service, remember: false)
    configure(service, remember: true)
    assertProgress(record(), position: 60, duration: 100, origin: 5)
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, false)
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "failure": "media_kit_open_failed"])
    service.persist()
    assertProgress(record(), position: 60, duration: 100, origin: 5)
  }

  func testNonSeekableProgressRequiresObservedNonbufferingPlaybackAdvancement() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0, "completed": false])
    service.pause()
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "ready": true,
      "duration": 120.0, "position": 0.0, "seekable": false, "playing": false])
    waitUntil { service.snapshot()["engineNotice"] as? String == "media_not_seekable" }
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "position": 0.0, "playing": true])
    service.persist()
    assertProgress(record(), position: 60)
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "position": 1.0, "buffering": true])
    service.persist()
    assertProgress(record(), position: 60)
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "position": 2.0, "buffering": false])
    assertProgress(record(), position: 2)
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, true)
    XCTAssertTrue(transport.requestedSeeks.isEmpty)
  }

  func testUnknownSeekabilityWaitsThenResumesHistoricalPosition() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0, "completed": false])
    service.pause()
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "ready": true,
      "duration": 120.0, "position": 0.0, "seekable": NSNull(), "playing": false])
    _ = record()
    XCTAssertTrue(transport.requestedSeeks.isEmpty)
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, false)
    assertProgress(record(), position: 60)
    transport.holdSeeks = true
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "seekable": true])
    waitUntil { !transport.seeks.isEmpty }
    XCTAssertEqual(try XCTUnwrap(transport.seeks.first).seconds, 60)
    position(60, in: service)
    try XCTUnwrap(transport.seeks.first).finish(true)
    drainMainQueue()
    assertProgress(record(), position: 60)
  }

  func testInitiallyNonSeekableThenSeekableBeforeAdvancementRestoresHistory() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 60.0, "duration": 120.0, "timelineOrigin": 0.0, "completed": false])
    service.pause()
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "ready": true,
      "duration": 120.0, "position": 0.0, "seekable": false, "playing": false])
    waitUntil { service.snapshot()["engineNotice"] as? String == "media_not_seekable" }
    transport.holdSeeks = true
    service.receiveMediaKitState(["engineId": service.mediaKitEngineId!, "seekable": true])
    waitUntil { !transport.seeks.isEmpty }
    XCTAssertEqual(try XCTUnwrap(transport.seeks.first).seconds, 60)
    assertProgress(record(), position: 60)
    position(60, in: service)
    try XCTUnwrap(transport.seeks.first).finish(true)
    drainMainQueue()
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, true)
  }

  func testInitialSeekFailureDoesNotMigrateOrOverwriteHistory() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 40.0, "duration": 100.0, "timelineOrigin": 5.0, "completed": false])
    transport.holdSeeks = true
    prepareCurrent(service)
    XCTAssertEqual(transport.seeks.first?.seconds, 45)
    service.persist()
    assertProgress(record(), position: 40, duration: 100, origin: 5)
    (try XCTUnwrap(transport.seeks.first)).finish(false)
    drainMainQueue()
    service.persist()
    assertProgress(record(), position: 40, duration: 100, origin: 5)
    XCTAssertEqual(service.snapshot()["progressValid"] as? Bool, false)
  }

  func testInitialSeekSuccessPersistsAcknowledgedPositionAndMigratesOrigin() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 40.0, "duration": 100.0, "timelineOrigin": 5.0, "completed": false])
    transport.holdSeeks = true
    prepareCurrent(service)
    assertProgress(record(), position: 40, duration: 100, origin: 5)
    position(45, in: service)
    (try XCTUnwrap(transport.seeks.first)).finish(true)
    drainMainQueue()
    assertProgress(record(), position: 45)
  }

  func testCompletionWhileOffPreservesHistoryAndOnCompletionSavesZero() throws {
    let service = try makeService(PlaybackTestTransport())
    position(32, in: service)
    configure(service, remember: false)
    service.play()
    position(120, in: service, ended: true)
    service.pause(); service.persist()
    assertProgress(record(), position: 32)
    configure(service, remember: true)
    assertProgress(record(), position: 0, completed: true)
    service.persist()
    assertProgress(record(), position: 0, completed: true)
  }

  func testCompletionWhileOnSurvivesLaterPauseAndSeekClearsCompleted() throws {
    let service = try makeService(PlaybackTestTransport())
    service.play()
    position(120, in: service, ended: true)
    service.pause(); service.persist()
    assertProgress(record(), position: 0, completed: true)
    position(15, in: service)
    service.seek(15)
    assertProgress(record(), position: 15)
  }

  func testCompletedRecordWithTimelineOriginRestartsAtZero() throws {
    let transport = PlaybackTestTransport()
    _ = try makeService(transport, resume: true,
      record: ["position": 0.0, "duration": 120.0, "timelineOrigin": 5.0, "completed": true])
    XCTAssertEqual(transport.requestedSeeks, [0])
    assertProgress(record(), position: 0)
  }

  func testLegacyPositivePositionResumesDespiteStaleCompletedFlag() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport, resume: true, prepare: false,
      record: ["position": 40.0, "duration": 120.0, "timelineOrigin": 5.0, "completed": true])
    transport.holdSeeks = true
    prepareCurrent(service)
    XCTAssertEqual((try XCTUnwrap(transport.seeks.first)).seconds, 45)
    position(45, in: service)
    (try XCTUnwrap(transport.seeks.first)).finish(true)
    drainMainQueue()
    assertProgress(record(), position: 45)
  }

  func testReopenReadsLastSubmittedSnapshotBeforeDiskPublication() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    position(37, in: service)
    configure(service, remember: false)
    configure(service, remember: true)
    try service.open(paths: ["a.mkv"], selected: 0, resume: true)
    prepareCurrent(service)
    XCTAssertEqual(transport.requestedSeeks.last, 37)
  }

  func testStaleExternalSubtitleRejectsBeforeSendingToNewMedia() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    let openingSession = service.snapshot()["generation"] as! Int
    service.skip(1)
    prepareCurrent(service)
    transport.holdSubtitles = true
    var results: [String?] = []

    service.requestSubtitle(path: "captions.srt", session: openingSession) { results.append($0) }

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first!, "track_selection_stale")
    XCTAssertTrue(transport.subtitles.isEmpty)
    XCTAssertEqual(service.snapshot()["subtitleName"] as? String, "")
    XCTAssertEqual(service.currentPath, "b.mkv")
  }

  func testExternalSubtitleCannotLoadIntoAnUnreadySession() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    service.skip(1)
    transport.holdSubtitles = true
    var result: String?
    service.requestSubtitle(path: "captions.srt", session: service.snapshot()["generation"] as! Int) {
      result = $0
    }
    XCTAssertEqual(result, "track_selection_stale")
    XCTAssertTrue(transport.subtitles.isEmpty)
  }

  func testLateExternalSubtitleResultCannotRenameNewMediaSubtitle() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    transport.holdSubtitles = true
    var results: [String?] = []
    service.requestSubtitle(path: "captions.srt", session: service.snapshot()["generation"] as! Int) {
      results.append($0)
    }
    XCTAssertEqual(transport.subtitles.count, 1)
    XCTAssertTrue(results.isEmpty)
    service.skip(1)
    prepareCurrent(service)
    transport.subtitles[0](true)

    XCTAssertEqual(results.count, 1)
    XCTAssertEqual(results.first!, "control_superseded")
    XCTAssertEqual(service.snapshot()["subtitleName"] as? String, "")
  }

  func testMatchingExternalSubtitleWaitsForEngineSuccess() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    transport.holdSubtitles = true
    var results: [String?] = []
    service.requestSubtitle(path: "captions.srt", session: service.snapshot()["generation"] as! Int) {
      results.append($0)
    }
    XCTAssertTrue(results.isEmpty)
    XCTAssertEqual(service.snapshot()["subtitleName"] as? String, "")
    transport.subtitles[0](true)
    XCTAssertEqual(results.count, 1)
    XCTAssertNil(results.first!)
    XCTAssertEqual(service.snapshot()["subtitleName"] as? String, "captions.srt")
  }

  func testConcurrentSeeksSettleSupersededAndLatestRequestsOnce() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    transport.holdSeeks = true
    var first: [Bool] = [], second: [Bool] = [], third: [Bool] = []
    service.seek(20) { first.append($0) }
    service.seek(40) { second.append($0) }
    service.seek(60) { third.append($0) }
    XCTAssertTrue(first.isEmpty)
    XCTAssertEqual(second, [false])
    XCTAssertTrue(third.isEmpty)
    XCTAssertEqual(transport.seeks.count, 1)
    transport.seeks[0].finish(true)
    XCTAssertEqual(first, [false])
    XCTAssertEqual(transport.seeks.count, 2)
    XCTAssertEqual(transport.seeks[1].seconds, 60)
    transport.seeks[0].finish(true)
    transport.seeks[1].finish(true)
    transport.seeks[1].finish(false)
    XCTAssertEqual(first, [false])
    XCTAssertEqual(second, [false])
    XCTAssertEqual(third, [true])
  }

  func testSwitchingMediaCancelsActiveAndPendingSeeksBeforeLateResult() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    transport.holdSeeks = true
    var first: [Bool] = [], second: [Bool] = []
    service.seek(20) { first.append($0) }
    service.seek(40) { second.append($0) }
    service.skip(1)
    XCTAssertEqual(first, [false])
    XCTAssertEqual(second, [false])
    transport.seeks[0].finish(true)
    XCTAssertEqual(first, [false])
    XCTAssertEqual(second, [false])
    XCTAssertEqual(service.currentPath, "b.mkv")
  }

  func testSeekFailureSettlesOnceAndDoesNotReportSuccess() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    transport.holdSeeks = true
    var results: [Bool] = []
    service.seek(20) { results.append($0) }
    transport.seeks[0].finish(false)
    transport.seeks[0].finish(true)
    XCTAssertEqual(results, [false])
    XCTAssertEqual(service.snapshot()["error"] as? String, "seek_failed")
  }

  func testSeekTimeoutSettlesBeforeLateEngineResult() throws {
    let transport = PlaybackTestTransport()
    let service = try makeService(transport)
    transport.holdSeeks = true
    let timedOut = expectation(description: "seek timeout")
    var results: [Bool] = []
    service.seek(20) {
      results.append($0)
      timedOut.fulfill()
    }
    wait(for: [timedOut], timeout: 10)
    XCTAssertEqual(results, [false])
    XCTAssertEqual(service.snapshot()["error"] as? String, "seek_timeout")
    transport.seeks[0].finish(true)
    XCTAssertEqual(results, [false])
  }

  func testDestroyingServiceCancelsOutstandingSeek() throws {
    let transport = PlaybackTestTransport()
    var service: PlaybackService? = try makeService(transport)
    weak var releasedService = service
    transport.holdSeeks = true
    var results: [Bool] = []
    service?.seek(20) { results.append($0) }
    service = nil
    XCTAssertNil(releasedService)
    XCTAssertEqual(results, [false])
    transport.seeks[0].finish(true)
    XCTAssertEqual(results, [false])
  }
}
