import XCTest
import AVFoundation
import UIKit
@testable import Runner

/// Independent service-level regression tests. The transport holds real service
/// continuations and supplies protocol-stamped state, rather than reimplementing
/// the EOF/replay decision logic in the test.
private final class ReplayReviewTransport {
  struct Seek {
    let seconds: Double
    let arguments: [String: Any]
    let finish: (Bool) -> Void
  }

  var commands: [String] = []
  var requestedSeeks: [Double] = []
  var heldSeeks: [Seek] = []
  var holdSeeks = false
  var positionVersion = 0
  var snapshotSequence = 0
  var engineID = ""

  func send(_ method: String, _ arguments: [String: Any], _ finish: @escaping (Bool) -> Void) {
    commands.append(method)
    if method == "open" {
      engineID = arguments["engineId"] as? String ?? ""
      snapshotSequence = 0
    }
    if let version = arguments["positionVersion"] as? Int { positionVersion = version }
    if method == "seek" {
      let seconds = (arguments["seconds"] as? NSNumber)?.doubleValue ?? -1
      requestedSeeks.append(seconds)
      if holdSeeks {
        heldSeeks.append(Seek(seconds: seconds, arguments: arguments, finish: finish))
        return
      }
    }
    finish(true)
  }

  func state(_ values: [String: Any], version: Int? = nil, sequence: Int? = nil,
             engineID: String? = nil) -> [String: Any] {
    snapshotSequence += 1
    var result = values
    result["engineId"] = engineID ?? self.engineID
    result["positionVersion"] = version ?? positionVersion
    result["snapshotSequence"] = sequence ?? snapshotSequence
    return result
  }

  var opens: Int { commands.filter { $0 == "open" }.count }
  var releases: Int { commands.filter { $0 == "release" }.count }
  var plays: Int { commands.filter { $0 == "play" }.count }
}

final class ReplayLifecycleReviewTests: XCTestCase {
  private var temporary: URL!
  private var library: CourseLibrary!
  private var transport: ReplayReviewTransport!
  private var savedDefaults: [String: Any] = [:]
  private let preferenceKeys = [
    "playback.rememberProgress", "playback.smartIntro", "playback.continuous",
    "playback.background", "playback.mode", "playback.resume",
  ]

