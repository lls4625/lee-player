import XCTest
@testable import Runner

private final class PlaybackTestTransport {
  var holdSeeks = false
  var holdSubtitles = false
  var seeks: [(seconds: Double, finish: (Bool) -> Void)] = []
  var subtitles: [(Bool) -> Void] = []

  func send(_ method: String, _ arguments: [String: Any], _ finish: @escaping (Bool) -> Void) {
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

  override func setUpWithError() throws {
    temporary = FileManager.default.temporaryDirectory
      .appendingPathComponent("LeiPlayerPlaybackTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try? FileManager.default.removeItem(at: temporary)
  }

  private func makeService(_ transport: PlaybackTestTransport) throws -> PlaybackService {
    let root = temporary.appendingPathComponent("Documents", isDirectory: true)
    let support = temporary.appendingPathComponent("Support", isDirectory: true)
    let library = try CourseLibrary(root: root, support: support)
    for path in ["a.mkv", "b.mkv", "captions.srt"] {
      try Data("1\n00:00:00,000 --> 00:00:05,000\nCaption\n".utf8)
        .write(to: root.appendingPathComponent(path))
    }
    let service = PlaybackService(library: library)
    service.mediaKitTransport = { method, arguments, completion in
      transport.send(method, arguments, completion)
    }
    try service.open(paths: ["a.mkv", "b.mkv"], selected: 0, resume: false)
    prepareCurrent(service)
    return service
  }

  private func prepareCurrent(_ service: PlaybackService) {
    service.pause()
    service.receiveMediaKitState([
      "engineId": service.mediaKitEngineId!, "ready": true,
      "duration": 120.0, "position": 0.0, "seekable": true, "playing": false,
    ])
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