  override func setUpWithError() throws {
    for key in preferenceKeys {
      if let value = UserDefaults.standard.object(forKey: key) { savedDefaults[key] = value }
    }
    UserDefaults.standard.set(true, forKey: "playback.rememberProgress")
    UserDefaults.standard.set(false, forKey: "playback.smartIntro")
    UserDefaults.standard.set(false, forKey: "playback.continuous")
    UserDefaults.standard.set(true, forKey: "playback.background")
    UserDefaults.standard.set(true, forKey: "playback.resume")
    UserDefaults.standard.set("folder", forKey: "playback.mode")
    temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("LeiPlayerReplayReview-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    transport = ReplayReviewTransport()
  }

  override func tearDownWithError() throws {
    for key in preferenceKeys {
      if let value = savedDefaults[key] { UserDefaults.standard.set(value, forKey: key) }
      else { UserDefaults.standard.removeObject(forKey: key) }
    }
    savedDefaults.removeAll()
    try? FileManager.default.removeItem(at: temporary)
  }

  private func makeService(paths: [String] = ["a.mkv", "b.mkv"]) throws -> PlaybackService {
    let root = temporary.appendingPathComponent("Documents", isDirectory: true)
    library = try CourseLibrary(root: root, support: temporary.appendingPathComponent("Support"))
    for path in paths { try Data("test media".utf8).write(to: root.appendingPathComponent(path)) }
    let loaded = expectation(description: "records loaded")
    library.recordStore.afterInitialLoad { loaded.fulfill() }
    wait(for: [loaded], timeout: 2)
    let service = PlaybackService(library: library)
    let transport = self.transport!
    service.mediaKitTransport = { transport.send($0, $1, $2) }
    try service.open(paths: paths, selected: 0, resume: false)
    waitUntil { service.mediaKitEngineId != nil }
    service.pause()
    send(["ready": true, "duration": 120.0, "position": 0.0,
          "seekable": true, "playing": false, "ended": false], to: service)
    waitUntil { !transport.requestedSeeks.isEmpty }
    drainMainQueue()
    send(["position": 0.0, "ended": false], to: service)
    return service
  }

  private func send(_ values: [String: Any], to service: PlaybackService,
                    version: Int? = nil, sequence: Int? = nil, engineID: String? = nil) {
    service.receiveMediaKitState(transport.state(values, version: version,
      sequence: sequence, engineID: engineID))
  }

  private func configure(_ values: [String: Any], service: PlaybackService) {
    let configured = expectation(description: "configuration acknowledged")
    service.requestConfiguration(values) { error in
      XCTAssertNil(error)
      configured.fulfill()
    }
    wait(for: [configured], timeout: 2)
  }

  private func settle(_ index: Int, service: PlaybackService, position: Double,
                      ended: Bool = false, success: Bool = true) throws {
    let request = try XCTUnwrap(transport.heldSeeks.indices.contains(index)
      ? transport.heldSeeks[index] : nil)
    send(["position": position, "ended": ended, "playing": false], to: service)
    request.finish(success)
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

  func testEOFDuringSeekAwayIsDiscardedAfterFinalPositionAcknowledgment() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    let engine = service.mediaKitEngineId
    let opens = transport.opens
    let releases = transport.releases
    var results: [Bool] = []
    service.seek(35) { results.append($0) }
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    try settle(0, service: service, position: 35)
    XCTAssertEqual(results, [true])
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(service.position, 35)
    XCTAssertEqual(service.mediaKitEngineId, engine)
    XCTAssertEqual(transport.opens, opens)
    XCTAssertEqual(transport.releases, releases)
  }

  func testDuplicateEOFStartsOneHeldReplayWithoutReplacingHealthySession() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    let engine = service.mediaKitEngineId
    let player = service.player
    let opens = transport.opens
    let releases = transport.releases
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(transport.heldSeeks.first?.seconds, 0)
    send(["position": 120.0, "ended": true], to: service)
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    try settle(0, service: service, position: 0)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(service.mediaKitEngineId, engine)
    XCTAssertTrue(service.player === player)
    XCTAssertEqual(transport.opens, opens)
    XCTAssertEqual(transport.releases, releases)
  }

  func testEndZeroEndUsesLatestSeekAndReplaysOnlyFinalEnd() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    var first: [Bool] = [], middle: [Bool] = [], last: [Bool] = []
    let opens = transport.opens
    service.seek(120) { first.append($0) }
    send(["position": 119.999, "ended": true], to: service)
    service.seek(0) { middle.append($0) }
    service.seek(120) { last.append($0) }
    XCTAssertEqual(middle, [false])
    try settle(0, service: service, position: 119.999, ended: true)
    XCTAssertEqual(first, [false])
    XCTAssertEqual(transport.heldSeeks.count, 2)
    try settle(1, service: service, position: 119.999, ended: true)
    XCTAssertEqual(last, [true])
    XCTAssertEqual(transport.heldSeeks.count, 3)
    XCTAssertEqual(transport.heldSeeks[2].seconds, 0)
    try settle(2, service: service, position: 0)
    XCTAssertEqual(transport.opens, opens)
    XCTAssertEqual(transport.heldSeeks.count, 3)
  }

  func testNearEndOrdinarySeekDoesNotBecomeReplay() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    let opens = transport.opens
    service.seek(119.95)
    try settle(0, service: service, position: 119.95)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(transport.opens, opens)
    XCTAssertEqual(service.position, 119.95)
  }

  func testEOFWhilePausedWaitsForExplicitPlayThenReusesSession() throws {
    let service = try makeService()
    transport.holdSeeks = true
    let engine = service.mediaKitEngineId
    let opens = transport.opens
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(transport.heldSeeks.count, 0)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    service.play()
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(transport.heldSeeks.first?.seconds, 0)
    try settle(0, service: service, position: 0)
    XCTAssertEqual(service.mediaKitEngineId, engine)
    XCTAssertEqual(transport.opens, opens)
  }

  func testPauseDuringReplayPreventsCompletionFromResumingPlayback() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    send(["position": 120.0, "ended": true], to: service)
    service.pause()
    let plays = transport.plays
    try settle(0, service: service, position: 0)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertEqual(transport.plays, plays)
  }

  func testBackgroundDisabledDuringReplayPreventsCompletionFromResuming() throws {
    let service = try makeService()
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    configure(["mode": "one", "continuous": true, "background": false], service: service)
    service.play()
    transport.holdSeeks = true
    send(["position": 120.0, "ended": true], to: service)
    NotificationCenter.default.post(name: UIApplication.didEnterBackgroundNotification, object: nil)
    let plays = transport.plays
    try settle(0, service: service, position: 0)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertEqual(transport.plays, plays)
    NotificationCenter.default.post(name: UIApplication.didBecomeActiveNotification, object: nil)
    XCTAssertEqual(transport.plays, plays)
  }

  func testReplayFailureReportsErrorWithoutAutomaticReloadOrLateResume() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    let opens = transport.opens
    send(["position": 120.0, "ended": true], to: service)
    let replay = try XCTUnwrap(transport.heldSeeks.first)
    replay.finish(false)
    drainMainQueue()
    let plays = transport.plays
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertFalse((service.snapshot()["error"] as? String ?? "").isEmpty)
    replay.finish(true)
    drainMainQueue()
    XCTAssertEqual(transport.opens, opens)
    XCTAssertEqual(transport.plays, plays)
  }

  func testOldVersionAndReversedSnapshotCannotRestoreEOFOrFailure() throws {
    let service = try makeService()
    service.play()
    let oldVersion = transport.positionVersion
    transport.holdSeeks = true
    service.seek(35)
    try settle(0, service: service, position: 35)
    let currentSequence = transport.snapshotSequence
    send(["position": 120.0, "ended": true, "failure": "old_seek_error"],
         to: service, version: oldVersion, sequence: currentSequence + 100)
    XCTAssertEqual(service.position, 35)
    XCTAssertEqual(service.snapshot()["error"] as? String, "")
    send(["position": 120.0, "ended": true, "failure": "old_snapshot_error"],
         to: service, sequence: currentSequence - 1)
    XCTAssertEqual(service.position, 35)
    XCTAssertEqual(service.snapshot()["error"] as? String, "")
  }

  func testFalseSeekCallbackOpeningAnotherItemDoesNotPoisonNewSession() throws {
    let service = try makeService()
    transport.holdSeeks = true
    var results: [Bool] = []
    service.seek(35) { success in
      results.append(success)
      if !success { service.skip(1) }
    }
    let first = try XCTUnwrap(transport.heldSeeks.first)
    first.finish(false)
    drainMainQueue()
    waitUntil { service.currentPath == "b.mkv" && service.mediaKitEngineId != nil }
    XCTAssertEqual(results, [false])
    XCTAssertEqual(service.snapshot()["error"] as? String, "")
    first.finish(true)
    XCTAssertEqual(results, [false])
    XCTAssertEqual(service.currentPath, "b.mkv")
  }

  func testSupersededPendingCallbackChangingItemSettlesEveryRequestOnce() throws {
    let service = try makeService()
    transport.holdSeeks = true
    var first: [Bool] = [], second: [Bool] = [], third: [Bool] = []
    service.seek(20) { first.append($0) }
    service.seek(40) { success in
      second.append(success)
      if !success { service.skip(1) }
    }
    service.seek(60) { third.append($0) }
    drainMainQueue()
    XCTAssertEqual(first, [false])
    XCTAssertEqual(second, [false])
    XCTAssertEqual(third, [false])
    XCTAssertEqual(service.currentPath, "b.mkv")
    XCTAssertEqual(service.snapshot()["error"] as? String, "")
    transport.heldSeeks.first?.finish(true)
    XCTAssertEqual(first, [false])
    XCTAssertEqual(second, [false])
    XCTAssertEqual(third, [false])
  }

  func testSingleEntryFolderLoopUsesReplayWithoutOpeningAgain() throws {
    let service = try makeService(paths: ["a.mkv"])
    configure(["mode": "folder", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    let opens = transport.opens
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(transport.heldSeeks.first?.seconds, 0)
    XCTAssertEqual(transport.opens, opens)
    XCTAssertEqual(service.currentPath, "a.mkv")
  }

  func testSequenceEndStopsAndExplicitPlayReplaysWithoutOpeningAgain() throws {
    let service = try makeService(paths: ["a.mkv"])
    configure(["mode": "sequence", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    let opens = transport.opens
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertEqual(transport.heldSeeks.count, 0)
    service.play()
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(transport.heldSeeks.first?.seconds, 0)
    XCTAssertEqual(transport.opens, opens)
  }

  private func playbackRecord() -> [String: Any] {
    let read = expectation(description: "current playback record")
    var result: [String: Any] = [:]
    library.recordStore.readPlaybackRecord(path: "a.mkv") { result = $0; read.fulfill() }
    wait(for: [read], timeout: 2)
    return result
  }

  func testABEndpointSeeksAWithoutCompletingEpisodeOrReplacingSession() throws {
    let service = try makeService()
    send(["position": 20.0, "ended": false], to: service)
    configure(["ab": "a"], service: service)
    send(["position": 40.0, "ended": false], to: service)
    configure(["ab": "b"], service: service)
    send(["position": 20.0, "ended": false], to: service)
    service.persist()
    XCTAssertEqual(playbackRecord()["completed"] as? Bool, false)
    service.play()
    transport.holdSeeks = true
    let opens = transport.opens
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(transport.heldSeeks.first?.seconds, 20)
    XCTAssertEqual(playbackRecord()["completed"] as? Bool, false)
    try settle(0, service: service, position: 20)
    XCTAssertEqual(playbackRecord()["completed"] as? Bool, false)
    XCTAssertEqual(playbackRecord()["position"] as? Double, 20)
    XCTAssertEqual(transport.opens, opens)
  }

  func testNonSeekableEOFReportsFailureRatherThanReloadingInLoop() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    send(["position": 30.0, "playing": true, "seekable": false], to: service)
    let opens = transport.opens
    let seeks = transport.requestedSeeks.count
    send(["position": 120.0, "ended": true, "playing": false], to: service)
    drainMainQueue()
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertFalse((service.snapshot()["error"] as? String ?? "").isEmpty)
    XCTAssertEqual(transport.opens, opens)
    XCTAssertEqual(transport.requestedSeeks.count, seeks)
  }

  func testContinuousDisabledStopsEvenInSingleRepeatMode() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": false], service: service)
    service.play()
    transport.holdSeeks = true
    let opens = transport.opens
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertTrue(transport.heldSeeks.isEmpty)
    XCTAssertEqual(transport.opens, opens)
  }

  func testShuffleWithTwoEntriesAdvancesToAnotherItemOnce() throws {
    let service = try makeService()
    configure(["mode": "shuffle", "continuous": true], service: service)
    service.play()
    let oldEngine = try XCTUnwrap(service.mediaKitEngineId)
    let oldVersion = transport.positionVersion
    let opens = transport.opens
    send(["position": 120.0, "ended": true], to: service)
    waitUntil { service.currentPath == "b.mkv" && service.mediaKitEngineId != oldEngine }
    send(["position": 120.0, "ended": true], to: service,
         version: oldVersion, engineID: oldEngine)
    XCTAssertEqual(service.currentPath, "b.mkv")
    XCTAssertEqual(transport.opens, opens + 1)
  }


  private func interruption(_ type: AVAudioSession.InterruptionType,
                            shouldResume: Bool = false) {
    NotificationCenter.default.post(name: AVAudioSession.interruptionNotification,
      object: nil, userInfo: [
        AVAudioSessionInterruptionTypeKey: type.rawValue,
        AVAudioSessionInterruptionOptionKey:
          shouldResume ? AVAudioSession.InterruptionOptions.shouldResume.rawValue : UInt(0),
      ])
  }

  func testEOFAtInterruptionResumesWithOneReplayWhenSystemPermits() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    let opens = transport.opens
    interruption(.began)
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertTrue(transport.heldSeeks.isEmpty)
    interruption(.ended, shouldResume: true)
    XCTAssertEqual(transport.heldSeeks.count, 1)
    XCTAssertEqual(transport.heldSeeks.first?.seconds, 0)
    try settle(0, service: service, position: 0)
    XCTAssertEqual(transport.opens, opens)
  }

  func testEOFAtInterruptionResumesAccordingToSequenceMode() throws {
    let service = try makeService()
    configure(["mode": "sequence", "continuous": true], service: service)
    service.play()
    let oldEngine = service.mediaKitEngineId
    interruption(.began)
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(service.currentPath, "a.mkv")
    interruption(.ended, shouldResume: true)
    waitUntil { service.currentPath == "b.mkv" && service.mediaKitEngineId != oldEngine }
    XCTAssertEqual(service.currentPath, "b.mkv")
  }

  func testEOFDuringInterruptionDoesNotReplayWithoutSystemResumePermission() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    interruption(.began)
    send(["position": 120.0, "ended": true], to: service)
    let plays = transport.plays
    interruption(.ended, shouldResume: false)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertTrue(transport.heldSeeks.isEmpty)
    XCTAssertEqual(transport.plays, plays)
  }


  func testEOFAtInterruptionResumesAccordingToFolderMode() throws {
    let service = try makeService()
    configure(["mode": "folder", "continuous": true], service: service)
    service.play()
    let oldEngine = service.mediaKitEngineId
    interruption(.began)
    send(["position": 120.0, "ended": true], to: service)
    XCTAssertEqual(service.currentPath, "a.mkv")
    interruption(.ended, shouldResume: true)
    waitUntil { service.currentPath == "b.mkv" && service.mediaKitEngineId != oldEngine }
    XCTAssertEqual(service.currentPath, "b.mkv")
  }

  func testEOFDuringInterruptionStillHonorsContinuousDisabledOnResume() throws {
    let service = try makeService()
    configure(["mode": "one", "continuous": false], service: service)
    service.play()
    transport.holdSeeks = true
    interruption(.began)
    send(["position": 120.0, "ended": true], to: service)
    let plays = transport.plays
    interruption(.ended, shouldResume: true)
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertTrue(transport.heldSeeks.isEmpty)
    XCTAssertEqual(transport.plays, plays)
  }

  func testPauseRevokesDeferredEOFEvenWhenInterruptionLaterPermitsResume() throws {
    let service = try makeService()
    configure(["mode": "folder", "continuous": true], service: service)
    service.play()
    transport.holdSeeks = true
    interruption(.began)
    send(["position": 120.0, "ended": true], to: service)
    service.pause()
    let plays = transport.plays
    interruption(.ended, shouldResume: true)
    XCTAssertEqual(service.currentPath, "a.mkv")
    XCTAssertEqual(service.snapshot()["wantsPlayback"] as? Bool, false)
    XCTAssertTrue(transport.heldSeeks.isEmpty)
    XCTAssertEqual(transport.plays, plays)
  }


  func testTerminalFailureIsNotHiddenByStaleEngineBuffering() throws {
    let service = try makeService()
    service.play()
    send(["buffering": true, "failure": "media_engine_cleanup_failed"], to: service)
    let state = service.snapshot()
    XCTAssertEqual(state["error"] as? String, "media_playback_failed")
    XCTAssertTrue((service.playbackInfo()["technicalDetail"] as? String)?.contains("media_engine_cleanup_failed") == true)
    XCTAssertEqual(state["wantsPlayback"] as? Bool, false)
    XCTAssertEqual(state["seeking"] as? Bool, false)
    XCTAssertEqual(state["loading"] as? Bool, false)
  }

}
