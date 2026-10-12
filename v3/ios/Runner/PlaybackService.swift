import AVFoundation
import AVKit
import MediaPlayer
import UIKit
import CryptoKit

enum AVPlayerPiPTerminal: String {
  case didStop
  case failedToStart
}

/// Volatile position only, not a persisted history record or full track/AB snapshot.
/// It belongs to one explicit media selection, even when that selection is reloaded.
struct CurrentSessionCheckpoint {
  let sessionID: UUID
  let path: String
  let generation: Int
  let engineID: String?
  let sourcePosition: Double

  func position(sessionID: UUID, path: String, origin: Double, duration: Double) -> Double? {
    guard self.sessionID == sessionID, self.path == path,
          sourcePosition.isFinite, sourcePosition >= 0,
          origin.isFinite, origin >= 0, duration.isFinite, duration > 0 else { return nil }
    // Recovery keeps valid positions near EOF. History's duration-2 filter
    // must not turn a live-session checkpoint into an invented zero start.
    return min(duration, max(0, sourcePosition - origin))
  }
}

struct CurrentSessionPositionRestore {
  let id: UUID
  let checkpoint: CurrentSessionCheckpoint
  let sourceEngineID: String
  let targetGeneration: Int
  var targetEngineID: String?
  var seekIssued = false
}

struct NativePlaybackTiming {
  private(set) var generation = -1
  private(set) var tickCount = 0
  private(set) var gapCount = 0
  private(set) var maxGapExcessMs = 0.0
  private(set) var audioActivateCount = 0
  private(set) var audioDeactivateCount = 0
  private(set) var audioLastReason = ""
  private var lastTick: Double?

  mutating func resetIfNeeded(generation: Int) {
    guard self.generation != generation else { return }
    self = NativePlaybackTiming()
    self.generation = generation
  }
  mutating func clearTickBaseline() { lastTick = nil }
  mutating func observeTick(now: Double, eligible: Bool, generation: Int) {
    resetIfNeeded(generation: generation)
    guard eligible else { clearTickBaseline(); return }
    tickCount += 1
    if let lastTick {
      gapCount += 1
      maxGapExcessMs = max(maxGapExcessMs, max(0, now - lastTick - 0.25) * 1000)
    }
    lastTick = now
  }
  mutating func recordAudioCall(activate: Bool, reason: String, generation: Int) {
    resetIfNeeded(generation: generation)
    if activate { audioActivateCount += 1 } else { audioDeactivateCount += 1 }
    audioLastReason = String(reason.prefix(64))
  }
  var diagnostics: [String: Any] {
    ["schema": 1, "generation": generation, "scope": "foreground-playing-no-seek",
     "tickCount": tickCount, "gapCount": gapCount, "maxGapExcessMs": maxGapExcessMs,
     "audioActivateCount": audioActivateCount, "audioDeactivateCount": audioDeactivateCount,
     "audioLastReason": audioLastReason]
  }
}

struct AudioRecoveryRetryPolicy {
  static let delays: [TimeInterval] = [0.25, 0.75, 1.5]
  static func delay(forAttempt attempt: Int) -> TimeInterval? {
    guard delays.indices.contains(attempt) else { return nil }
    return delays[attempt]
  }
}

/// One playback-environment rule for both engines. Inactive UI (Control Center,
/// dialogs, page changes) is deliberately not an actual background transition.
struct BackgroundPlaybackPolicy {
  static func permitsPlayback(backgroundEnabled: Bool, inBackground: Bool,
                              session: Int, pipSession: Int?, pipActive: Bool,
                              pipDeadline: Double?, now: Double) -> Bool {
    if !inBackground || backgroundEnabled { return true }
    guard pipSession == session else { return false }
    return pipActive || pipDeadline.map { now < $0 } == true
  }
}

/// Recovery is a one-shot repair of the current user playback task, never a
/// reason to take output ownership away from an in-flight PiP presentation.
struct MediaKitDecoderRecoveryPolicy {
  static func permitsRequest(identityMatches: Bool, active: Bool, wantsPlayback: Bool,
                             stable: Bool, presentationOwned: Bool,
                             attempted: Bool, recovering: Bool) -> Bool {
    identityMatches && active && wantsPlayback && stable
      && !presentationOwned && !attempted && !recovering
  }
}

/// Keep ordinary foreground repair separate from the first-load attachment.
/// These rules do not change playback intent or rebuild an AVPlayer/item.
struct AVPlayerPresentationPolicy {
  static func permitsAttachment(active: Bool, authorized: Bool, pipActive: Bool) -> Bool {
    active || authorized || pipActive
  }

  static func permitsForegroundRepair(active: Bool, validItem: Bool, hasSurface: Bool,
                                      replacing: Bool, starting: Bool, pipActive: Bool,
                                      retiring: Bool) -> Bool {
    active && validItem && hasSurface && !replacing && !starting && !pipActive && !retiring
  }

  static func requiresTerminal(startIssued: Bool, startObserved: Bool, active: Bool) -> Bool {
    startIssued || startObserved || active
  }
}

/// EOF notifications have item identity, but no trustworthy playback-pass ID.
/// Treat them as hints; only the current, settled timeline can consume one.
struct PlaybackEndGate {
  private(set) var candidate = false
  private(set) var armed = true
  private(set) var explicitEndOperation: Int?
  private(set) var consumedOperation: Int?

  static func tolerance(_ duration: Double) -> Double { min(0.005, duration * 0.001) }
  static func isAtEnd(_ position: Double, duration: Double) -> Bool {
    duration.isFinite && duration > 0 && position.isFinite && position > 0
      && position >= duration - tolerance(duration)
  }
  static func seekTarget(_ seconds: Double, duration: Double) -> Double {
    min(max(0, duration - 0.001), max(0, seconds))
  }
  mutating func offer() { candidate = true }
  mutating func beginOperation() { explicitEndOperation = nil }
  mutating func settled(operation: Int, rawTarget: Double, position: Double, duration: Double,
                        confirmedEngineEnd: Bool = false, endpointSeekTolerance: Double? = nil) {
    guard duration.isFinite, duration > 0, position.isFinite else { return }
    // A successfully positioned new playback pass may itself end on a frame
    // before duration. Do not leave it disarmed by the preceding pass's EOF.
    if consumedOperation != operation, confirmedEngineEnd || endpointSeekTolerance != nil {
      armed = true
    }
    // The raw target is retained before clamp; a near-end seek is not EOF.
    if rawTarget >= duration,
       abs(position - Self.seekTarget(rawTarget, duration: duration)) <= (endpointSeekTolerance ?? max(0.002, Self.tolerance(duration))) {
      explicitEndOperation = operation
    } else {
      explicitEndOperation = nil
      if !confirmedEngineEnd && !Self.isAtEnd(position, duration: duration) {
        candidate = false; armed = true; consumedOperation = nil
      }
    }
  }
  mutating func consume(operation: Int, position: Double, duration: Double, confirmedEngineEnd: Bool = false) -> Bool {
    if explicitEndOperation == operation, consumedOperation != operation {
      candidate = false; armed = false; consumedOperation = operation
      explicitEndOperation = nil
      return true
    }
    guard candidate else { return false }
    candidate = false
    // libmpv EOF is authoritative after the Dart seek/snapshot fences. Its
    // final output timestamp need not equal container duration (last frame).
    // AVPlayer notifications retain the original strict timeline check.
    guard armed, confirmedEngineEnd || Self.isAtEnd(position, duration: duration) else { return false }
    armed = false; consumedOperation = operation
    return true
  }
}

/// Shared wire contract with MediaKitSnapshotFence on the Dart side.
struct PlaybackSnapshotGate {
  private(set) var positionVersion = 0
  private(set) var sequence = -1
  mutating func advance() { positionVersion += 1; sequence = -1 }
  mutating func accepts(_ state: [String: Any]) -> Bool {
    guard let version = state["positionVersion"] as? NSNumber,
      let next = state["snapshotSequence"] as? NSNumber,
      version.intValue == positionVersion, next.intValue > sequence else { return false }
    sequence = next.intValue
    return true
  }
}

final class LeeMediaKitEngine {
  let id = UUID().uuidString
  var changed: (() -> Void)?
  private let transport: (String, [String: Any], @escaping (Bool) -> Void) -> Void
  private var opened = false
  private(set) var playIntentVersion = 0
  private var stopped = false
  private var snapshots = PlaybackSnapshotGate()
  private let startedAt = ProcessInfo.processInfo.systemUptime
  private var controls: [String] = []
  private var engineDiagnostics: [String: Any] = [:]
  private(set) var position = 0.0
  private(set) var duration = 0.0
  private(set) var playing = false
  private(set) var ready = false
  private(set) var buffering = false
  private(set) var ended = false
  private(set) var seekable = false
  private(set) var seekabilityKnown = false
  private(set) var failure = ""
  private(set) var trackState: [String: Any] = [:]
  var rate: Float = 1
  var volume: Float = 1
  func control(_ method: String, arguments: [String: Any], completion: @escaping (Bool) -> Void) {
    guard !stopped, ready else { completion(false); return }
    var values = arguments
    values["requestId"] = UUID().uuidString
    send(method, values, completion: completion)
  }

  init(transport: @escaping (String, [String: Any], @escaping (Bool) -> Void) -> Void) {
    self.transport = transport
  }

  var positionVersion: Int { snapshots.positionVersion }

  var diagnostics: [String: Any] {
    var result = engineDiagnostics
    result["sessionAge"] = ProcessInfo.processInfo.systemUptime - startedAt
    result["controlEvents"] = controls
    return result
  }

  private func send(_ method: String, _ arguments: [String: Any] = [:], completion: ((Bool) -> Void)? = nil) {
    guard !stopped else { completion?(false); return }
    var args = arguments
    args["engineId"] = id
    args["positionVersion"] = snapshots.positionVersion
    if args["requestId"] == nil { args["requestId"] = UUID().uuidString }
    transport(method, args) { [weak self] success in
      guard let self = self, !self.stopped else { completion?(false); return }
      if !success {
        self.recordDiagnostic("\(method) rejected")
        if method == "open" {
          self.failure = "media_kit_open_failed"
          self.changed?()
        }
      }
      completion?(success)
    }
  }

  func open(url: URL, isAudio: Bool) {
    opened = true
    recordDiagnostic("open")
    send("open", ["url": url.absoluteString, "isAudio": isAudio, "rate": Double(rate), "volume": Double(volume)])
  }

  func pausePlayback(completion: ((Bool) -> Void)? = nil) {
    playIntentVersion += 1
    send("pause", completion: completion); recordDiagnostic("pause")
  }
  func resumePlayback(completion: @escaping (Bool) -> Void) {
    playIntentVersion += 1
    send("play", completion: completion); recordDiagnostic("resume")
  }
  func stopPlayback() {
    guard !stopped else { return }
    stopped = true; changed = nil
    transport("stop", ["engineId": id]) { _ in }
  }

  func seek(seconds: Double, completion: @escaping (Bool) -> Void) {
    snapshots.advance()
    ended = false
    send("seek", ["seconds": seconds], completion: completion)
  }

  func select(kind: String, trackID: String?) -> Bool {
    guard !stopped, ready, ["audio", "subtitle"].contains(kind) else { return false }
    let rows = trackState["\(kind)Tracks"] as? [[String: Any]] ?? []
    guard trackID == nil || rows.contains(where: { ($0["id"] as? String) == trackID }) else { return false }
    var args: [String: Any] = ["kind": kind]
    if let trackID = trackID { args["trackId"] = trackID }
    send("track", args)
    return true
  }

  func select(kind: String, index: Int) -> Bool {
    if index == -1 { return select(kind: kind, trackID: nil) }
    let rows = trackState["\(kind)Tracks"] as? [[String: Any]] ?? []
    guard let row = rows.first(where: { ($0["index"] as? NSNumber)?.intValue == index }),
      let trackID = row["id"] as? String else { return false }
    return select(kind: kind, trackID: trackID)
  }

  func startPiP(requestID: String, completion: @escaping (Bool) -> Void) {
    send("pip", ["requestId": requestID], completion: completion)
  }
  func restoreVideoOutput(completion: @escaping (Bool) -> Void) { send("pipRestore", completion: completion) }

  func recordDiagnostic(_ text: String) {
    controls.append(String(format: "[%.1fs] %@", ProcessInfo.processInfo.systemUptime - startedAt, text))
    if controls.count > 40 { controls.removeFirst(controls.count - 40) }
  }

  func update(_ state: [String: Any]) {
    guard !stopped, snapshots.accepts(state) else { return }
    if let value = state["position"] as? NSNumber, value.doubleValue.isFinite { position = max(0, value.doubleValue) }
    if let value = state["duration"] as? NSNumber, value.doubleValue.isFinite { duration = max(0, value.doubleValue) }
    if let value = state["playing"] as? Bool { playing = value }
    if let value = state["ready"] as? Bool { ready = value }
    if let value = state["buffering"] as? Bool, value != buffering {
      buffering = value; recordDiagnostic("buffering=\(value ? 1 : 0)")
    }
    if let value = state["ended"] as? Bool { ended = value }
    if let value = state["seekable"] as? Bool { seekable = value; seekabilityKnown = true }
    if let value = state["failure"] as? String { failure = value }
    if let value = state["tracks"] as? [String: Any] { trackState = value }
    if let value = state["diagnostics"] as? [String: Any] { engineDiagnostics = value }
    changed?()
  }
}

struct SubtitleCue {
  let start: Double
  let end: Double
  let text: String
}

final class PlaybackService: NSObject {
  private static let pipDiagnosticBuild = "pip-eof-settled-20261012-r7"
  static func matchesPiPAbort(engineID: String, requestID: String,
                              currentEngineID: String?, currentRequestID: String?) -> Bool {
    !engineID.isEmpty && !requestID.isEmpty
      && engineID == currentEngineID && requestID == currentRequestID
  }
  private(set) var player = AVPlayer()
  var mediaKitTransport: ((String, [String: Any], @escaping (Bool) -> Void) -> Void)?
  private var mediaKit: LeeMediaKitEngine?
  var restoreRequested: (() -> Void)?
  private var heartbeat: Timer?
  private var engineNotice = ""
  private var fallbackUsed = false
  // Resume eligibility belongs to the open, not to a later settings change.
  private var pendingResume = false
  private var initialPositionEstablished = false
  private var initialHistoricalSeekPending = false
  private var nonSeekableStartPosition: Double?
  private var sessionCompleted = false
  private var atPlaybackEnd = false
  private var pendingEndAction = false
  private var lastValidRememberedProgress: [String: Any]?
  private var currentSessionID = UUID()
  private var currentSessionCheckpoint: CurrentSessionCheckpoint?
  private var currentSessionPositionRestore: CurrentSessionPositionRestore?
  private var mediaVolume: Float
  private var mediaBrightness: CGFloat
  private var seekSequence = 0
  private var playbackOperation = 0
  private var endGate = PlaybackEndGate()
  private var replayOperation: Int?
  private var lifecycleEvents: [String] = []
  private var playerCreations = 1
  private var itemCreations = 0
  private var pipCreations = 0
  private var pendingReplacement: (id: UUID, controller: AVPictureInPictureController, resume: Bool, autoplay: Bool, clearOnly: Bool)?
  private var replacementTimeout: DispatchWorkItem?
  private var deferredPresentationLoad: (resume: Bool, autoplay: Bool, clearOnly: Bool)?
  private var cancellingSeeks = false
  private var activeSeek: Int?
  private var pendingSeek: (id: Int, seconds: Double, precise: Bool, done: (Bool) -> Void)?
  private var activeSeekCompletion: ((Bool) -> Void)?
  private var seekTimeout: DispatchWorkItem?
  private var scrubbing = false
  private var seekFault = false
  private var boundaryObserver: Any?
  private var preparedMediaKit = false
  private var openingTimeout: DispatchWorkItem?
  private var audioRecoveryWorkItem: DispatchWorkItem?
  private var audioRecoveryRequest: UUID?
  private var audioRecoveryPending = false
  private var audioRecoveryAttempt = 0
  private var audioRecoveryExhausted = false
  // Only retries originating in an approved interruption end depend on this
  // setting. Ordinary audio activation retries are a different operation.
  private var audioRecoveryRequiresAutoResume = false
  private var rebuildPlayerAfterMediaServicesReset = false
  private var lastDiagnostic = ""
  private var decoderRecoveryAttempted = false
  private var decoderRecoveryRequest: (id: UUID, generation: Int)?
  private var mediaIsAudio: Bool { guard let path = currentPath else { return false }; return library.audioExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
  private var enginePlaying: Bool { mediaKit?.playing ?? (player.timeControlStatus == .playing) }
  private var pipActive: Bool { mediaKitPiP?.isActive ?? (pip?.isPictureInPictureActive == true) }
  private var pipAvailable: Bool {
    !mediaIsAudio && AVPictureInPictureController.isPictureInPictureSupported()
      && (mediaKit != nil || (hasValidAVPlayerPresentationItem
        && UIApplication.shared.applicationState == .active
        && pip?.isPictureInPicturePossible == true))
  }
  private var pipRequesting: Bool {
    mediaKitPiPPreparing || mediaKitPiP != nil || mediaKitPiPRestoring
      || avPlayerPiPRequest != nil || pipStartIssued
      || pipActive || retiringPiP.keys.contains { !unconfirmedPiPStops.contains($0) }
  }
  private var isSeeking: Bool { activeSeek != nil || pendingSeek != nil }
  private func pauseEngine() {
    endInlinePiPTransportFollow()
    avPlayerTransportMutationDepth += 1
    defer { avPlayerTransportMutationDepth -= 1 }
    nativePlaybackTiming.clearTickBaseline()
    if let engine = mediaKit {
      engine.pausePlayback { [weak self, weak engine] success in
        DispatchQueue.main.async {
          guard let self, let engine, self.mediaKit === engine, success else { return }
          self.deactivateAudioSessionIfIdle()
          self.publish()
        }
      }
    } else {
      player.pause()
      deactivateAudioSessionIfIdle()
    }
  }
  private func resumeEngine(completion: @escaping (Bool) -> Void) {
    endInlinePiPTransportFollow()
    avPlayerTransportMutationDepth += 1
    defer { avPlayerTransportMutationDepth -= 1 }
    guard wantsPlayback, playbackEnvironmentAllowsPlayback, !presentationWaiting, !interrupted else {
      completion(false); return
    }
    if let mediaKit = mediaKit {
      mediaKit.rate = rate
      mediaKit.resumePlayback(completion: completion)
    } else {
      player.playImmediately(atRate: rate)
      completion(true)
    }
  }

  let library: CourseLibrary
  var changed: (([String: Any]) -> Void)?
  var surface: PlayerSurface?
  var pip: AVPictureInPictureController?
  weak var pipDelegate: AVPictureInPictureControllerDelegate?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var pipActivationTimeout: DispatchWorkItem?
  private var pipStartIssued = false
  // Only accepted presentations get a session. AVKit's didStop has no close
  // reason: a restore request is recorded separately, before restoring the UI.
  private var pipPlaybackSession: (id: UUID, controller: ObjectIdentifier, generation: Int,
    restoreToken: UUID?, stopping: Bool, inline: Bool)?
  private var pipTransportObservation: NSObjectProtocol?
  private var avPlayerTransportMutationDepth = 0
  private var avPlayerPiPRequest: (id: UUID, generation: Int, item: AVPlayerItem, layer: AVPlayerLayer, deadline: Double?)?
  // Diagnostic identities only, never strong platform-object references.
  private var avPlayerPiPTraceRequests: [(controller: ObjectIdentifier, request: UUID, generation: Int)] = []
  // Business invariant: background playback is audio-only. PiP requires an explicit button request.
  private var avPlayerPiPAuthorized = false
  private var installedAVPlayerItem: (item: AVPlayerItem, path: String, generation: Int)?
  private var mediaKitPiP: MediaKitPiPRenderer?
  private var mediaKitPiPPreparing = false
  private var mediaKitPiPRequestID: String?
  private var mediaKitPiPActiveRequestID: String?
  private var mediaKitPiPPreparationTimeout: DispatchWorkItem?
  private var mediaKitPiPRestoring = false
  private var mediaKitPiPRestoreTimeout: DispatchWorkItem?
  private var retiringPiP: [ObjectIdentifier: (controller: AVPictureInPictureController,
    renderer: MediaKitPiPRenderer?, requiresTerminal: Bool)] = [:]
  // AVKit owns these identities until a terminal delegate callback. A new
  // user-selected item may use a different, isolated output after bounded wait.
  private var retiredAVPlayerOutputs: [ObjectIdentifier: (player: AVPlayer,
    item: AVPlayerItem?, layer: AVPlayerLayer, isolated: Bool,
    rateObservation: NSKeyValueObservation?)] = [:]
  private var blockingRetiringPiP: Bool {
    // Only a positively identified, isolated AV graph is unrelated to the
    // current inline output. MK renderers and unknown owners remain fenced.
    retiringPiP.contains { key, entry in
      entry.renderer != nil || retiredAVPlayerOutputs[key]?.isolated != true
    }
  }
  private var presentationWaiting: Bool {
    if deferredPresentationLoad != nil && blockingRetiringPiP { return true }
    if mediaKitPiPRestoring { return true }
    guard let engine = mediaKit else { return false }
    return retiringPiPRestores.values.contains { $0.generation == generation && $0.engine === engine }
  }
  private var observedPiPStarts: Set<ObjectIdentifier> = []
  // Keep unsafe-to-release identities quarantined, but end the visible request
  // after the watchdog reports a failure instead of leaving the button busy.
  private var unconfirmedPiPStops: Set<ObjectIdentifier> = []
  private var retiringPiPRestores: [ObjectIdentifier: (engine: LeeMediaKitEngine, generation: Int)] = [:]
  private var retiringPiPAbortCompletions:
    [ObjectIdentifier: (token: UUID, completion: (Bool) -> Void)] = [:]

  private var hasValidAVPlayerPresentationItem: Bool {
    guard let installed = installedAVPlayerItem, let path = currentPath else { return false }
    return installed.generation == generation && installed.path == path
      && installed.item === player.currentItem && installed.item.status != .failed
      && player.status != .failed && !seekFault && errorMessage.isEmpty && mediaKit == nil
  }

  private var avPlayerPiPOwnsPresentation: Bool {
    guard let controller = pip else { return false }
    return AVPlayerPresentationPolicy.requiresTerminal(startIssued: pipStartIssued,
      startObserved: observedPiPStarts.contains(ObjectIdentifier(controller)),
      active: controller.isPictureInPictureActive)
  }

  private func discardAVPlayerPiP() {
    // Inactive does not prove an issued/observed start has finished.
    let controller = pip
    if let controller { clearPiPPlaybackSession(controller) }
    let needsRetirement = avPlayerPiPOwnsPresentation
    avPlayerPiPAuthorized = false
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
    cancelPendingAVPlayerPiP()
    // Clear ownership before stop: AVKit may synchronously deliver a terminal callback.
    pip = nil
    if let controller = controller {
      if needsRetirement {
        retirePiP(controller)
      } else {
        observedPiPStarts.remove(ObjectIdentifier(controller))
        controller.delegate = nil
      }
    }
  }

  private func prepareAVPlayerPiP() {
    // Preparation is readiness only. It never creates a request or grants
    // permission to start PiP or continue playback in the background.
    guard UIApplication.shared.applicationState == .active, mediaKit == nil,
          pendingReplacement == nil, !avPlayerPiPOwnsPresentation,
          avPlayerPiPRequest == nil, !avPlayerPiPAuthorized, retiringPiP.isEmpty,
          hasValidAVPlayerPresentationItem, !mediaIsAudio,
          AVPictureInPictureController.isPictureInPictureSupported(),
          let videoLayer = surface?.videoLayer, videoLayer.player === player else { return }
    if let controller = pip, controller.playerLayer === videoLayer {
      controller.delegate = pipDelegate
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      return
    }
    discardAVPlayerPiP()
    guard retiringPiP.isEmpty,
          let controller = AVPictureInPictureController(playerLayer: videoLayer) else { return }
    controller.delegate = pipDelegate
    controller.canStartPictureInPictureAutomaticallyFromInline = false
    pip = controller
    // ObjectIdentifier addresses can be reused after an idle controller dies.
    // A new preparation must never inherit a previous manual request's trace.
    avPlayerPiPTraceRequests.removeAll { $0.controller == ObjectIdentifier(controller) }
    pipCreations += 1
    recordLifecycle("AVPiP prepared request=none requestGeneration=\(generation) controller=\(ObjectIdentifier(controller)) main=\(Thread.isMainThread)")
    pipPossibleObservation = controller.observe(\.isPictureInPicturePossible,
                                                 options: [.initial, .new]) { [weak self, weak controller] _, _ in
      DispatchQueue.main.async {
        guard let self, let controller, self.pip === controller else { return }
        self.recordAVPlayerPiPEvent("possible KVO delivered", controller: controller)
        self.publish()
      }
    }
  }

  private func discardUnrequestedAVPlayerPiP() {
    // Clear only the idle system registration. Manual, issued, observed,
    // active, replacing and retiring presentations retain their original fences.
    guard Thread.isMainThread, mediaKit == nil, let controller = pip,
          !avPlayerPiPAuthorized, avPlayerPiPRequest == nil,
          !avPlayerPiPOwnsPresentation, pendingReplacement == nil,
          retiringPiP.isEmpty else { return }
    // Capture diagnostic values only; do not retain the source or its layer.
    let sourceMatchedCurrentLayer = (controller.contentSource?.playerLayer)
      .map { $0 === surface?.videoLayer } ?? false
    recordLifecycle("AVPiP idle source clear before controller=\(ObjectIdentifier(controller)) contentSourcePresent=\(controller.contentSource != nil) sourceMatchedCurrentLayer=\(sourceMatchedCurrentLayer)")
    // The existing discard invalidates KVO and clears ownership/delegate first.
    // Hold only this idle controller until the explicit public source release.
    discardAVPlayerPiP()
    // System state can advance between the idle check and generic cleanup.
    guard retiringPiP[ObjectIdentifier(controller)] == nil,
          !controller.isPictureInPictureActive else { return }
    controller.contentSource = nil
    // Do not read controller.playerLayer (or the source's layer) after clearing.
    recordLifecycle("AVPiP idle preparation discarded; presentation preserved sourceClear=after controller=\(ObjectIdentifier(controller)) contentSourcePresent=\(controller.contentSource != nil) sourceMatchedCurrentLayerBefore=\(sourceMatchedCurrentLayer)")
    publish()
  }

  private func beginAVPlayerPiP(delegate: AVPictureInPictureControllerDelegate) throws {
    guard pendingReplacement == nil, hasValidAVPlayerPresentationItem,
          let item = player.currentItem, let videoLayer = surface?.videoLayer,
          videoLayer.player === player else { throw LibraryFailure.app("pip_video_not_ready") }
    prepareAVPlayerPiP()
    // Readiness can change after the UI snapshot. Leave an idle preparation
    // idle, with no delayed automatic start, busy state or failure popup.
    guard let controller = pip, controller.playerLayer === videoLayer,
          controller.isPictureInPicturePossible else { publish(); return }
    controller.delegate = delegate
    let requestID = UUID()
    avPlayerPiPRequest = (requestID, generation, item, videoLayer, nil)
    avPlayerPiPTraceRequests.append((ObjectIdentifier(controller), requestID, generation))
    if avPlayerPiPTraceRequests.count > 8 { avPlayerPiPTraceRequests.removeFirst() }
    avPlayerPiPAuthorized = true
    recordLifecycle("PiP requested id=\(requestID)")
    recordAVPlayerPiPEvent("requested", controller: controller, includeSource: true)
    startAVPlayerPiPIfPossible(controller, requestID: requestID)
  }

  private func matchesAVPlayerPiPRequest(_ controller: AVPictureInPictureController,
                                        requestID: UUID) -> Bool {
    guard pip === controller, let request = avPlayerPiPRequest,
          request.id == requestID, request.generation == generation,
          request.item === player.currentItem, request.layer.player === player,
          controller.playerLayer === request.layer,
          hasValidAVPlayerPresentationItem, pendingReplacement == nil else { return false }
    // A new surface during an already-issued handoff does not invalidate it.
    return pipStartIssued || observedPiPStarts.contains(ObjectIdentifier(controller))
      || surface?.videoLayer === request.layer
  }

  private func startAVPlayerPiPIfPossible(_ controller: AVPictureInPictureController,
                                         requestID: UUID) {
    guard pip === controller, avPlayerPiPRequest?.id == requestID, !pipStartIssued,
          !observedPiPStarts.contains(ObjectIdentifier(controller)) else { return }
    guard avPlayerPiPAuthorized, matchesAVPlayerPiPRequest(controller, requestID: requestID) else {
      recordAVPlayerPiPEvent("request invalidated before start", controller: controller)
      revokeManualPiP()
      discardAVPlayerPiP()
      publish()
      return
    }
    // Expiry limits issuing a start, not accepting an already successful one.
    guard avPlayerPiPRequest?.deadline.map({ ProcessInfo.processInfo.systemUptime < $0 }) ?? true else {
      recordAVPlayerPiPEvent("preparation expired before start", controller: controller)
      revokeManualPiP(); discardAVPlayerPiP(); publish(); return
    }
    guard controller.isPictureInPicturePossible else {
      // A second readiness sample can change after the button's first check.
      // No start was issued: clear only the request, retaining idle readiness
      // observation rather than leaving an unbounded pending authorization.
      avPlayerPiPRequest = nil
      revokeManualPiP()
      publish()
      return
    }
    pipStartIssued = true
    pipPossibleObservation?.invalidate(); pipPossibleObservation = nil
    authorizeManualPiP(seconds: 8)
    armAVPlayerPiPTimeout(controller, requestID: requestID, seconds: 8)
    recordLifecycle("PiP start issued id=\(requestID)")
    recordAVPlayerPiPEvent("start issued", controller: controller)
    // Do not require applicationState == active here: a legitimate tap may be
    // followed immediately by Home/lock while AVKit is becoming ready.
    // Capture values and a weak layer only: synchronous delegate callbacks can
    // release/replace this request while AVKit is inside startPictureInPicture.
    let callTrace = "request=\(requestID) requestGeneration=\(avPlayerPiPRequest?.generation ?? generation) controller=\(ObjectIdentifier(controller))"
    weak var callSourceLayer = avPlayerPiPRequest?.layer
    recordLifecycle("AVPiP source before start \(callTrace) \(avPlayerPiPSourceSnapshot(layer: callSourceLayer))")
    recordLifecycle("AVPiP start call before \(callTrace) main=\(Thread.isMainThread)")
    let callBegan = ProcessInfo.processInfo.systemUptime
    controller.startPictureInPicture()
    let elapsedMs = (ProcessInfo.processInfo.systemUptime - callBegan) * 1000
    // This paired return log must not depend on current ownership/trace lookup.
    recordLifecycle("AVPiP start call returned \(callTrace) main=\(Thread.isMainThread) elapsedMs=\(String(format: "%.3f", elapsedMs)) possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive) suspended=\(controller.isPictureInPictureSuspended)")
    recordLifecycle("AVPiP source after start \(callTrace) \(avPlayerPiPSourceSnapshot(layer: callSourceLayer))")
    publish()
  }

  private func armAVPlayerPiPTimeout(_ controller: AVPictureInPictureController,
                                    requestID: UUID, seconds: TimeInterval) {
    pipActivationTimeout?.cancel()
    avPlayerPiPRequest?.deadline = ProcessInfo.processInfo.systemUptime + seconds
    let timeout = DispatchWorkItem { [weak self, weak controller] in
      guard let self, let controller, self.pip === controller,
            self.avPlayerPiPRequest?.id == requestID else { return }
      self.recordAVPlayerPiPEvent("phase watchdog fired", controller: controller, includeSource: true)
      let started = self.pipStartIssued || self.observedPiPStarts.contains(ObjectIdentifier(controller))
      if controller.isPictureInPictureActive, self.avPlayerPiPAuthorized,
         self.matchesAVPlayerPiPRequest(controller, requestID: requestID) {
        // AVKit may be active before its main-queue didStart callback arrives.
        self.didStartAVPlayerPiP(controller)
        return
      }
      self.revokeManualPiP()
      self.discardAVPlayerPiP()
      self.reconcileAVPlayerPresentation(reason: "PiP request expired")
      self.recordPiPFailure(started ? "activation timed out" : "preparation timed out")
      self.publish()
    }
    pipActivationTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: timeout)
  }

  private func attachAVPlayerPresentationIfAllowed(reason: String) {
    guard pendingReplacement == nil, mediaKit == nil, !blockingRetiringPiP,
          let videoLayer = surface?.videoLayer else { return }
    guard AVPlayerPresentationPolicy.permitsAttachment(
      active: UIApplication.shared.applicationState == .active,
      authorized: avPlayerPiPAuthorized, pipActive: pipActive) else {
      // A rejected attachment must never tear down somebody else's handoff.
      recordLifecycle("attach deferred: \(reason)")
      return
    }
    if videoLayer.player !== player {
      videoLayer.player = player
      recordLifecycle("layer bound: \(reason)")
    }
    prepareAVPlayerPiP()
  }

  private func ensureAVPlayerPresentation(reason: String) {
    guard AVPlayerPresentationPolicy.permitsForegroundRepair(
      active: UIApplication.shared.applicationState == .active,
      validItem: hasValidAVPlayerPresentationItem, hasSurface: surface != nil,
      replacing: pendingReplacement != nil, starting: avPlayerPiPOwnsPresentation,
      pipActive: pipActive, retiring: blockingRetiringPiP) else { return }
    attachAVPlayerPresentationIfAllowed(reason: reason)
  }

  private func reconcileAVPlayerPresentation(reason: String) {
    // Ordinary background/inactive transitions keep the healthy layer bound.
    // The idle registration is discarded separately at willResignActive.
    ensureAVPlayerPresentation(reason: reason)
  }

  private func retirePiP(_ controller: AVPictureInPictureController, renderer: MediaKitPiPRenderer? = nil) {
    let key = ObjectIdentifier(controller)
    clearPiPPlaybackSession(controller)
    guard retiringPiP[key] == nil else { return }
    // AVPlayer callers retire only after an issued or observed start. A native
    // media_kit renderer may still be prepared without ever issuing AVKit start.
    let requiresTerminal = AVPlayerPresentationPolicy.requiresTerminal(
      startIssued: renderer?.startIssued ?? true,
      startObserved: observedPiPStarts.contains(key), active: controller.isPictureInPictureActive)
    retiringPiP[key] = (controller, renderer, requiresTerminal)
    if renderer == nil, let owner = controller.playerLayer.player {
      let layer = controller.playerLayer
      retiredAVPlayerOutputs[key] = (owner, owner.currentItem, layer, false, nil)
    }
    recordLifecycle("PiP retiring controller=\(key) terminalRequired=\(requiresTerminal)")
    if let renderer = renderer { renderer.stop() } else { controller.stopPictureInPicture() }
    // Never infer completion from isActive=false after start. The identity and
    // delegate stay alive until didStop/failedToStart rejects any late start.
    if let entry = retiringPiP[key], !entry.requiresTerminal,
       !controller.isPictureInPictureActive {
      _ = finishRetiringPiP(controller)
      return
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self = self, self.retiringPiP[key] != nil else { return }
      self.retiringPiPAbortCompletions.removeValue(forKey: key)?.completion(false)
      guard self.retiringPiP[key] != nil else { return }
      self.unconfirmedPiPStops.insert(key)
      self.recordLifecycle("PiP retirement stop unconfirmed controller=\(key)")
      // A PiP transaction timeout is not a decoder/item failure. Preserve the
      // healthy media generation, timeline and the user's current play intent.
      self.lastDiagnostic = "PiP stop awaiting system confirmation"
      self.resumeDeferredPresentationLoadIfPossible()
      self.publish()
    }
    publish()
  }

  private func isolateRetiringAVPlayerIfNeeded() {
    guard deferredPresentationLoad != nil else { return }
    for key in Array(retiringPiP.keys) {
      guard unconfirmedPiPStops.contains(key), var output = retiredAVPlayerOutputs[key],
            !output.isolated, output.player === player else { continue }
      // Stop old observers on their actual owner before switching self.player.
      clearBoundary()
      observations.removeAll(); playerObservations.removeAll()
      output.player.isMuted = true
      output.player.pause()
      output.rateObservation = output.player.observe(\.rate, options: [.new]) { [weak owner = output.player] _, _ in
        DispatchQueue.main.async {
          // Old AVKit controls can address the quarantined player directly.
          // Never route these callbacks through PlaybackService.pause().
          guard let owner, owner.rate != 0 else { return }
          owner.isMuted = true; owner.pause()
        }
      }
      output.isolated = true
      retiredAVPlayerOutputs[key] = output
      surface?.isolateVideoLayer(output.layer)
      installedAVPlayerItem = nil
      player = AVPlayer()
      rebuildPlayerAfterMediaServicesReset = false
      playerCreations += 1
      player.volume = mediaVolume
      player.allowsExternalPlayback = false
      player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
      bindPlayerObservers()
      recordLifecycle("PiP old AVPlayer isolated; latest media may load")
    }
  }

  private func resumeDeferredPresentationLoadIfPossible() {
    guard deferredPresentationLoad != nil, pendingReplacement == nil else { return }
    isolateRetiringAVPlayerIfNeeded()
    guard !blockingRetiringPiP, let request = deferredPresentationLoad else { return }
    // Consume before calling out: synchronous callbacks and later terminals
    // must not replay an old open/clear over a newer pause, item or cancellation.
    deferredPresentationLoad = nil
    if request.clearOnly || currentPath == nil { clearPlaybackEnginesAfterMutation(); publish() }
    else { performLoad(resume: request.resume, autoplay: request.autoplay) }
  }

  func finishRetiringPiP(_ controller: AVPictureInPictureController,
                        avTerminal: AVPlayerPiPTerminal? = nil) -> Bool {
    let key = ObjectIdentifier(controller)
    guard let entry = retiringPiP[key] else { return false }
    // A delegate terminal is stronger evidence than a transient property
    // snapshot. Only AVPlayer's typed terminal bypasses this check; the MK
    // renderer and non-terminal cleanup retain their existing ownership gate.
    let confirmedAVTerminal = entry.renderer == nil && avTerminal != nil
    guard confirmedAVTerminal || !controller.isPictureInPictureActive else { return true }
    let completedCurrentOutput = retiredAVPlayerOutputs[key].map { !$0.isolated && $0.player === player } ?? false
    let completedGeneration = generation
    controller.delegate = nil
    retiringPiP.removeValue(forKey: key)
    unconfirmedPiPStops.remove(key)
    observedPiPStarts.remove(key)
    if let output = retiredAVPlayerOutputs.removeValue(forKey: key), output.isolated {
      output.rateObservation?.invalidate()
      output.player.pause()
      output.layer.player = nil
      output.player.replaceCurrentItem(with: nil)
      surface?.releaseIsolatedVideoLayer(output.layer)
    }
    recordLifecycle("PiP retirement confirmed controller=\(key)")
    retiringPiPAbortCompletions.removeValue(forKey: key)?.completion(true)
    if let restore = retiringPiPRestores.removeValue(forKey: key),
       restore.generation == generation, mediaKit === restore.engine,
       pendingReplacement == nil, mediaKitPiP == nil, !blockingRetiringPiP {
      restoreMediaKitVideoOutput()
    }
    let hadDeferredLoad = deferredPresentationLoad != nil
    resumeDeferredPresentationLoadIfPossible()
    // A mutation may have cleared the queue while preserving AVKit's resources.
    if !hadDeferredLoad, currentPath == nil, pendingReplacement == nil, !blockingRetiringPiP,
       player.currentItem != nil || mediaKit != nil {
      clearPlaybackEnginesAfterMutation()
    }
    reconcileAVPlayerPresentation(reason: "retirement confirmed")
    if completedCurrentOutput, completedGeneration == generation { resumeHealthyPlaybackAfterPiPStop() }
    publish()
    return true
  }

  private func resumeHealthyPlaybackAfterPiPStop() {
    guard pendingReplacement == nil, deferredPresentationLoad == nil,
          !blockingRetiringPiP, !presentationWaiting,
          timelineReady, !loading, !isSeeking, !scrubbing, !interrupted,
          wantsPlayback, playbackEnvironmentAllowsPlayback else { return }
    if let engine = mediaKit {
      guard engine.ready, engine.failure.isEmpty else { return }
    } else if !hasValidAVPlayerPresentationItem { return }
    // AVKit can pause the source during stop. Restore the current play intent
    // on this same healthy item; a later pause/background-off must win.
    attemptAudioRecovery()
  }

  func rejectRetiringPiPStart(_ controller: AVPictureInPictureController) -> Bool {
    let key = ObjectIdentifier(controller)
    if pip === controller || mediaKitPiP?.controller === controller
      || pendingReplacement?.controller === controller || retiringPiP[key] != nil {
      observedPiPStarts.insert(key)
    }
    guard retiringPiP[key] != nil else { return false }
    retiringPiP[key]?.requiresTerminal = true
    recordLifecycle("late PiP start rejected controller=\(key)")
    controller.stopPictureInPicture()
    return true
  }
  private var playerObservations: [NSKeyValueObservation] = []
  private var observations: [NSKeyValueObservation] = []
  private var notifications: [NSObjectProtocol] = []
  private var remoteTargets: [(MPRemoteCommand, Any)] = []
  private var queue: [String] = []
  private var index = 0
  private var wantsPlayback = false
  private var inBackground = UIApplication.shared.applicationState == .background
  private var manualPiPSession: Int?
  private var manualPiPDeadline: Double?
  private var audioSessionActivated = false
  private var nativePlaybackTiming = NativePlaybackTiming()

  private var avPlayerPiPPhaseAuthorizesBackground: Bool {
    guard mediaKit == nil, avPlayerPiPAuthorized, let controller = pip,
          let request = avPlayerPiPRequest, request.deadline != nil else { return false }
    // The phase watchdog owns expiry, including a queued success at the same
    // deadline. The heartbeat must not revoke or pause this request first.
    return matchesAVPlayerPiPRequest(controller, requestID: request.id)
  }

  private var manualPiPAllowsBackground: Bool {
    if avPlayerPiPPhaseAuthorizesBackground { return true }
    return BackgroundPlaybackPolicy.permitsPlayback(backgroundEnabled: false, inBackground: true,
      session: generation, pipSession: manualPiPSession,
      pipActive: pipActive, pipDeadline: manualPiPDeadline,
      now: ProcessInfo.processInfo.systemUptime)
  }

  private var playbackEnvironmentAllowsPlayback: Bool {
    if avPlayerPiPPhaseAuthorizesBackground { return true }
    return BackgroundPlaybackPolicy.permitsPlayback(backgroundEnabled: background, inBackground: inBackground,
      session: generation, pipSession: manualPiPSession,
      pipActive: pipActive, pipDeadline: manualPiPDeadline,
      now: ProcessInfo.processInfo.systemUptime)
  }

  private func authorizeManualPiP(seconds: Double) {
    manualPiPSession = generation
    manualPiPDeadline = ProcessInfo.processInfo.systemUptime + seconds
  }

  private func revokeManualPiP(enforce: Bool = true) {
    manualPiPSession = nil
    manualPiPDeadline = nil
    avPlayerPiPAuthorized = false
    if enforce { enforcePlaybackEnvironment() }
  }

  private func enforcePlaybackEnvironment() {
    guard !playbackEnvironmentAllowsPlayback else { return }
    pendingReplacement?.autoplay = false
    deferredPresentationLoad?.autoplay = false
    if wantsPlayback || enginePlaying || audioRecoveryPending || resumeAfterInterruption {
      pause()
    } else {
      deactivateAudioSessionIfIdle()
      updateNowPlaying()
    }
  }

  private func deactivateAudioSessionIfIdle() {
    guard audioSessionActivated, !wantsPlayback, !enginePlaying,
          !manualPiPAllowsBackground else { return }
    do {
      nativePlaybackTiming.recordAudioCall(activate: false, reason: "deactivate:idle", generation: generation)
      try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
      audioSessionActivated = false
    } catch {
      // A failed deactivation never grants playback intent or starts recovery.
      lastDiagnostic = "audio session deactivation failed: \(error.localizedDescription)"
    }
  }
  private var interrupted = false
  private var resumeAfterInterruption = false
  // iOS 15/16 do not expose routeDisconnected; correlate the paired notifications briefly.
  private var routeLossRecoveryDeadline = 0.0
  private var loading = false
  private var generation = 0
  private var assetPreparationTask: Task<Void, Never>?
  private var timelineReady = false
  private var timelineOrigin = 0.0
  private var fallbackAudio: [AVPlayerItemTrack] = []
  private var fallbackSubtitles: [AVPlayerItemTrack] = []
  private var errorMessage = ""
  private var lastSave = Date.distantPast
  private var savedBrightness: CGFloat?
  private var aPoint: Double?
  private var bPoint: Double?
  private var sleepUntil: Date?
  private var sleepTimer: Timer?
  private var cues: [SubtitleCue] = []
  private var subtitleName = ""
  private var subtitleText = ""
  private var audioOptions: [AVMediaSelectionOption] = []
  private var subtitleOptions: [AVMediaSelectionOption] = []
  private var selectedAudio = -1
  private var selectedSubtitle = -1
  private var trackSelection: (generation: Int, kind: String, id: String?, index: Int, deadline: TimeInterval, done: (String?) -> Void)?
  private var rate: Float
  private var mode: String
  private var continuous: Bool
  private var background: Bool
  private var autoResume: Bool
  private var rememberProgress: Bool
  private var rewindSeconds: Int
  private var forwardSeconds: Int
  private var fit = "fit"
  private var smartIntro: Bool
  private lazy var introScanner = IntroScanner(support: library.support)
  private var introToken = 0
  private var detectingIntro = false
  private var introSkipped = 0.0
  private var introBackgroundTask: UIBackgroundTaskIdentifier = .invalid

  var currentPath: String? { queue.indices.contains(index) ? queue[index] : nil }
  var usesMediaKit: Bool { mediaKit != nil }
  var mediaKitEngineId: String? { mediaKit?.id }
  var position: Double { let value = mediaKit?.position ?? player.currentTime().seconds; return value.isFinite ? max(0, value) : 0 }
  var duration: Double { let value = mediaKit?.duration ?? player.currentItem?.duration.seconds ?? 0; return value.isFinite ? max(0, value) : 0 }

  init(library: CourseLibrary) {
    self.library = library
    let defaults = UserDefaults.standard
    rate = Self.normalizedRate((defaults.object(forKey: "playback.rate") as? NSNumber)?.doubleValue ?? 1)
    mode = defaults.string(forKey: "playback.mode") ?? "folder"
    continuous = defaults.object(forKey: "playback.continuous") as? Bool ?? true
    background = defaults.object(forKey: "playback.background") as? Bool ?? true
    smartIntro = defaults.object(forKey: "playback.smartIntro") as? Bool ?? true
    rememberProgress = defaults.object(forKey: "playback.rememberProgress") as? Bool ?? true
    autoResume = defaults.object(forKey: "playback.resume") as? Bool ?? true
    rewindSeconds = Self.normalizedJumpSeconds((defaults.object(forKey: "playback.rewindSeconds") as? NSNumber)?.intValue ?? 15)
    forwardSeconds = Self.normalizedJumpSeconds((defaults.object(forKey: "playback.forwardSeconds") as? NSNumber)?.intValue ?? 15)
    mediaVolume = Float(min(1, max(0,
      (defaults.object(forKey: "playback.volume") as? NSNumber)?.doubleValue ?? 1)))
    mediaBrightness = CGFloat(min(1, max(0.05,
      (defaults.object(forKey: "playback.brightness") as? NSNumber)?.doubleValue
        ?? Double(UIScreen.main.brightness))))
    super.init()
    player.volume = mediaVolume
    player.allowsExternalPlayback = false
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in self?.tick() }
    heartbeat = timer
    RunLoop.main.add(timer, forMode: .common)
    bindPlayerObservers()
    let center = NotificationCenter.default
    notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] in self?.interruption($0) })
    notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      self?.routeChanged(note)
    })
    notifications.append(center.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
      self?.nativePlaybackTiming.clearTickBaseline()
      self?.discardUnrequestedAVPlayerPiP()
      self?.recordLifecycle("willResignActive: presentation preserved")
    })
    notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.inBackground = true
      self.nativePlaybackTiming.clearTickBaseline()
      self.recordLifecycle("didEnterBackground: presentation preserved")
      // Fence playback before a pending scrub/seek completion can resume it.
      self.enforcePlaybackEnvironment()
      if self.scrubbing { self.cancelScrub() }
      self.persist()
    })
    notifications.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      self?.inBackground = false
      self?.nativePlaybackTiming.clearTickBaseline()
    })
    notifications.append(center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      self.inBackground = false
      self.nativePlaybackTiming.clearTickBaseline()
      self.recordLifecycle("didBecomeActive")
      self.ensureAVPlayerPresentation(reason: "didBecomeActive")
      if self.audioRecoveryPending { self.attemptAudioRecovery() }
      self.tick()
    })
    notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
      self?.mediaServicesWereReset()
    })
    notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
      self.offerEndCandidate(source: "AVPlayerItemDidPlayToEndTime")
    })
    notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let item = note.object as? AVPlayerItem,
        item === self.player.currentItem, self.pendingReplacement == nil,
        self.deferredPresentationLoad == nil else { return }
      if let error = item.error { self.lastDiagnostic = error.localizedDescription }
      self.fail("media_playback_failed")
    })
    setupRemoteCommands()
  }

  deinit {
    assetPreparationTask?.cancel()
    sleepTimer?.invalidate()
    heartbeat?.invalidate()
    openingTimeout?.cancel(); cancelSeeks()
    audioRecoveryWorkItem?.cancel()
    mediaKitPiPRestoreTimeout?.cancel()
    replacementTimeout?.cancel()
    cancelPendingAVPlayerPiP()
    if let observation = pipTransportObservation { NotificationCenter.default.removeObserver(observation) }
    mediaKitPiP?.stop()
    mediaKit?.stopPlayback()
    if let boundary = boundaryObserver { player.removeTimeObserver(boundary) }
    notifications.forEach { NotificationCenter.default.removeObserver($0) }
    for (command, target) in remoteTargets { command.removeTarget(target) }
  }

  private var stateRevision = 0
  func snapshot() -> [String: Any] {
    let mediaKitTracks = mediaKit?.trackState ?? [:]
    return ["path": currentPath ?? "", "queue": queue, "index": index, "generation": generation,
      "revision": stateRevision, "wantsPlayback": wantsPlayback,
      "trackSelecting": trackSelection != nil, "engineId": mediaKit?.id ?? "",
      "playing": wantsPlayback && playbackEnvironmentAllowsPlayback && !presentationWaiting && enginePlaying,
      // A media fault must not remain busy because an engine retained its
      // buffering flag. PiP transaction failures do not invalidate this item.
      "loading": !presentationWaiting && !seekFault && (loading || isSeeking || (mediaKit?.buffering ?? (player.timeControlStatus == .waitingToPlayAtSpecifiedRate))),
      "seeking": isSeeking, "scrubbing": scrubbing, "isAudio": mediaIsAudio,
      "engine": mediaKit == nil ? "AVPlayer" : "media_kit", "engineNotice": engineNotice,
      "diagnostic": lastDiagnostic, "seekable": timelineReady && !seekFault && !presentationWaiting && (mediaKit?.seekable ?? true),
      "position": position, "duration": duration, "progressValid": progressValid,
      "rate": Double(rate), "mode": mode,
      "continuous": continuous, "background": background, "autoResume": autoResume, "rememberProgress": rememberProgress,
      "rewindSeconds": rewindSeconds, "forwardSeconds": forwardSeconds,
      "smartIntro": smartIntro, "detectingIntro": detectingIntro, "introSkipped": introSkipped,
      "error": errorMessage, "interrupted": interrupted, "volume": Double(mediaVolume),
      "audioRecovery": audioRecoveryExhausted ? "exhausted" : audioRecoveryPending ? "pending" : "idle",
      "brightness": Double(mediaBrightness), "fit": fit,
      "a": aPoint ?? -1, "b": bPoint ?? -1,
      "sleepRemaining": max(0, sleepUntil?.timeIntervalSinceNow ?? 0),
      "subtitleName": subtitleName, "audioTrack": mediaKitTracks["audioTrack"] ?? selectedAudio, "subtitleTrack": mediaKitTracks["subtitleTrack"] ?? selectedSubtitle,
      "audioTracks": mediaKitTracks["audioTracks"] ?? trackDescriptions(audioOptions, fallback: fallbackAudio),
      "subtitleTracks": mediaKitTracks["subtitleTracks"] ?? trackDescriptions(subtitleOptions, fallback: fallbackSubtitles),
      "presentationWaiting": presentationWaiting,
      "pipActive": pipActive,
      "pipAvailable": pipAvailable,
      "pipRequesting": pipRequesting]
  }

  func publish() {
    stateRevision += 1
    UIApplication.shared.isIdleTimerDisabled = !mediaIsAudio && enginePlaying && UIApplication.shared.applicationState == .active
    changed?(snapshot())
    updateNowPlaying()
  }

  func playbackInfo() -> [String: Any] {
    nativePlaybackTiming.resetIfNeeded(generation: generation)
    var result: [String: Any] = [
      "engine": mediaKit == nil ? "AVPlayer" : "media_kit / libmpv",
      "durationSeconds": Int(duration),
      "seekable": mediaKit?.seekable ?? timelineReady,
      "generation": generation,
      "errorCode": errorMessage,
      "presentationWaiting": presentationWaiting,
      "nativePlaybackTiming": nativePlaybackTiming.diagnostics,
    ]
    if let mediaKit = mediaKit {
      let info = mediaKit.diagnostics
      result["decoderCode"] = info["decoderCode"] ?? "automatic_hardware_decode"
      result["syncPolicy"] = "libmpv / PCM"
      result["configuredRate"] = rate
      if let actualRate = info["actualRate"] { result["actualRate"] = actualRate }
      let session = AVAudioSession.sharedInstance()
      result["audioOutput"] = session.currentRoute.outputs.map {
        "\($0.portName) (\($0.portType.rawValue))"
      }.joined(separator: ", ")
      result["sampleRate"] = Int(session.sampleRate)
      for key in ["version", "hwdec", "vo", "decoderDrops", "outputDrops", "hwdecReadStatus",
                  "configuredHwdec", "decoderRecovery", "engineAvsync", "subtitleFontStatus", "subtitleFontFamily", "playbackTiming"] {
        if let value = info[key] { result[key] = value }
      }
      result["sessionAge"] = (info["sessionAge"] as? NSNumber)?.doubleValue ?? 0
      result["outputTimingMeasured"] = false
      if let events = info["controlEvents"] as? [String], !events.isEmpty {
        result["controlEvents"] = events
      }
      if let errors = info["errors"] as? [String], !errors.isEmpty {
        result["engineLogs"] = errors
      }
    }
    // Existing playback-info formatting exposes this in all four languages,
    // including before the first PiP request and after the bounded log rolls.
    result["lifecycleEvents"] = ["PiP diagnostics build=\(Self.pipDiagnosticBuild)"] + lifecycleEvents
    result["playerCreations"] = playerCreations
    result["itemCreations"] = itemCreations
    result["pipCreations"] = pipCreations
    let state = snapshot()
    result["audioTracks"] = state["audioTracks"] as? [[String: Any]] ?? []
    result["audioTrack"] = state["audioTrack"] ?? -1
    result["subtitleTracks"] = state["subtitleTracks"] as? [[String: Any]] ?? []
    result["subtitleTrack"] = state["subtitleTrack"] ?? -1
    if !lastDiagnostic.isEmpty { result["technicalDetail"] = lastDiagnostic }
    return result
  }

  func open(paths: [String], selected: Int, resume: Bool) throws {
    guard !paths.isEmpty, paths.indices.contains(selected) else { throw LibraryFailure.app("playback_queue_empty") }
    for path in paths { _ = try library.url(path) }
    persist()
    resetCurrentSessionCheckpoint()
    queue = paths; index = selected
    decoderRecoveryAttempted = false
    load(resume: resume)
  }

  /// A failed AVPlayer needs a new instance. Healthy replay never reaches here.
  private func bindPlayerObservers() {
    playerObservations.removeAll()
    let observed = player
    playerObservations.append(observed.observe(\.timeControlStatus, options: [.new]) { [weak self, weak observed] _, _ in
      DispatchQueue.main.async {
        guard let self, let observed, self.player === observed else { return }
        self.publish()
      }
    })
    playerObservations.append(observed.observe(\.status, options: [.new]) { [weak self, weak observed] _, _ in
      DispatchQueue.main.async {
        guard let self, let observed, self.player === observed,
          observed.status == .failed, self.mediaKit == nil, self.currentPath != nil,
          self.pendingReplacement == nil, self.deferredPresentationLoad == nil else { return }
        self.lastDiagnostic = observed.error?.localizedDescription ?? "AVPlayer failed"
        self.fail("media_playback_failed")
      }
    })
  }

  private func replaceFailedPlayerIfNeeded() {
    guard player.status == .failed || rebuildPlayerAfterMediaServicesReset else { return }
    // This runs only after the current PiP output is stopped or isolated.
    // A media-server reset invalidates players even if status is not .failed.
    clearBoundary()
    observations.removeAll(); playerObservations.removeAll()
    surface?.videoLayer.player = nil
    player.pause(); player.replaceCurrentItem(with: nil)
    player = AVPlayer()
    rebuildPlayerAfterMediaServicesReset = false
    playerCreations += 1
    player.volume = mediaVolume
    player.allowsExternalPlayback = false
    player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    bindPlayerObservers()
    recordLifecycle("unusable player rebuilt for media load")
  }

  private func load(resume: Bool, autoplay: Bool = true) {
    guard currentPath != nil else { return }
    endInlinePiPTransportFollow()
    let controller = pendingReplacement?.controller
      ?? (avPlayerPiPOwnsPresentation ? pip : nil)
      ?? mediaKitPiP?.controller
    guard let controller else {
      if blockingRetiringPiP {
        deferPresentationLoad(resume: resume, autoplay: autoplay, clearOnly: false)
        return
      }
      performLoad(resume: resume, autoplay: autoplay)
      return
    }
    awaitPresentationStop(controller, resume: resume, autoplay: autoplay)
  }

  private func deferPresentationLoad(resume: Bool, autoplay: Bool, clearOnly: Bool) {
    generation += 1
    let token = generation
    cancelAudioRecovery(); cancelIntroDetection(); cancelSeeks()
    assetPreparationTask?.cancel(); assetPreparationTask = nil
    openingTimeout?.cancel()
    guard generation == token else { return }
    deferredPresentationLoad = (resume, autoplay && playbackEnvironmentAllowsPlayback, clearOnly)
    errorMessage = ""
    wantsPlayback = false; timelineReady = false; loading = false; pauseEngine()
    revokeManualPiP(enforce: false)
    resumeDeferredPresentationLoadIfPossible()
    publish()
  }

  private func awaitPresentationStop(_ controller: AVPictureInPictureController,
                                    resume: Bool, autoplay: Bool, clearOnly: Bool = false) {
    errorMessage = ""
    // Keep only the newest requested media and play intent. Repeated opens do
    // not restart the bounded stop wait or create another retiring graph.
    if pendingReplacement?.controller === controller {
      pendingReplacement?.resume = resume
      pendingReplacement?.autoplay = autoplay && playbackEnvironmentAllowsPlayback
      pendingReplacement?.clearOnly = clearOnly
      publish()
      return
    }
    generation += 1
    let token = generation
    cancelAudioRecovery(); cancelIntroDetection(); cancelSeeks()
    assetPreparationTask?.cancel(); assetPreparationTask = nil
    openingTimeout?.cancel()
    guard generation == token else { return }
    wantsPlayback = false; timelineReady = false; loading = true; pauseEngine()
    revokeManualPiP(enforce: false)
    pipActivationTimeout?.cancel(); pipActivationTimeout = nil
    pipPossibleObservation?.invalidate(); pipPossibleObservation = nil
    avPlayerPiPRequest = nil
    let id = UUID()
    pendingReplacement = (id, controller, resume, autoplay && playbackEnvironmentAllowsPlayback, clearOnly)
    replacementTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self, weak controller] in
      guard let self, let controller, let request = self.pendingReplacement,
            request.id == id, request.controller === controller else { return }
      self.pendingReplacement = nil
      self.replacementTimeout = nil
      self.deferredPresentationLoad = (request.resume, request.autoplay, request.clearOnly)
      let renderer = self.mediaKitPiP?.controller === controller ? self.mediaKitPiP : nil
      if renderer != nil { self.mediaKitPiP = nil; self.mediaKitPiPActiveRequestID = nil }
      if self.pip === controller { self.pip = nil }
      self.cancelPendingAVPlayerPiP()
      self.loading = false
      self.recordLifecycle("PiP stop wait elapsed; latest media intent retained")
      self.retirePiP(controller, renderer: renderer)
      if self.retiringPiP[ObjectIdentifier(controller)] != nil {
        self.unconfirmedPiPStops.insert(ObjectIdentifier(controller))
      }
      self.resumeDeferredPresentationLoadIfPossible()
      self.publish()
    }
    replacementTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: timeout)
    if let renderer = mediaKitPiP, renderer.controller === controller { renderer.stop() }
    else { controller.stopPictureInPicture() }
    publish()
  }

  private func finishPendingReplacement(_ controller: AVPictureInPictureController,
                                        avTerminal: AVPlayerPiPTerminal? = nil) -> Bool {
    guard let request = pendingReplacement, request.controller === controller else { return false }
    let confirmedAVTerminal = avTerminal != nil && mediaKitPiP?.controller !== controller
    guard confirmedAVTerminal || !controller.isPictureInPictureActive else { return true }
    clearPiPPlaybackSession(controller)
    pendingReplacement = nil; replacementTimeout?.cancel(); replacementTimeout = nil
    let renderer = mediaKitPiP?.controller === controller ? mediaKitPiP : nil
    if renderer != nil { mediaKitPiP = nil; mediaKitPiPActiveRequestID = nil }
    if pip === controller { pip = nil }
    cancelPendingAVPlayerPiP()
    observedPiPStarts.remove(ObjectIdentifier(controller))
    controller.delegate = nil
    renderer?.stop()
    if request.clearOnly || currentPath == nil { clearPlaybackEnginesAfterMutation(); publish() }
    else { performLoad(resume: request.resume, autoplay: request.autoplay) }
    return true
  }

  private func clearPlaybackEnginesAfterMutation() {
    discardMediaKitPiP()
    mediaKit?.stopPlayback(); mediaKit = nil
    discardAVPlayerPiP()
    observations.removeAll()
    installedAVPlayerItem = nil
    player.replaceCurrentItem(with: nil)
    loading = false
  }

  private func performLoad(resume: Bool, autoplay: Bool) {
    guard let path = currentPath else { return }
    generation += 1
    let token = generation
    if currentSessionPositionRestore?.targetGeneration != token {
      currentSessionPositionRestore = nil
    }
    decoderRecoveryRequest = nil
    revokeManualPiP(enforce: false)
    cancelAudioRecovery()
    assetPreparationTask?.cancel()
    assetPreparationTask = nil
    finishTrackSelection("track_selection_stale")
    guard generation == token else { return }
    cancelIntroDetection()
    cancelSeeks()
    guard generation == token else { return }
    openingTimeout?.cancel()
    clearBoundary()
    discardMediaKitPiP()
    mediaKit?.stopPlayback(); mediaKit = nil
    discardAVPlayerPiP()
    replaceFailedPlayerIfNeeded()
    recordLifecycle("load")
    engineNotice = ""; lastDiagnostic = ""; fallbackUsed = false; preparedMediaKit = false
    seekFault = false; pendingResume = resume && rememberProgress
    initialPositionEstablished = false; initialHistoricalSeekPending = false; sessionCompleted = false; atPlaybackEnd = false; pendingEndAction = false
    nonSeekableStartPosition = nil
    lastValidRememberedProgress = nil
    introSkipped = 0
    player.pause(); timelineReady = false; loading = true; wantsPlayback = autoplay && playbackEnvironmentAllowsPlayback; errorMessage = ""
    // An interruption belongs to the audio session, not to the media item. If the
    // user switches items while it is active, carry the new playback intent so an
    // eventual .ended notification resumes the new item instead of the old one.
    if interrupted {
      resumeAfterInterruption = wantsPlayback
      audioRecoveryPending = wantsPlayback
    }
    observations.removeAll()
    installedAVPlayerItem = nil
    player.replaceCurrentItem(with: nil)
    aPoint = nil; bPoint = nil
    cues = []; subtitleName = ""; subtitleText = ""; surface?.caption.text = ""; surface?.caption.isHidden = true
    audioOptions = []; subtitleOptions = []; selectedAudio = -1; selectedSubtitle = -1
    guard let transport = mediaKitTransport else { fail("playback_channel_unavailable"); return }
    scheduleOpenTimeout(token: token)
    publish()
    transport("release", [:]) { [weak self] success in
      guard let self = self, self.generation == token else { return }
      guard success else {
        self.lastDiagnostic = "media_kit_release_failed"
        self.fail("media_engine_cleanup_failed")
        return
      }
      self.loadPrepared(path: path, resume: resume, token: token)
    }
  }

  private func loadPrepared(path: String, resume: Bool, token: Int) {
    do {
      let url = try library.url(path)
      guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryFailure.app("media_missing") }
      // Best effort only; never block the main playback path on a provider's
      // metadata operation.
      library.scheduleProtectionNormalization(paths: [path])
      timelineReady = false
      timelineOrigin = 0
      fallbackAudio = []; fallbackSubtitles = []
      observations.removeAll()
      player.replaceCurrentItem(with: nil)
      surface?.videoLayer.isHidden = false
      surface?.onLayout = nil
      // An MP4 may already be on MK after AV fallback. Internal output
      // recovery must rebuild that same engine type, not retry AV and skip
      // the MK ready/position acknowledgement path.
      let restoringCurrentMKPosition = currentSessionPositionRestore.map {
        $0.targetGeneration == token && $0.checkpoint.sessionID == currentSessionID
          && $0.checkpoint.path == path
      } ?? false
      guard currentSessionPositionRestore == nil || restoringCurrentMKPosition else {
        fail("media_playback_failed")
        lastDiagnostic = "inline output recovery load identity no longer matches"
        publish()
        return
      }
      if Self.prefersMediaKit(url) || restoringCurrentMKPosition {
        openMediaKit(url: url, resume: resume, token: token)
        return
      }
      attachAVPlayerPresentationIfAllowed(reason: "initial load")
      scheduleOpenTimeout(token: token)
      let task = Task.detached(priority: .userInitiated) { [weak self] in
        do {
          let prepared = try await PlaybackTimeline.prepare(url: url)
          try Task.checkCancellation()
          DispatchQueue.main.async {
            guard let self = self, self.generation == token else { return }
            self.assetPreparationTask = nil
            self.install(prepared.asset, origin: prepared.origin, url: url, path: path, resume: resume, token: token)
          }
        } catch is CancellationError {
          return
        } catch {
          DispatchQueue.main.async {
            guard let self = self, self.generation == token else { return }
            self.assetPreparationTask = nil
            self.fallbackToMediaKit(url: url, resume: resume, token: token, error: error)
          }
        }
      }
      assetPreparationTask = task
      publish()
    } catch {
      if let failure = error as? LibraryFailure {
        fail(failure.code)
      } else {
        lastDiagnostic = error.localizedDescription
        fail("media_playback_failed")
      }
    }
  }

  private func install(_ asset: AVAsset, origin: Double, url: URL, path: String, resume: Bool, token: Int) {
    guard generation == token, currentPath == path, mediaKit == nil,
          pendingReplacement == nil, !seekFault, errorMessage.isEmpty else { return }
    timelineOrigin = origin
    let item = AVPlayerItem(asset: asset)
    itemCreations += 1
    recordLifecycle("item created")
    item.audioTimePitchAlgorithm = .timeDomain
    var prepared = false
    observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.generation == token, self.mediaKit == nil,
              self.player.currentItem === item, self.currentPath == path, !self.seekFault else { return }
        if item.status == .failed {
          self.fallbackToMediaKit(url: url, resume: resume, token: token, error: item.error ?? LibraryFailure.app("media_unsupported")); return
        }
        guard item.status == .readyToPlay, !prepared else { return }
        prepared = true
        self.openingTimeout?.cancel()
        self.timelineReady = true
        self.ensureAVPlayerPresentation(reason: "item ready")
        self.loadTracks(item)
        let startToken = self.introToken
        self.library.recordStore.readPlaybackRecord(path: path) { [weak self, weak item] record in
          guard let self = self, let item = item, self.generation == token,
            self.player.currentItem === item, self.mediaKit == nil, !self.seekFault,
            self.introToken == startToken else { return }
          // Old records used the source movie clock. Migration is committed only
          // after the initial seek succeeds, so a failed open preserves history.
          let previousOrigin = (record["timelineOrigin"] as? NSNumber)?.doubleValue ?? 0
          let saved = (record["position"] as? NSNumber)?.doubleValue ?? 0
          let migrated = saved.isFinite && saved > 0
            ? max(0, saved + previousOrigin - origin) : 0
          let start = self.rememberProgress && self.pendingResume && migrated > 0 && migrated < self.duration - 2 ? migrated : 0
          self.initialHistoricalSeekPending = start > 0
          self.prepareStart(url: url, saved: start)
        }
      }
    })
    installedAVPlayerItem = (item, path, token)
    player.replaceCurrentItem(with: item)
    ensureAVPlayerPresentation(reason: "item installed")
    publish()
  }

  private func cancelIntroDetection() {
    introToken += 1
    introScanner.cancel()
    if detectingIntro || timelineReady { loading = false }
    detectingIntro = false
    endIntroBackgroundTask()
  }

  private func endIntroBackgroundTask() {
    if introBackgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(introBackgroundTask)
      introBackgroundTask = .invalid
    }
  }

  private func prepareStart(url: URL, saved: Double) {
    let token = introToken
    let itemGeneration = generation
    if !smartIntro || mediaIsAudio || saved > 0 || !wantsPlayback {
      finishStart(saved, token: token, itemGeneration: itemGeneration)
      return
    }
    detectingIntro = true; loading = true; publish()
    introBackgroundTask = UIApplication.shared.beginBackgroundTask(withName: "片头识别") { [weak self] in
      guard let self = self, self.introToken == token, self.generation == itemGeneration else { return }
      self.cancelIntroDetection()
      self.finishStart(0, token: self.introToken, itemGeneration: itemGeneration)
    }
    if UIApplication.shared.applicationState != .active && introBackgroundTask == .invalid {
      finishStart(0, token: token, itemGeneration: itemGeneration)
      return
    }
    guard let asset = player.currentItem?.asset else {
      endIntroBackgroundTask(); return
    }
    introScanner.detect(url: url, asset: asset, origin: timelineOrigin) { [weak self] offset in
      guard let self = self, self.introToken == token, self.generation == itemGeneration else { return }
      let start = self.smartIntro ? min(offset ?? 0, max(0, self.duration - 1)) : 0
      self.introSkipped = start
      self.finishStart(start, token: token, itemGeneration: itemGeneration)
    }
  }

  private func finishStart(_ seconds: Double, token: Int, itemGeneration: Int) {
    guard introToken == token, generation == itemGeneration else { return }
    detectingIntro = false
    let operation = playbackOperation
    enqueueSeek(seconds, precise: true) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self = self, self.introToken == token, self.generation == itemGeneration,
          self.playbackOperation == operation else { return }
        let wasReplay = self.replayOperation == operation
        self.replayOperation = nil
        self.loading = false
        if !finished { self.introSkipped = 0; self.endIntroBackgroundTask(); return }
        if wasReplay && PlaybackEndGate.isAtEnd(self.position, duration: self.duration) {
          self.endIntroBackgroundTask(); self.fail("seek_failed"); return
        }
        self.initialPositionEstablished = true
        self.initialHistoricalSeekPending = false
        self.sessionCompleted = false; self.atPlaybackEnd = false; self.pendingEndAction = false
        self.endGate.settled(operation: operation, rawTarget: seconds, position: self.position, duration: self.duration,
          confirmedEngineEnd: self.mediaKit?.ended == true, endpointSeekTolerance: self.mediaKit == nil ? nil : 0.35)
        if self.wantsPlayback { self.attemptAudioRecovery() }
        self.endIntroBackgroundTask()
        self.persist(); self.publish()
      }
    }
  }

  func play() {
    guard currentPath != nil else { return }
    endInlinePiPTransportFollow()
    guard playbackEnvironmentAllowsPlayback else { enforcePlaybackEnvironment(); return }
    if let deadline = sleepUntil, Date() >= deadline {
      sleepTimer?.invalidate(); sleepTimer = nil; sleepUntil = nil; pause(); return
    }
    // Only this explicit user/remote/PiP play entry can revalidate a missing
    // interruption-ended notification. Timer/foreground/item-ready callbacks
    // never acquire that authority from resetting their retry counter.
    audioRecoveryRequiresAutoResume = false
    if interrupted {
      do {
        try activateAudioSession(reason: "explicit-play")
        interrupted = false; resumeAfterInterruption = false
        lastDiagnostic = "explicit play reactivated an interrupted audio session"
      } catch {
        lastDiagnostic = error.localizedDescription
        wantsPlayback = true; audioRecoveryPending = true
        pauseEngine(); publish(); return
      }
    }
    if pendingReplacement != nil || deferredPresentationLoad != nil {
      pendingReplacement?.autoplay = true
      deferredPresentationLoad?.autoplay = true
      resumeDeferredPresentationLoadIfPossible()
      publish(); return
    }
    if presentationWaiting { wantsPlayback = true; publish(); return }
    pendingEndAction = false
    if seekFault || (mediaKit?.failure.isEmpty == false)
      || (mediaKit == nil && (player.status == .failed || player.currentItem?.status == .failed)) {
      decoderRecoveryAttempted = false
      load(resume: true); return
    }
    if replayOperation != nil { wantsPlayback = true; publish(); return }
    if atPlaybackEnd {
      wantsPlayback = true
      attemptAudioRecovery(resetAttempts: true)
      return
    }
    if !timelineReady || loading || isSeeking || scrubbing { wantsPlayback = true; publish(); return }
    if let deadline = sleepUntil, Date() >= deadline { sleepTimer?.invalidate(); sleepTimer = nil; sleepUntil = nil; pause(); return }
    wantsPlayback = true
    attemptAudioRecovery(resetAttempts: true)
  }

  private func attemptAudioRecovery(resetAttempts: Bool = false) {
    nativePlaybackTiming.clearTickBaseline()
    if let deadline = sleepUntil, Date() >= deadline {
      sleepTimer?.invalidate(); sleepTimer = nil; sleepUntil = nil; pause(); return
    }
    guard playbackEnvironmentAllowsPlayback else { enforcePlaybackEnvironment(); return }
    guard currentPath != nil, wantsPlayback else { cancelAudioRecovery(); return }
    guard !presentationWaiting else { pauseEngine(); publish(); return }
    guard timelineReady, !loading, !isSeeking, !scrubbing else {
      audioRecoveryPending = true
      publish()
      return
    }
    if interrupted {
      audioRecoveryPending = true
      errorMessage = ""
      pauseEngine(); publish(); return
    }
    guard !audioRecoveryRequiresAutoResume || autoResume else { pause(); return }
    let operationBeforeEnd = playbackOperation
    let generationBeforeEnd = generation
    resolveEndCandidate()
    guard playbackOperation == operationBeforeEnd, generation == generationBeforeEnd, wantsPlayback else { return }
    if pendingEndAction { performPendingEndAction(); return }
    if atPlaybackEnd {
      if let a = aPoint, bPoint != nil { seek(a) } else { restartCurrentItem() }
      return
    }
    if resetAttempts {
      audioRecoveryWorkItem?.cancel()
      audioRecoveryWorkItem = nil
      audioRecoveryAttempt = 0
      audioRecoveryExhausted = false
    }
    let token = generation
    let path = currentPath
    let request = UUID()
    audioRecoveryRequest = request
    let recoveryEngine = mediaKit
    let expectedPlayIntentVersion = recoveryEngine.map { $0.playIntentVersion + 1 }
    let recoveryOperation = playbackOperation
    do {
      try activateAudioSession(reason: audioRecoveryRequiresAutoResume ? "interruption-resume"
        : resetAttempts ? "explicit-play" : "automatic-recovery")
      guard audioRecoveryRequest == request else { return }
      audioRecoveryPending = false
      errorMessage = ""
      resumeEngine { [weak self] success in
        DispatchQueue.main.async {
          guard let self = self, self.generation == token, self.currentPath == path,
                self.wantsPlayback, self.playbackEnvironmentAllowsPlayback,
                self.audioRecoveryRequest == request,
                self.playbackOperation == recoveryOperation,
                self.mediaKit === recoveryEngine,
                self.mediaKit?.playIntentVersion == expectedPlayIntentVersion else { return }
          // A transport acknowledgement owns only the request that issued it.
          // This also fences AVPlayer's synchronous success queued on main,
          // which has no media_kit play-intent version of its own.
          self.audioRecoveryRequest = nil
          if success {
            self.cancelAudioRecovery()
            self.errorMessage = ""
            self.publish()
          } else {
            self.lastDiagnostic = "media_kit play rejected during audio recovery"
            self.deferAudioRecovery()
          }
        }
      }
    } catch {
      guard audioRecoveryRequest == request else { return }
      audioRecoveryRequest = nil
      lastDiagnostic = error.localizedDescription
      deferAudioRecovery()
    }
  }

  private func deferAudioRecovery() {
    audioRecoveryPending = wantsPlayback
    errorMessage = ""
    pauseEngine()
    publish()
    scheduleAudioRecoveryRetry()
  }

  private func scheduleAudioRecoveryRetry() {
    audioRecoveryWorkItem?.cancel()
    audioRecoveryWorkItem = nil
    guard audioRecoveryPending, wantsPlayback, playbackEnvironmentAllowsPlayback, !interrupted,
          !audioRecoveryRequiresAutoResume || autoResume else { return }
    // The bounded retry also serves permitted background audio while this
    // process is runnable. It does not request unlimited background execution.
    guard let delay = AudioRecoveryRetryPolicy.delay(forAttempt: audioRecoveryAttempt) else {
      // Do not leave recovery in a silent, permanently-pending state. Keep the
      // user's play intent so an explicit Play can start a fresh attempt, while
      // exposing a terminal state to Flutter. Pause still clears that intent.
      audioRecoveryPending = false
      audioRecoveryExhausted = true
      lastDiagnostic = "audio_recovery_failed: " + lastDiagnostic
      errorMessage = "media_playback_failed"
      publish()
      return
    }
    audioRecoveryAttempt += 1
    let token = generation
    let path = currentPath
    let work = DispatchWorkItem { [weak self] in
      guard let self = self, self.generation == token, self.currentPath == path,
            self.audioRecoveryPending, self.wantsPlayback else { return }
      self.audioRecoveryWorkItem = nil
      self.attemptAudioRecovery()
    }
    audioRecoveryWorkItem = work
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
  }

  private func cancelAudioRecovery(clearPending: Bool = true) {
    audioRecoveryRequest = nil
    audioRecoveryWorkItem?.cancel()
    audioRecoveryWorkItem = nil
    audioRecoveryAttempt = 0
    audioRecoveryExhausted = false
    audioRecoveryRequiresAutoResume = false
    if clearPending { audioRecoveryPending = false }
  }

  func pause() {
    endInlinePiPTransportFollow()
    pendingReplacement?.autoplay = false
    deferredPresentationLoad?.autoplay = false
    pendingEndAction = false
    let clearRecoveryFailure = audioRecoveryExhausted && errorMessage == "media_playback_failed"
    cancelAudioRecovery()
    let wasDetectingIntro = detectingIntro
    if wasDetectingIntro { cancelIntroDetection() }
    wantsPlayback = false; resumeAfterInterruption = false
    if clearRecoveryFailure { errorMessage = "" }
    scrubbing = false
    pauseEngine()
    // Pausing the scan still needs a confirmed initial position. Do not cancel
    // an already dispatched initial seek's completion token merely to pause.
    if wasDetectingIntro { finishStart(0, token: introToken, itemGeneration: generation) }
    resolveEndCandidate()
    persist(); publish()
  }

  func seek(_ seconds: Double, completion: @escaping (Bool) -> Void = { _ in }) {
    guard !cancellingSeeks, timelineReady, !seekFault, !presentationWaiting, seconds.isFinite, duration > 0,
      mediaKit?.seekable ?? true else { completion(false); return }
    captureRememberedProgress()
    currentSessionPositionRestore = nil
    initialHistoricalSeekPending = false
    cancelIntroDetection()
    introSkipped = 0
    playbackOperation += 1
    let operation = playbackOperation
    let token = generation
    endGate.beginOperation()
    replayOperation = nil
    scrubbing = false
    pauseEngine()
    enqueueSeek(seconds, precise: true) { [weak self] finished in
      guard let self = self, self.generation == token, self.playbackOperation == operation else { completion(false); return }
      if finished {
        self.initialPositionEstablished = true
        self.initialHistoricalSeekPending = false
        self.sessionCompleted = false; self.atPlaybackEnd = false; self.pendingEndAction = false
        self.endGate.settled(operation: operation, rawTarget: seconds, position: self.position, duration: self.duration,
          confirmedEngineEnd: self.mediaKit?.ended == true, endpointSeekTolerance: self.mediaKit == nil ? nil : 0.35)
        self.resolveEndCandidate()
        guard self.generation == token, self.playbackOperation == operation else { completion(true); return }
        if self.wantsPlayback && !self.scrubbing && !self.sessionCompleted { self.attemptAudioRecovery() }
        self.persist()
      }
      self.publish(); completion(finished)
    }
  }

  func previewSeek(_ seconds: Double) {
    guard !cancellingSeeks, timelineReady, !seekFault, !presentationWaiting, seconds.isFinite, duration > 0, mediaKit?.seekable ?? true else { return }
    if !scrubbing {
      captureRememberedProgress(); cancelIntroDetection()
      currentSessionPositionRestore = nil
      playbackOperation += 1; replayOperation = nil; endGate.beginOperation()
      scrubbing = true; pauseEngine()
    }
    if mediaKit != nil { publish(); return }
    enqueueSeek(seconds, precise: false) { _ in }
  }

  func cancelScrub() {
    guard scrubbing else { return }
    scrubbing = false
    seek(position)
  }

  private func enqueueSeek(_ seconds: Double, precise: Bool, done: @escaping (Bool) -> Void) {
    guard !cancellingSeeks, timelineReady, !seekFault else { done(false); return }
    let token = generation
    seekSequence += 1
    let requestID = seekSequence
    let previous = pendingSeek
    pendingSeek = (requestID, PlaybackEndGate.seekTarget(seconds, duration: duration), precise, done)
    previous?.done(false)
    guard generation == token, pendingSeek?.id == requestID else { return }
    runNextSeek()
  }

  private func runNextSeek() {
    guard activeSeek == nil, let request = pendingSeek else { return }
    pendingSeek = nil; activeSeek = request.id; activeSeekCompletion = request.done
    let token = generation
    let startedAt = ProcessInfo.processInfo.systemUptime
    mediaKit?.recordDiagnostic(String(format: "seek start session=%d request=%d target=%.3f before=%.3f precise=%@", token, request.id, request.seconds, position, request.precise ? "yes" : "no"))
    let finish: (Bool) -> Void = { [weak self] finished in
      guard let self = self, self.generation == token, self.activeSeek == request.id else { return }
      self.seekTimeout?.cancel(); self.seekTimeout = nil
      self.activeSeek = nil; self.activeSeekCompletion = nil
      let superseded = self.pendingSeek != nil
      self.mediaKit?.recordDiagnostic(String(format: "seek finish session=%d request=%d success=%@ superseded=%@ after=%.3f elapsed=%.3f", token, request.id, finished ? "yes" : "no", superseded ? "yes" : "no", self.position, ProcessInfo.processInfo.systemUptime - startedAt))
      let sequenceBeforeCallback = self.seekSequence
      request.done(finished && !superseded)
      guard self.generation == token, self.seekSequence == sequenceBeforeCallback, self.activeSeek == nil else { return }
      if !finished && !superseded {
        self.fail("seek_failed")
        return
      }
      self.runNextSeek()
      guard self.generation == token else { return }
      self.publish()
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.generation == token, self.activeSeek == request.id else { return }
      self.mediaKit?.recordDiagnostic("seek timeout session=\(token) request=\(request.id)")
      self.seekFault = true
      self.cancelSeeks()
      guard self.generation == token else { return }
      self.fail("seek_timeout")
    }
    seekTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: timeout)
    if let mediaKit = mediaKit {
      mediaKit.seek(seconds: request.seconds, completion: finish)
    } else {
      let tolerance = request.precise ? CMTime.zero : CMTime(seconds: 0.2, preferredTimescale: 600)
      player.seek(to: CMTime(seconds: request.seconds, preferredTimescale: 600), toleranceBefore: tolerance, toleranceAfter: tolerance) { success in
        DispatchQueue.main.async { finish(success) }
      }
    }
    guard generation == token else { return }
    publish()
  }

  private func cancelSeeks() {
    guard !cancellingSeeks else { return }
    cancellingSeeks = true
    defer { cancellingSeeks = false }
    playbackOperation += 1
    replayOperation = nil; endGate = PlaybackEndGate(); pendingEndAction = false
    if isSeeking { mediaKit?.recordDiagnostic("seek cancelled session=\(generation) active=\(activeSeek ?? -1) pending=\(pendingSeek?.id ?? -1)") }
    seekTimeout?.cancel(); seekTimeout = nil
    let active = activeSeekCompletion; let pending = pendingSeek
    activeSeek = nil; activeSeekCompletion = nil; pendingSeek = nil; scrubbing = false
    player.currentItem?.cancelPendingSeeks()
    active?(false)
    // Both captured completions are owed false even if the first opens another item.
    pending?.done(false)
  }

  func skip(_ direction: Int) {
    guard !queue.isEmpty else { return }
    persist()
    let next: Int
    if mode == "shuffle" && queue.count > 1 {
      next = (index + Int.random(in: 1..<queue.count)) % queue.count
    } else {
      let candidate = index + direction
      if queue.indices.contains(candidate) { next = candidate }
      else if mode == "folder" || mode == "one" { next = (candidate + queue.count) % queue.count }
      else { if direction > 0 { pause() }; return }
    }
    if next == index { wantsPlayback = playbackEnvironmentAllowsPlayback; restartCurrentItem(); return }
    resetCurrentSessionCheckpoint()
    index = next; decoderRecoveryAttempted = false; load(resume: false)
  }

  private func recordLifecycle(_ event: String) {
    let binding = "appState=\(UIApplication.shared.applicationState.rawValue) layer=\(surface.map { String(describing: ObjectIdentifier($0.videoLayer)) } ?? "nil") boundPlayer=\(surface?.videoLayer.player.map { String(describing: ObjectIdentifier($0)) } ?? "nil") retiring=\(retiringPiP.count)"
    let identities = "player=\(ObjectIdentifier(player)) item=\(player.currentItem.map { String(describing: ObjectIdentifier($0)) } ?? "nil") pip=\(pip.map { String(describing: ObjectIdentifier($0)) } ?? "nil")"
    let clock = String(format: "%.3f", ProcessInfo.processInfo.systemUptime)
    let engine = currentPath == nil ? "none" : mediaKit == nil ? "AVPlayer" : "media_kit"
    lifecycleEvents.append("uptime=\(clock) engine=\(engine) generation=\(generation) operation=\(playbackOperation) \(identities) \(binding) \(event)")
    if lifecycleEvents.count > 40 { lifecycleEvents.removeFirst(lifecycleEvents.count - 40) }
  }

  private var healthyForReplay: Bool {
    guard timelineReady, !seekFault, duration > 0 else { return false }
    if let engine = mediaKit { return engine.ready && engine.seekable && engine.failure.isEmpty }
    return player.status == .readyToPlay && player.currentItem?.status == .readyToPlay
  }

  private func restartCurrentItem() {
    guard replayOperation == nil, currentPath != nil else { return }
    guard healthyForReplay else { fail("seek_failed"); return }
    currentSessionPositionRestore = nil
    cancelAudioRecovery()
    cancelIntroDetection()
    playbackOperation += 1
    endGate.beginOperation()
    replayOperation = playbackOperation
    scrubbing = false
    pauseEngine()
    initialHistoricalSeekPending = false
    recordLifecycle("restart by seek")
    // Keep the current player, item, layer, tracks and PiP. Manual seek(0) does
    // not enter this path, so it continues to bypass smart-intro detection.
    if mediaKit != nil { finishStart(0, token: introToken, itemGeneration: generation) }
    else if let path = currentPath, let url = try? library.url(path) { prepareStart(url: url, saved: 0) }
    else { replayOperation = nil; fail("media_missing") }
  }

  private func offerEndCandidate(source: String) {
    guard currentPath != nil, timelineReady, !seekFault else { return }
    endGate.offer()
    recordLifecycle("EOF candidate source=\(source) busy=\(isSeeking || scrubbing)")
    resolveEndCandidate()
  }

  private func resolveEndCandidate() {
    guard initialPositionEstablished, !loading, !isSeeking, !scrubbing, replayOperation == nil,
      endGate.consume(operation: playbackOperation, position: position, duration: duration, confirmedEngineEnd: mediaKit?.ended == true) else { return }
    recordLifecycle("EOF consumed")
    // Consume before dispatching callbacks. An A–B repeat does not complete the
    // entire media or overwrite its history with a completed zero.
    atPlaybackEnd = true
    if aPoint == nil || bPoint == nil { sessionCompleted = true; persist() }
    pendingEndAction = wantsPlayback && playbackEnvironmentAllowsPlayback
    performPendingEndAction()
  }

  private func performPendingEndAction() {
    guard pendingEndAction, atPlaybackEnd, wantsPlayback, playbackEnvironmentAllowsPlayback,
      !interrupted, !isSeeking, !scrubbing, !loading else { publish(); return }
    pendingEndAction = false
    if let a = aPoint, bPoint != nil { seek(a); return }
    if !continuous { wantsPlayback = false; pauseEngine(); publish(); return }
    if mode == "one" { restartCurrentItem(); return }
    if index == queue.count - 1 && mode == "sequence" { wantsPlayback = false; pauseEngine(); publish(); return }
    skip(1)
  }

  private static func normalizedRate(_ value: Double) -> Float {
    guard value.isFinite else { return 1 }
    return Float((min(3, max(0.5, value)) * 20).rounded() / 20)
  }

  private static func normalizedJumpSeconds(_ value: Int) -> Int {
    min(300, max(1, value))
  }

  private var controlBusy = false

  func requestConfiguration(_ values: [String: Any], completion: @escaping (String?) -> Void) {
    if let requested = values["generation"] as? Int, requested != generation {
      completion("control_superseded"); return
    }
    guard let engine = mediaKit else {
      do { try configure(values); completion(nil) }
      catch { completion((error as? LibraryFailure)?.code ?? "playback_control_failed") }
      return
    }
    guard !controlBusy else { completion("playback_control_failed"); return }
    let token = generation
    var commands: [(String, [String: Any], () -> Void)] = []
    var remaining = values
    if let value = values["rate"] as? Double, value.isFinite {
      let rate = Self.normalizedRate(value)
      remaining.removeValue(forKey: "rate")
      commands.append(("rate", ["value": Double(rate)], { [weak self] in
        self?.rate = rate; engine.rate = rate
        UserDefaults.standard.set(rate, forKey: "playback.rate")
      }))
    }
    if let value = values["volume"] as? Double, value.isFinite {
      let volume = Float(min(1, max(0, value)))
      remaining.removeValue(forKey: "volume")
      commands.append(("volume", ["value": Double(volume)], { [weak self] in
        self?.mediaVolume = volume; engine.volume = volume
        UserDefaults.standard.set(volume, forKey: "playback.volume")
      }))
    }
    if let action = values["ab"] as? String {
      remaining.removeValue(forKey: "ab")
      var a: Double?, b: Double?
      if action == "a" { a = position }
      else if action == "b" {
        guard let start = aPoint, position > start + 0.5 else { completion("ab_repeat_invalid"); return }
        a = start; b = position
      }
      guard engine.seekable else { completion("ab_repeat_unsupported"); return }
      let nextA = a, nextB = b
      commands.append(("loop", ["from": a ?? -1, "to": b ?? -1], { [weak self] in
        self?.aPoint = nextA; self?.bPoint = nextB
        if let start = nextA, nextB != nil { self?.seek(start) }
      }))
    }
    guard !commands.isEmpty else {
      do { try configure(remaining); completion(nil) }
      catch { completion((error as? LibraryFailure)?.code ?? "playback_control_failed") }
      return
    }
    controlBusy = true
    func run(_ index: Int) {
      guard generation == token, mediaKit === engine else {
        controlBusy = false; completion("control_superseded"); return
      }
      guard index < commands.count else {
        controlBusy = false
        do { try configure(remaining); completion(nil) }
        catch { completion((error as? LibraryFailure)?.code ?? "playback_control_failed") }
        return
      }
      let command = commands[index]
      engine.control(command.0, arguments: command.1) { [weak self] success in
        guard let self else { completion("control_superseded"); return }
        guard self.generation == token, self.mediaKit === engine else {
          self.controlBusy = false; completion("control_superseded"); return
        }
        guard success else {
          self.controlBusy = false; self.publish(); completion("playback_control_failed"); return
        }
        command.2(); self.publish(); run(index + 1)
      }
    }
    run(0)
  }

  private func configure(_ values: [String: Any]) throws {
    if let value = values["rememberProgress"] as? Bool {
      // Capture the last stable ON snapshot before disabling writes. Enabling
      // records this session in place; it must never trigger a historical seek.
      if rememberProgress && !value {
        captureRememberedProgress()
        if let path = currentPath, var final = lastValidRememberedProgress {
          final["lastPlayed"] = Date().timeIntervalSince1970
          library.recordStore.updateProgress(path: path, fields: final)
          lastSave = Date()
        }
      }
      if !value {
        pendingResume = false
        if !initialPositionEstablished && initialHistoricalSeekPending {
          initialHistoricalSeekPending = false
          introToken += 1 // Also invalidate a success already queued on main.
          // Revoke a historical start that has not yet settled. The seek queue
          // supersedes its acknowledgment before establishing the zero start.
          finishStart(0, token: introToken, itemGeneration: generation)
        }
      }
      if value != rememberProgress { lastValidRememberedProgress = nil }
      let wasEnabled = rememberProgress
      rememberProgress = value
      UserDefaults.standard.set(value, forKey: "playback.rememberProgress")
      if value && !wasEnabled { persist() }
    }
    if let value = values["smartIntro"] as? Bool {
      smartIntro = value
      UserDefaults.standard.set(value, forKey: "playback.smartIntro")
      if !value && detectingIntro {
        cancelIntroDetection()
        finishStart(0, token: introToken, itemGeneration: generation)
      }
    }
    if let value = values["rate"] as? Double, value.isFinite {
      rate = Self.normalizedRate(value)
      UserDefaults.standard.set(rate, forKey: "playback.rate")
      mediaKit?.rate = rate
      if mediaKit == nil && player.rate != 0 { player.rate = rate }
    }
    if let value = values["mode"] as? String, ["sequence", "folder", "one", "shuffle"].contains(value) { mode = value; continuous = true }
    if let value = values["continuous"] as? Bool { continuous = value }
    if let value = values["background"] as? Bool {
      background = value
      // Keep the AVPlayer/audio capability; the common service policy decides
      // whether this particular session may actually play in the background.
      enforcePlaybackEnvironment()
    }
    if let value = values["autoResume"] as? Bool {
      autoResume = value
      if !value && audioRecoveryRequiresAutoResume { pause() }
    }
    if let value = values["rewindSeconds"] as? NSNumber {
      rewindSeconds = Self.normalizedJumpSeconds(value.intValue)
      UserDefaults.standard.set(rewindSeconds, forKey: "playback.rewindSeconds")
      MPRemoteCommandCenter.shared().skipBackwardCommand.preferredIntervals = [NSNumber(value: rewindSeconds)]
    }
    if let value = values["forwardSeconds"] as? NSNumber {
      forwardSeconds = Self.normalizedJumpSeconds(value.intValue)
      UserDefaults.standard.set(forwardSeconds, forKey: "playback.forwardSeconds")
      MPRemoteCommandCenter.shared().skipForwardCommand.preferredIntervals = [NSNumber(value: forwardSeconds)]
    }
    if let value = values["volume"] as? Double, value.isFinite {
      mediaVolume = Float(min(1, max(0, value)))
      UserDefaults.standard.set(mediaVolume, forKey: "playback.volume")
      player.volume = mediaVolume
      mediaKit?.volume = mediaVolume
    }
    if let value = values["brightness"] as? Double, value.isFinite {
      if savedBrightness == nil { savedBrightness = UIScreen.main.brightness }
      mediaBrightness = CGFloat(min(1, max(0.05, value)))
      UserDefaults.standard.set(mediaBrightness, forKey: "playback.brightness")
      UIScreen.main.brightness = mediaBrightness
    }
    if let value = values["fit"] as? String { fit = value; surface?.videoLayer.videoGravity = value == "fill" ? .resizeAspectFill : value == "stretch" ? .resize : .resizeAspect }
    if let minutes = values["sleepMinutes"] as? Double {
      sleepTimer?.invalidate(); sleepTimer = nil
      sleepUntil = minutes > 0 ? Date().addingTimeInterval(minutes * 60) : nil
      if minutes > 0 {
        let timer = Timer(timeInterval: minutes * 60, repeats: false) { [weak self] _ in
          self?.sleepUntil = nil; self?.sleepTimer = nil; self?.pause()
        }
        sleepTimer = timer
        RunLoop.main.add(timer, forMode: .common)
      }
    }
    if let action = values["ab"] as? String {
      if detectingIntro { seek(position) }
      var restartAt: Double?
      switch action {
      case "a": aPoint = position; bPoint = nil
      case "b":
        guard let a = aPoint, position > a + 0.5 else { throw LibraryFailure.app("ab_repeat_invalid") }
        bPoint = position
        restartAt = a
      default: aPoint = nil; bPoint = nil
      }
      updateLoop()
      if let restartAt = restartAt { seek(restartAt) }
    }
    let defaults = UserDefaults.standard
    defaults.set(mode, forKey: "playback.mode")
    defaults.set(continuous, forKey: "playback.continuous"); defaults.set(background, forKey: "playback.background"); defaults.set(autoResume, forKey: "playback.resume")
    publish()
  }

  func playerDismissed() {
    restoreBrightness()
    // Returning while another item is still waiting must not start that item
    // later. Already-playing audio remains unchanged for the mini-player.
    pendingReplacement?.autoplay = false
    deferredPresentationLoad?.autoplay = false
    if presentationWaiting {
      wantsPlayback = false; resumeAfterInterruption = false
      cancelAudioRecovery(); pauseEngine()
    }
    // A later return-to-library intent cancels an unfinished PiP request. An
    // already active manual PiP session and ordinary audio keep their intent.
    if !pipActive {
      revokeManualPiP()
      if mediaKitPiP != nil { stopMediaKitPiPAndRestoreVideoOutput() }
      else if mediaKitPiPPreparing { discardMediaKitPiP() }
      if pendingReplacement == nil { discardAVPlayerPiP() }
    }
    publish()
  }

  func restoreBrightness() {
    if let value = savedBrightness { UIScreen.main.brightness = value; savedBrightness = nil }
  }

  func requestSubtitle(path: String, session: Int, completion: @escaping (String?) -> Void) {
    // The file chooser belongs to the media session in which it was opened.
    // Validate before reading the file or sending any command to either engine.
    guard session == generation, timelineReady, !seekFault, currentPath != nil else {
      completion("track_selection_stale"); return
    }
    guard let engine = mediaKit else {
      do { try loadSubtitle(path: path); completion(nil) }
      catch { completion((error as? LibraryFailure)?.code ?? "subtitle_load_failed") }
      return
    }
    guard !controlBusy, trackSelection == nil else { completion("subtitle_switch_busy"); return }
    do {
      let url = try library.url(path)
      let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      guard size <= 10 * 1024 * 1024 else { throw LibraryFailure.app("subtitle_too_large") }
      controlBusy = true
      let token = generation
      engine.control("subtitle", arguments: ["url": url.absoluteString]) { [weak self] success in
        guard let self else { completion("control_superseded"); return }
        self.controlBusy = false
        guard self.generation == token, self.mediaKit === engine else { completion("control_superseded"); return }
        if success {
          self.cues = []; self.subtitleName = url.lastPathComponent
          self.surface?.caption.isHidden = true; self.publish()
        }
        completion(success ? nil : "subtitle_load_failed")
      }
    } catch { completion((error as? LibraryFailure)?.code ?? "subtitle_load_failed") }
  }

  func attachSurface(_ view: PlayerSurface) {
    surface = view
    view.onLayout = nil
    if mediaKit != nil { view.videoLayer.player = nil; view.caption.isHidden = true; return }
    view.videoLayer.isHidden = false
    view.videoLayer.videoGravity = fit == "fill" ? .resizeAspectFill : fit == "stretch" ? .resize : .resizeAspect
    view.caption.text = subtitleText
    view.caption.isHidden = subtitleText.isEmpty
    if hasValidAVPlayerPresentationItem && (avPlayerPiPAuthorized || pipActive) {
      // Preserve the explicit PiP handoff without rebuilding its controller.
      attachAVPlayerPresentationIfAllowed(reason: "authorized PiP surface attached")
    } else {
      ensureAVPlayerPresentation(reason: "surface attached")
    }
  }

  private func tick() {
    nativePlaybackTiming.observeTick(now: ProcessInfo.processInfo.systemUptime,
      eligible: UIApplication.shared.applicationState == .active && mediaKit?.playing == true
        && wantsPlayback && !loading && !isSeeking && !scrubbing && !interrupted
        && !audioRecoveryPending && !audioRecoveryExhausted && decoderRecoveryRequest == nil
        && !presentationWaiting && !pipRequesting && !pipActive,
      generation: generation)
    // Starting PiP has a finite grace window. Restoring/retiring controllers
    // and stale requests are never permission to keep background audio alive.
    if manualPiPSession != nil && !manualPiPAllowsBackground {
      revokeManualPiP()
      if mediaKit != nil { stopMediaKitPiPAndRestoreVideoOutput() }
      // AVPlayer's phase watchdog or explicit cancellation owns its lifecycle.
      // After an active session ends, this heartbeat may revoke background
      // audio permission but must not turn a pending didStop into retirement.
    }
    enforcePlaybackEnvironment()
    captureRememberedProgress()
    checkTrackSelection()
    if let engine = mediaKit, !preparedMediaKit, !seekFault { mediaKitChanged(engine, token: generation) }
    if let deadline = sleepUntil, Date() >= deadline { sleepTimer?.invalidate(); sleepTimer = nil; sleepUntil = nil; pause() }
    if let a = aPoint, let b = bPoint, wantsPlayback, !interrupted, !scrubbing, !isSeeking,
       position > b + 0.35 {
      seek(a)
      return
    }
    // External files keep their original movie timestamps; embedded tracks were rebased with the asset.
    let subtitlePosition = position + timelineOrigin
    let text = cues.first(where: { $0.start <= subtitlePosition && subtitlePosition < $0.end })?.text ?? ""
    if subtitleText != text { subtitleText = text; surface?.caption.text = text; surface?.caption.isHidden = text.isEmpty }
    if wantsPlayback && !scrubbing && !isSeeking && Date().timeIntervalSince(lastSave) >= 5 { persist() }
    publish()
  }

  private var progressValid: Bool {
    let currentPosition = mediaKit?.position ?? player.currentTime().seconds
    return timelineReady && !seekFault && initialPositionEstablished
      && !detectingIntro && !loading && !isSeeking && !scrubbing
      && currentPath != nil && currentPosition.isFinite && currentPosition >= 0
      && duration.isFinite && duration > 0 && timelineOrigin.isFinite
  }

  private func captureRememberedProgress() {
    guard progressValid, let path = currentPath else { return }
    // This volatile checkpoint is deliberately maintained with history OFF.
    // Existing generation/engine/snapshot fences and progressValid exclude
    // loading, previews, unacknowledged seeks and failed output positions.
    currentSessionCheckpoint = CurrentSessionCheckpoint(sessionID: currentSessionID,
      path: path, generation: generation, engineID: mediaKit?.id,
      sourcePosition: position + timelineOrigin)
    guard rememberProgress else { return }
    let completed = sessionCompleted
    lastValidRememberedProgress = ["position": completed ? 0.0 : position,
      "duration": duration, "timelineOrigin": timelineOrigin, "completed": completed]
  }

  func persist() {
    guard progressValid, let path = currentPath else { return }
    captureRememberedProgress()
    var record: [String: Any] = rememberProgress ? lastValidRememberedProgress ?? [:] : [:]
    record["lastPlayed"] = Date().timeIntervalSince1970
    library.recordStore.updateProgress(path: path, fields: record)
    // Submission throttle only; the store tracks dirty data and retries failed commits.
    lastSave = Date()
  }

  private func fail(_ message: String) {
    // These are real stopped/exhausted media states, unlike PiP transactions.
    // Keep the precise cause for diagnostics, with one non-blocking failure
    // label in the UI. This does not change any recovery budget or policy.
    let displayMessage: String
    switch message {
    case "media_engine_cleanup_failed", "media_decoder_recovery_failed":
      lastDiagnostic = message + (lastDiagnostic.isEmpty ? "" : ": " + lastDiagnostic)
      displayMessage = "media_playback_failed"
    default: displayMessage = message
    }
    currentSessionPositionRestore = nil
    generation += 1
    let token = generation
    seekFault = true; timelineReady = false
    decoderRecoveryRequest = nil
    revokeManualPiP(enforce: false)
    // Preparation is cancellable; an issued/observed controller is retained by
    // retirement or by the existing replacement stop fence until a terminal.
    if pendingReplacement == nil {
      discardAVPlayerPiP()
      discardMediaKitPiP()
    }
    cancelAudioRecovery()
    finishTrackSelection("track_selection_stale")
    guard generation == token else { return }
    cancelIntroDetection()
    assetPreparationTask?.cancel(); assetPreparationTask = nil
    openingTimeout?.cancel(); cancelSeeks()
    guard generation == token else { return }
    loading = false; wantsPlayback = false; pauseEngine(); errorMessage = displayMessage; publish()
  }

  private func interruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    if type == .began {
      let routeDisconnected: Bool
      if #available(iOS 17.0, *),
        let reasonRaw = note.userInfo?[AVAudioSessionInterruptionReasonKey] as? UInt,
        let reason = AVAudioSession.InterruptionReason(rawValue: reasonRaw) {
        routeDisconnected = reason == .routeDisconnected
      } else {
        routeDisconnected = false
      }
      let recentlyReturnedToSpeaker =
        ProcessInfo.processInfo.systemUptime <= routeLossRecoveryDeadline &&
        AVAudioSession.sharedInstance().currentRoute.outputs.contains {
          $0.portType == .builtInSpeaker
        }
      if routeDisconnected || recentlyReturnedToSpeaker {
        cancelAudioRecovery()
        interrupted = false; resumeAfterInterruption = false; wantsPlayback = false
        pendingReplacement?.autoplay = false; deferredPresentationLoad?.autoplay = false
        scrubbing = false; errorMessage = ""
        pauseEngine(); persist(); publish()
        return
      }
      resumeAfterInterruption = wantsPlayback
      cancelAudioRecovery(clearPending: false)
      audioRecoveryPending = resumeAfterInterruption
      interrupted = true; scrubbing = false; errorMessage = ""
      pauseEngine(); persist(); publish()
    } else {
      // Ignore duplicate or delayed end notifications after another recovery path
      // has already reactivated the session and cleared the interruption.
      guard interrupted else { return }
      interrupted = false
      let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      let resume = resumeAfterInterruption && wantsPlayback && playbackEnvironmentAllowsPlayback && autoResume && options.contains(.shouldResume)
      resumeAfterInterruption = false
      errorMessage = ""
      if resume {
        audioRecoveryPending = true
        audioRecoveryRequiresAutoResume = true
        attemptAudioRecovery(resetAttempts: true)
      } else {
        cancelAudioRecovery()
        wantsPlayback = false
        pendingReplacement?.autoplay = false; deferredPresentationLoad?.autoplay = false
        pauseEngine(); publish()
      }
    }
  }

  private func routeChanged(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
      let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
      reason == .oldDeviceUnavailable else { return }
    cancelAudioRecovery()
    let wasDetectingIntro = detectingIntro
    if wasDetectingIntro { cancelIntroDetection() }
    wantsPlayback = false; resumeAfterInterruption = false; scrubbing = false
    pendingReplacement?.autoplay = false; deferredPresentationLoad?.autoplay = false
    pauseEngine(); errorMessage = ""
    if wasDetectingIntro { finishStart(0, token: introToken, itemGeneration: generation) }

    let wirelessOrHeadphones: [AVAudioSession.Port] = [
      .bluetoothA2DP, .bluetoothHFP, .bluetoothLE, .headphones,
    ]
    let previousRoute = note.userInfo?[AVAudioSessionRouteChangePreviousRouteKey]
      as? AVAudioSessionRouteDescription
    let removedPrivateOutput = previousRoute?.outputs.contains {
      wirelessOrHeadphones.contains($0.portType)
    } == true
    let switchedToSpeaker = AVAudioSession.sharedInstance().currentRoute.outputs.contains {
      $0.portType == .builtInSpeaker
    }
    if removedPrivateOutput && switchedToSpeaker {
      interrupted = false
      routeLossRecoveryDeadline = ProcessInfo.processInfo.systemUptime + 2
    } else {
      routeLossRecoveryDeadline = 0
    }
    persist(); publish()
  }

  private func activateAudioSession(reason: String = "playback") throws {
    let controller = mediaKit == nil ? pip : nil
    if let controller { recordAVPlayerPiPEvent("audio activation attempted", controller: controller) }
    do {
      let session = AVAudioSession.sharedInstance()
      if session.category != .playback || session.mode != .moviePlayback || !session.categoryOptions.isEmpty {
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
      }
      nativePlaybackTiming.recordAudioCall(activate: true, reason: "activate:" + reason, generation: generation)
      try session.setActive(true)
      audioSessionActivated = true
      routeLossRecoveryDeadline = 0
      if let controller { recordAVPlayerPiPEvent("audio activation succeeded", controller: controller) }
    } catch {
      if let controller { recordAVPlayerPiPEvent("audio activation failed", controller: controller, error: error) }
      throw error
    }
  }

  private func mediaServicesWereReset() {
    // The system discarded the old audio objects/session. Rebuild safely, but
    // Apple requires a new user action before starting media after this event.
    persist()
    audioSessionActivated = false
    interrupted = false; resumeAfterInterruption = false
    routeLossRecoveryDeadline = 0
    rebuildPlayerAfterMediaServicesReset = true
    pause()
    errorMessage = ""
    guard currentPath != nil else { publish(); return }
    load(resume: true, autoplay: false)
    lastDiagnostic = "media services reset: rebuilt paused; awaiting explicit play"
    publish()
  }

  private func trackDescriptions(_ options: [AVMediaSelectionOption], fallback: [AVPlayerItemTrack]) -> [[String: Any]] {
    if !options.isEmpty {
      return options.enumerated().map { ["index": $0.offset, "name": $0.element.displayName] }
    }
    return fallback.enumerated().map { index, itemTrack in
      let language = itemTrack.assetTrack?.extendedLanguageTag ?? itemTrack.assetTrack?.languageCode ?? "und"
      return ["index": index, "name": "Track \(index + 1) · \(language)"]
    }
  }

  private func loadTracks(_ item: AVPlayerItem) {
    fallbackAudio = []; fallbackSubtitles = []
    if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible) {
      audioOptions = group.options
      selectedAudio = group.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: group) }) ?? -1
    }
    if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible) {
      subtitleOptions = group.options
      selectedSubtitle = group.options.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: group) }) ?? -1
    }
    // Compositions may expose tracks without URL-asset media selection groups.
    if audioOptions.isEmpty {
      fallbackAudio = item.tracks.filter { $0.assetTrack?.mediaType == .audio }
      selectedAudio = fallbackAudio.isEmpty ? -1 : 0
      for (index, track) in fallbackAudio.enumerated() { track.isEnabled = index == selectedAudio }
    }
    if subtitleOptions.isEmpty {
      fallbackSubtitles = item.tracks.filter {
        guard let type = $0.assetTrack?.mediaType else { return false }
        return type == .subtitle || type == .text || type == .closedCaption
      }
      selectedSubtitle = -1
      fallbackSubtitles.forEach { $0.isEnabled = false }
    }
  }

  func requestTrack(kind: String, index: Int, id: String?, session: Int, completion: @escaping (String?) -> Void) throws {
    guard session == generation, timelineReady, !seekFault, currentPath != nil else {
      throw LibraryFailure.app("track_selection_stale")
    }
    guard ["audio", "subtitle"].contains(kind), trackSelection == nil else {
      throw LibraryFailure.app("track_request_invalid")
    }
    let disabled = kind == "subtitle" && index == -1 && id == nil
    guard disabled || index >= 0 else { throw LibraryFailure.app("track_request_invalid") }
    if let mediaKit = mediaKit {
      guard disabled || id?.isEmpty == false else { throw LibraryFailure.app("track_selection_stale") }
      guard mediaKit.select(kind: kind, trackID: disabled ? nil : id) else { throw LibraryFailure.app("track_selection_stale") }
      mediaKit.recordDiagnostic("track request session=\(generation) kind=\(kind) id=\(id ?? "off")")
    } else {
      try selectTrack(kind: kind, index: index)
    }
    trackSelection = (generation, kind, disabled ? nil : id, index, ProcessInfo.processInfo.systemUptime + 3, completion)
    checkTrackSelection()
    publish()
  }

  private func finishTrackSelection(_ error: String?) {
    guard let request = trackSelection else { return }
    trackSelection = nil
    mediaKit?.recordDiagnostic("track \(error == nil ? "confirmed" : "unconfirmed") session=\(request.generation) kind=\(request.kind) id=\(request.id ?? "off")")
    if error == nil && request.kind == "subtitle" {
      cues = []; subtitleName = ""; subtitleText = ""
      surface?.caption.text = ""; surface?.caption.isHidden = true
    }
    request.done(error)
  }

  private func checkTrackSelection() {
    if mediaKit == nil, let item = player.currentItem {
      if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .audible), !audioOptions.isEmpty {
        selectedAudio = audioOptions.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: group) }) ?? -1
      } else { selectedAudio = fallbackAudio.firstIndex(where: { $0.isEnabled }) ?? -1 }
      if let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: .legible), !subtitleOptions.isEmpty {
        selectedSubtitle = subtitleOptions.firstIndex(where: { $0 == item.currentMediaSelection.selectedMediaOption(in: group) }) ?? -1
      } else { selectedSubtitle = fallbackSubtitles.firstIndex(where: { $0.isEnabled }) ?? -1 }
    }
    guard let request = trackSelection else { return }
    guard request.generation == generation, timelineReady, !seekFault else {
      finishTrackSelection("track_selection_stale"); return
    }
    let confirmed: Bool
    if let mediaKit = mediaKit {
      let rows = mediaKit.trackState["\(request.kind)Tracks"] as? [[String: Any]] ?? []
      let selected = rows.filter { ($0["selected"] as? Bool) == true }
      confirmed = request.id == nil ? selected.isEmpty : selected.count == 1 && (selected.first?["id"] as? String) == request.id
    } else {
      confirmed = (request.kind == "audio" ? selectedAudio : selectedSubtitle) == request.index
    }
    if confirmed { finishTrackSelection(nil) }
    else if ProcessInfo.processInfo.systemUptime >= request.deadline {
      finishTrackSelection("track_switch_unconfirmed")
    }
  }

  private func selectTrack(kind: String, index: Int) throws {
    if let mediaKit = mediaKit {
      guard mediaKit.select(kind: kind, index: index) else { throw LibraryFailure.app("track_selection_stale") }
      if kind == "subtitle" { cues = []; subtitleName = ""; surface?.caption.text = ""; surface?.caption.isHidden = true }
      publish(); return
    }
    guard let item = player.currentItem else { return }
    let options = kind == "audio" ? audioOptions : subtitleOptions
    let fallback = kind == "audio" ? fallbackAudio : fallbackSubtitles
    let count = options.isEmpty ? fallback.count : options.count
    guard index == -1 || (0..<count).contains(index) else { throw LibraryFailure.app("track_selection_stale") }
    if kind == "audio" && index < 0 { return }
    if !options.isEmpty, let group = item.asset.mediaSelectionGroup(forMediaCharacteristic: kind == "audio" ? .audible : .legible) {
      item.select(index == -1 ? nil : options[index], in: group)
    } else {
      for (i, track) in fallback.enumerated() { track.isEnabled = i == index }
    }
    if kind == "audio" { selectedAudio = index }
    else { selectedSubtitle = index; cues = []; subtitleName = ""; surface?.caption.text = "" }
    publish()
  }

  private func loadSubtitle(path: String) throws {
    guard trackSelection == nil else { throw LibraryFailure.app("subtitle_switch_busy") }
    let url = try library.url(path)
    library.scheduleProtectionNormalization(paths: [path])
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 10 * 1024 * 1024 else { throw LibraryFailure.app("subtitle_too_large") }
    guard mediaKit == nil else { throw LibraryFailure.app("subtitle_load_failed") }
    guard ["srt", "vtt"].contains(url.pathExtension.lowercased()) else {
      throw LibraryFailure.app("subtitle_format_unsupported")
    }
    let text = try String(contentsOf: url, encoding: .utf8)
      .replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    func stamp(_ value: String) -> Double? {
      let pieces = value.replacingOccurrences(of: ",", with: ".").split(separator: ":").compactMap { Double($0) }
      if pieces.count == 3 { return pieces[0] * 3600 + pieces[1] * 60 + pieces[2] }
      if pieces.count == 2 { return pieces[0] * 60 + pieces[1] }
      return nil
    }
    var parsed: [SubtitleCue] = []
    for block in text.components(separatedBy: "\n\n") {
      let lines = block.components(separatedBy: "\n")
      guard let i = lines.firstIndex(where: { $0.contains("-->") }), i + 1 < lines.count else { continue }
      let fields = lines[i].components(separatedBy: "-->")
      guard fields.count == 2,
        let start = stamp(fields[0].trimmingCharacters(in: .whitespaces)),
        let endString = fields[1].trimmingCharacters(in: .whitespaces).split(separator: " ").first,
        let end = stamp(String(endString)), end > start else { continue }
      let caption = lines[(i + 1)...].joined(separator: "\n").replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
      parsed.append(SubtitleCue(start: start, end: end, text: caption))
    }
    guard !parsed.isEmpty else { throw LibraryFailure.app("subtitle_timeline_invalid") }
    if detectingIntro { seek(position) }
    try selectTrack(kind: "subtitle", index: -1)
    cues = parsed.sorted { $0.start < $1.start }; subtitleName = URL(fileURLWithPath: path).lastPathComponent; publish()
  }

  func stopForMutation(_ path: String) {
    guard queue.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) else { return }
    pause()
    resetCurrentSessionCheckpoint()
    generation += 1
    let token = generation
    finishTrackSelection("track_selection_stale")
    guard generation == token else { return }
    assetPreparationTask?.cancel(); assetPreparationTask = nil
    cancelSeeks()
    guard generation == token else { return }
    clearBoundary(); openingTimeout?.cancel()
    timelineReady = false; timelineOrigin = 0
    queue = []; index = 0; aPoint = nil; bPoint = nil; cues = []; loading = false
    sessionCompleted = false; atPlaybackEnd = false; pendingEndAction = false
    subtitleName = ""; subtitleText = ""; surface?.caption.text = ""; surface?.caption.isHidden = true
    sleepTimer?.invalidate(); sleepTimer = nil; sleepUntil = nil; errorMessage = ""
    let controller = pendingReplacement?.controller
      ?? (avPlayerPiPOwnsPresentation ? pip : nil)
      ?? mediaKitPiP?.controller
    if let controller {
      awaitPresentationStop(controller, resume: false, autoplay: false, clearOnly: true)
    } else if !blockingRetiringPiP {
      deferredPresentationLoad = nil
      clearPlaybackEnginesAfterMutation()
    } else {
      deferPresentationLoad(resume: false, autoplay: false, clearOnly: true)
    }
    publish()
  }

  func remapQueuePath(from old: String, to new: String) {
    let currentWasRemapped = currentPath.map { $0 == old || $0.hasPrefix(old + "/") } == true
    let shouldResume = wantsPlayback
    var changed = false
    queue = queue.map { path in
      guard path == old || path.hasPrefix(old + "/") else { return path }
      changed = true
      return new + String(path.dropFirst(old.count))
    }
    guard changed else { return }
    persist()
    if currentWasRemapped {
      load(resume: true, autoplay: shouldResume)
    } else {
      publish()
    }
  }

  private func scheduleOpenTimeout(token: Int) {
    openingTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.generation == token, !self.timelineReady else { return }
      self.fail("open_timeout")
    }
    openingTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 15, execute: timeout)
  }

  private func fallbackToMediaKit(url: URL, resume: Bool, token: Int, error: Error) {
    guard generation == token else { return }
    let detail = error as NSError
    lastDiagnostic = "\(detail.domain) (\(detail.code)): \(detail.localizedDescription)"
    if let underlying = detail.userInfo[NSUnderlyingErrorKey] as? NSError {
      lastDiagnostic += " | \(underlying.domain) (\(underlying.code)): \(underlying.localizedDescription)"
    }
    // Only container/decoder failures justify trying a different engine.
    let mediaFailure = detail.domain == AVFoundationErrorDomain && [-11800, -11821, -11828, -11829, -11833].contains(detail.code)
    guard !fallbackUsed, mediaFailure else { fail("media_playback_failed"); return }
    guard !avPlayerPiPOwnsPresentation, !pipActive, mediaKitPiP == nil, !blockingRetiringPiP,
      pendingReplacement == nil else {
      // Do not replace an engine underneath a PiP stop/start handshake. The
      // explicit retry path stops presentation before rebuilding playback.
      fail("media_playback_failed"); return
    }
    fallbackUsed = true
    engineNotice = "fallback_engine_active"
    openMediaKit(url: url, resume: resume, token: token)
  }

  private func openMediaKit(url: URL, resume: Bool, token: Int) {
    guard generation == token else { return }
    cancelIntroDetection()
    clearBoundary()
    revokeManualPiP()
    discardAVPlayerPiP()
    if wantsPlayback && playbackEnvironmentAllowsPlayback && !interrupted {
      do {
        try activateAudioSession(reason: "media-open")
      } catch {
        lastDiagnostic = error.localizedDescription
        audioRecoveryPending = wantsPlayback
        errorMessage = ""
      }
    }
    cancelSeeks()
    guard generation == token else { return }
    installedAVPlayerItem = nil
    player.pause(); player.replaceCurrentItem(with: nil)
    observations.removeAll()
    timelineReady = false; timelineOrigin = 0; preparedMediaKit = false
    initialPositionEstablished = false; initialHistoricalSeekPending = false; sessionCompleted = false; atPlaybackEnd = false; pendingEndAction = false
    nonSeekableStartPosition = nil
    loading = true
    guard let transport = mediaKitTransport else { fail("playback_channel_unavailable"); return }
    let engine = LeeMediaKitEngine(transport: transport)
    mediaKit = engine
    if let restore = currentSessionPositionRestore,
       restore.targetGeneration == token, restore.checkpoint.sessionID == currentSessionID,
       restore.checkpoint.path == currentPath, restore.sourceEngineID != engine.id {
      currentSessionPositionRestore?.targetEngineID = engine.id
    }
    engine.rate = rate; engine.volume = mediaVolume
    engine.changed = { [weak self, weak engine] in
      guard let self = self, let engine = engine, self.generation == token, self.mediaKit === engine else { return }
      self.mediaKitChanged(engine, token: token)
    }
    surface?.videoLayer.player = nil
    surface?.caption.isHidden = true
    scheduleOpenTimeout(token: token)
    engine.open(url: url, isAudio: mediaIsAudio)
    publish()
  }

  private func mediaKitChanged(_ engine: LeeMediaKitEngine, token: Int) {
    if !engine.failure.isEmpty {
      if errorMessage != engine.failure { lastDiagnostic = engine.failure; fail(engine.failure) }
      return
    }
    if engine.seekable, nonSeekableStartPosition != nil, !initialPositionEstablished {
      // An initially unavailable seek capability may settle after metadata.
      // Preserve the original resume intent until positioning actually starts.
      nonSeekableStartPosition = nil
      preparedMediaKit = false; loading = true
    }
    if engine.ready && engine.duration > 0 && engine.seekabilityKnown && !preparedMediaKit {
      preparedMediaKit = true; timelineReady = true; openingTimeout?.cancel()
      if restoreCurrentSessionPositionIfNeeded(engine: engine, generation: token) { return }
      let startToken = introToken
      library.recordStore.readPlaybackRecord(path: currentPath ?? "") { [weak self, weak engine] record in
        guard let self = self, let engine = engine, self.generation == token,
          self.mediaKit === engine, !self.seekFault, self.introToken == startToken else { return }
        let saved = (record["position"] as? NSNumber)?.doubleValue ?? 0
        let previousOrigin = (record["timelineOrigin"] as? NSNumber)?.doubleValue ?? 0
        let sourceTime = saved > 0 ? saved + previousOrigin : 0
        let start = self.rememberProgress && self.pendingResume && sourceTime.isFinite && sourceTime > 0 && sourceTime < self.duration - 2 ? sourceTime : 0
        // Keep the historical record intact until positioning is acknowledged.
        self.loading = false
        if engine.seekable {
          if self.engineNotice == "media_not_seekable" { self.engineNotice = "" }
          self.initialHistoricalSeekPending = start > 0
          self.finishStart(start, token: self.introToken, itemGeneration: token)
        } else {
          self.engineNotice = "media_not_seekable"
          self.nonSeekableStartPosition = engine.position
          if self.wantsPlayback { self.attemptAudioRecovery() }
          self.publish()
        }
      }
      return
    }
    if let initial = nonSeekableStartPosition, !initialPositionEstablished,
      engine.ready, engine.playing, !engine.buffering, engine.position > initial,
      !seekFault, !loading, !isSeeking, !scrubbing {
      // Metadata-ready at zero is not proof of a playable non-seekable stream.
      // Only observed playback advancement can replace its historical record.
      nonSeekableStartPosition = nil
      initialPositionEstablished = true
      persist()
    }
    if engine.ended { offerEndCandidate(source: "media_kit snapshot"); return }
    captureRememberedProgress()
  }

  func receiveMediaKitState(_ state: [String: Any]) {
    guard let engine = mediaKit, state["engineId"] as? String == engine.id else { return }
    engine.update(state)
    // A late transport snapshot cannot reauthorize audio after a native pause.
    if !playbackEnvironmentAllowsPlayback { enforcePlaybackEnvironment() }
    deactivateAudioSessionIfIdle()
  }

  func requestMediaKitDecoderRecovery(engineID: String, positionVersion: Int,
                                      completion: @escaping (Bool) -> Void) {
    guard let engine = mediaKit else { completion(false); return }
    let stable = timelineReady && !loading && !seekFault && !isSeeking && !scrubbing
      && !interrupted && !controlBusy && trackSelection == nil
    let presentationOwned = pipRequesting || pip != nil || pendingReplacement != nil || blockingRetiringPiP
    let otherwiseEligible = MediaKitDecoderRecoveryPolicy.permitsRequest(
      identityMatches: engine.id == engineID && engine.positionVersion == positionVersion,
      active: !inBackground && UIApplication.shared.applicationState == .active,
      wantsPlayback: wantsPlayback, stable: stable, presentationOwned: presentationOwned,
      attempted: false, recovering: decoderRecoveryRequest != nil)
    guard otherwiseEligible else { completion(false); return }
    guard !decoderRecoveryAttempted else {
      engine.recordDiagnostic("decoder recovery budget exhausted for current playback task")
      fail("media_decoder_recovery_failed")
      completion(false); return
    }
    let requestID = UUID(), token = generation
    let playIntentVersion = engine.playIntentVersion
    decoderRecoveryAttempted = true
    decoderRecoveryRequest = (requestID, token)
    engine.recordDiagnostic("bounded decoder recovery requested")
    publish()
    // The same mpv player/output stay in place. Dart performs the supported
    // hwdec reinitialization and respects newer pause/seek intent.
    engine.control("recoverDecoder", arguments: [:]) { [weak self, weak engine] success in
      DispatchQueue.main.async {
        guard let self, let engine, self.mediaKit === engine, self.generation == token,
              self.decoderRecoveryRequest?.id == requestID else { completion(false); return }
        self.decoderRecoveryRequest = nil
        if !success && (engine.positionVersion != positionVersion || engine.playIntentVersion != playIntentVersion) {
          engine.recordDiagnostic("decoder recovery superseded by newer seek/play intent")
          self.publish()
          completion(true)
          return
        }
        if success {
          engine.recordDiagnostic("decoder recovery command acknowledged; output not measured")
          self.publish()
        } else {
          self.fail("media_decoder_recovery_failed")
        }
        completion(success)
      }
    }
  }

  func startPiP(delegate: AVPictureInPictureControllerDelegate, requestID: String? = nil) throws {
    guard decoderRecoveryRequest == nil else { throw LibraryFailure.app("pip_busy") }
    guard pendingReplacement == nil else { throw LibraryFailure.app("pip_ending") }
    guard retiringPiP.isEmpty else { throw LibraryFailure.app("pip_ending") }
    guard !mediaIsAudio else { throw LibraryFailure.app("pip_audio_unnecessary") }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw LibraryFailure.app("pip_unsupported")
    }
    if let mediaKit = mediaKit {
      guard !mediaKitPiPPreparing, mediaKitPiP == nil, !mediaKitPiPRestoring else {
        throw LibraryFailure.app("pip_busy")
      }
      guard let requestID = requestID, !requestID.isEmpty else {
        throw LibraryFailure.app("pip_request_invalid")
      }
      authorizeManualPiP(seconds: 28)
      mediaKitPiPPreparing = true
      mediaKitPiPRequestID = requestID
      let timeout = DispatchWorkItem { [weak self, weak mediaKit] in
        guard let self = self, let mediaKit = mediaKit,
              self.mediaKit === mediaKit, self.mediaKitPiPPreparing,
              self.mediaKitPiPRequestID == requestID else { return }
        self.mediaKitPiPPreparing = false
        self.mediaKitPiPRequestID = nil
        self.mediaKitPiPPreparationTimeout = nil
        self.revokeManualPiP()
        self.recordPiPFailure("media_kit preparation timed out")
        self.publish()
      }
      mediaKitPiPPreparationTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: timeout)
      publish()
      mediaKit.startPiP(requestID: requestID) { [weak self, weak mediaKit] success in
        guard let self = self, let mediaKit = mediaKit, self.mediaKit === mediaKit else { return }
        if !success && self.mediaKitPiPRequestID == requestID {
          self.mediaKitPiPPreparationTimeout?.cancel()
          self.mediaKitPiPPreparationTimeout = nil
          self.mediaKitPiPPreparing = false
          self.mediaKitPiPRequestID = nil
          self.revokeManualPiP()
          self.recordPiPFailure("media_kit start rejected")
          self.publish()
        }
      }
    } else {
      if pipRequesting { throw LibraryFailure.app("pip_busy") }
      try beginAVPlayerPiP(delegate: delegate)
    }
  }

  func recordPiPFailure(_ detail: String) {
    lastDiagnostic = "PiP: \(detail)"
    recordLifecycle(lastDiagnostic)
  }

  // Unfiltered delegate entry evidence. Do not query playerLayer here: unknown
  // and media_kit controllers may use a sample-buffer ContentSource instead.
  func recordPiPDelegateEntry(_ event: String, controller: AVPictureInPictureController,
                              error: Error? = nil) {
    let key = ObjectIdentifier(controller)
    let originMain = Thread.isMainThread
    let entryUptime = ProcessInfo.processInfo.systemUptime
    let errorCode = error.map { ($0 as NSError).code }
    if originMain {
      recordPiPDelegateEntryOnMain(event, controller: controller, key: key,
        originMain: true, entryUptime: entryUptime, errorCode: errorCode)
    } else {
      // Do not read ownership, UI, or log arrays off-main. Only the diagnostic
      // is queued; the original delegate control callback keeps its timing.
      DispatchQueue.main.async { [weak self, weak controller] in
        self?.recordPiPDelegateEntryOnMain(event, controller: controller, key: key,
          originMain: false, entryUptime: entryUptime, errorCode: errorCode)
      }
    }
  }

  private func recordPiPDelegateEntryOnMain(_ event: String, controller: AVPictureInPictureController?,
                                            key: ObjectIdentifier, originMain: Bool,
                                            entryUptime: Double, errorCode: Int?) {
    var owner = "unknown"
    var kind = "unknown"
    if let controller {
      if let entry = retiringPiP[key], entry.controller === controller {
        owner = "retiring"; kind = entry.renderer == nil ? "AVPlayer" : "media_kit"
      } else if pip === controller {
        owner = "current"; kind = "AVPlayer"
      } else if mediaKitPiP?.controller === controller {
        owner = "current"; kind = "media_kit"
      }
    }
    // Never attribute a reused unknown address to an earlier request. For a
    // queued entry, ownership is sampled now, not at the earlier callback time.
    let idlePreparation = owner == "current" && kind == "AVPlayer"
      && avPlayerPiPRequest == nil && !avPlayerPiPOwnsPresentation && pendingReplacement == nil
    let trace = owner != "unknown" && kind == "AVPlayer" && !idlePreparation
      ? avPlayerPiPTraceRequests.last(where: { $0.controller == key }) : nil
    let request = trace.map { "request=\($0.request) requestGeneration=\($0.generation)" }
      ?? "request=unknown requestGeneration=unknown"
    let failure = errorCode.map { " errorCode=\($0)" } ?? ""
    let sample = originMain ? "entry" : "deferred"
    let details = originMain ? "mainThread" : "skippedOffMain"
    recordLifecycle("PiP delegate entry \(event) controller=\(key) owner=\(owner) kind=\(kind) \(request) main=\(Thread.isMainThread) originMain=\(originMain) entryUptime=\(String(format: "%.3f", entryUptime)) ownershipSample=\(sample) objectAlive=\(controller != nil) avDetails=\(details)\(failure)")
  }

  private static func pipDiagnosticIdentity(_ value: AnyObject?) -> String {
    value.map { String(describing: ObjectIdentifier($0)) } ?? "nil"
  }

  private static func pipDiagnosticRect(_ rect: CGRect) -> String {
    if rect.isNull { return "null" }
    if rect.isInfinite { return "infinite" }
    return String(format: "[%.1f,%.1f,%.1f,%.1f]",
                  Double(rect.origin.x), Double(rect.origin.y), Double(rect.width), Double(rect.height))
  }

  // On-demand, bounded snapshots only; no observers, asynchronous work, stored
  // object references, layout passes, route names/UIDs, URLs or media metadata.
  private func avPlayerPiPSourceSnapshot(layer: AVPlayerLayer?) -> String {
    guard Thread.isMainThread else { return "sourceSnapshot=skippedOffMain" }
    let session = AVAudioSession.sharedInstance()
    let inputs = session.currentRoute.inputs.prefix(4).map { String($0.portType.rawValue.prefix(40)) }
    let outputs = session.currentRoute.outputs.prefix(4).map { String($0.portType.rawValue.prefix(40)) }
    var fields = ["audioCategory=\(session.category.rawValue) audioMode=\(session.mode.rawValue) audioOptions=\(session.categoryOptions.rawValue) audioInputs=\(inputs) audioOutputs=\(outputs)"]
    if let layer {
      fields.append("sourceLayer=\(Self.pipDiagnosticIdentity(layer)) sourcePlayer=\(Self.pipDiagnosticIdentity(layer.player)) sourceItem=\(Self.pipDiagnosticIdentity(layer.player?.currentItem)) layerBounds=\(Self.pipDiagnosticRect(layer.bounds)) layerFrame=\(Self.pipDiagnosticRect(layer.frame)) videoRect=\(Self.pipDiagnosticRect(layer.videoRect)) layerHidden=\(layer.isHidden) layerOpacity=\(layer.opacity) firstFrameReady=\(layer.isReadyForDisplay)")
      // A surface replacement must not claim the new view owns the old layer.
      let source = surface.flatMap { layer === $0.layer || layer.superlayer === $0.layer ? $0 : nil }
      fields.append("surface=\(Self.pipDiagnosticIdentity(source)) currentSurface=\(Self.pipDiagnosticIdentity(surface)) sourceIsCurrentLayer=\(surface?.videoLayer === layer)")
      if let source {
        let window = source.window
        fields.append("surfaceHidden=\(source.isHidden) surfaceAlpha=\(source.alpha) window=\(Self.pipDiagnosticIdentity(window)) windowHidden=\(window?.isHidden ?? true) windowAlpha=\(window?.alpha ?? 0) windowKey=\(window?.isKeyWindow ?? false) sceneState=\(window?.windowScene?.activationState.rawValue ?? -1)")
        var intersection = window.map { layer.convert(layer.bounds, to: $0.layer).intersection($0.bounds) } ?? .null
        var hidden = layer.isHidden || (window?.isHidden ?? true)
        var alpha = layer === source.layer ? 1.0 : Double(layer.opacity)
        var ancestors: [String] = []
        var ancestor: UIView? = source
        while let view = ancestor, ancestors.count < 8 {
          ancestors.append("\(Self.pipDiagnosticIdentity(view)):hidden=\(view.isHidden),alpha=\(view.alpha),clips=\(view.clipsToBounds)")
          hidden = hidden || view.isHidden
          alpha *= Double(view.alpha)
          if view.clipsToBounds, let window {
            intersection = intersection.intersection(view.convert(view.bounds, to: window))
          }
          ancestor = view.superview
        }
        let truncated = ancestor != nil
        let visible = truncated ? "unknown" : Self.pipDiagnosticRect(hidden || alpha <= 0.01 ? .null : intersection)
        fields.append("ancestors=\(ancestors.joined(separator: ";")) ancestorsTruncated=\(truncated) clippedIntersection=\(Self.pipDiagnosticRect(intersection)) visibleIntersection=\(visible) visibility=geometryAndAncestorsOnly")
      }
    } else {
      fields.append("sourceLayer=nil sourceSnapshot=released")
    }
    return String(fields.joined(separator: " ").prefix(2800))
  }

  func recordAVPlayerPiPEvent(_ event: String, controller: AVPictureInPictureController,
                            error: Error? = nil, includeSource: Bool = false) {
    // Raw delegate entry preserves off-main evidence separately. Detailed AV
    // state is never queried off-main, including when no source was requested.
    guard Thread.isMainThread else { return }
    let key = ObjectIdentifier(controller)
    // Never access AVPlayer's playerLayer API on a sample-buffer/MK controller.
    // Historical addresses can be reused; establish live ownership first.
    let ownsRetiredAV = retiringPiP[key].map {
      $0.controller === controller && $0.renderer == nil
    } ?? false
    guard pip === controller || ownsRetiredAV else { return }
    let prepared = pip === controller && avPlayerPiPRequest == nil
      && !avPlayerPiPOwnsPresentation && pendingReplacement == nil
    let trace = prepared ? nil : avPlayerPiPTraceRequests.last(where: { $0.controller == key })
    let requestTrace = trace.map { "request=\($0.request) requestGeneration=\($0.generation)" }
      ?? "request=none requestGeneration=\(generation)"
    let layer = controller.playerLayer
    let phase: String
    if retiringPiP[key] != nil { phase = "retiring" }
    else if pendingReplacement?.controller === controller { phase = "replacing" }
    else if pip !== controller { phase = "released" }
    else if prepared { phase = "prepared" }
    else if avPlayerPiPRequest?.deadline == nil { phase = "activeAccepted" }
    else { phase = pipStartIssued ? "starting" : "preparing" }
    let itemStatus = layer.player?.currentItem?.status.rawValue ?? -1
    let transport = layer.player?.timeControlStatus.rawValue ?? -1
    let sourceWindow = surface?.videoLayer === layer && surface?.window != nil
    var detail = "AVPiP \(event) main=\(Thread.isMainThread) \(requestTrace) controller=\(key) phase=\(phase) possible=\(controller.isPictureInPicturePossible) active=\(controller.isPictureInPictureActive) suspended=\(controller.isPictureInPictureSuspended) firstFrameReady=\(layer.isReadyForDisplay) itemStatus=\(itemStatus) rate=\(layer.player?.rate ?? 0) transport=\(transport) sourceWindow=\(sourceWindow) layerBounds=\(layer.bounds) audioActivatedByApp=\(audioSessionActivated) interrupted=\(interrupted)"
    if let error {
      var current: NSError? = error as NSError
      var chain: [String] = []
      while let failure = current, chain.count < 3 {
        chain.append("\(String(failure.domain.prefix(80)))(\(failure.code))")
        current = failure.userInfo[NSUnderlyingErrorKey] as? NSError
      }
      detail += " error=" + chain.joined(separator: " <- ")
    }
    if includeSource { detail += " " + avPlayerPiPSourceSnapshot(layer: layer) }
    recordLifecycle(detail)
  }

  private func acceptPiPPlaybackSession(_ controller: AVPictureInPictureController) {
    guard pendingReplacement == nil,
          pip === controller || mediaKitPiP?.controller === controller else { return }
    // Duplicate didStart must not unfreeze a stop or a pending UI restoration.
    if pipPlaybackSession?.controller == ObjectIdentifier(controller),
       pipPlaybackSession?.generation == generation { return }
    clearPiPTransportObservation()
    let sessionID = UUID()
    pipPlaybackSession = (sessionID, ObjectIdentifier(controller), generation, nil, false, false)
    if pip === controller {
      observePiPTransport(controller, sessionID: sessionID)
      if let item = player.currentItem {
        mirrorPiPTransport(player, item: item, controllerID: ObjectIdentifier(controller),
          sessionID: sessionID, generation: generation)
      }
    }
  }

  func didStartMediaKitPiP(_ controller: AVPictureInPictureController) {
    guard mediaKitPiP?.controller === controller, manualPiPSession == generation else { return }
    acceptPiPPlaybackSession(controller)
    publish()
  }

  private func clearPiPPlaybackSession(_ controller: AVPictureInPictureController) {
    if pipPlaybackSession?.controller == ObjectIdentifier(controller) {
      pipPlaybackSession = nil
      clearPiPTransportObservation()
    }
  }

  func willStopPiP(_ controller: AVPictureInPictureController) {
    guard pipPlaybackSession?.controller == ObjectIdentifier(controller),
          pipPlaybackSession?.generation == generation else { return }
    pipPlaybackSession?.stopping = true
    recordLifecycle("PiP willStop; AVKit retains native transport ownership")
  }

  func beginPiPRestore(_ controller: AVPictureInPictureController, token: UUID) -> Bool {
    guard allowsPiPRestore(controller) else { return false }
    if pipPlaybackSession?.controller == ObjectIdentifier(controller),
       pipPlaybackSession?.generation == generation {
      pipPlaybackSession?.restoreToken = token
      recordLifecycle("PiP restore requested token=\(token)")
    }
    return true
  }

  func completePiPRestore(_ controller: AVPictureInPictureController, token: UUID, restored: Bool) {
    guard pipPlaybackSession?.controller == ObjectIdentifier(controller),
          pipPlaybackSession?.generation == generation,
          pipPlaybackSession?.restoreToken == token else { return }
    if !restored {
      pipPlaybackSession?.restoreToken = nil
      if controller.isPictureInPictureActive { pipPlaybackSession?.stopping = false }
    }
    recordLifecycle("PiP restore completed success=\(restored) token=\(token)")
  }

  private func endInlinePiPTransportFollow() {
    guard pipPlaybackSession?.inline == true else { return }
    pipPlaybackSession = nil
    clearPiPTransportObservation()
  }

  private func clearPiPTransportObservation() {
    if let observation = pipTransportObservation { NotificationCenter.default.removeObserver(observation) }
    pipTransportObservation = nil
  }

  private func observePiPTransport(_ controller: AVPictureInPictureController, sessionID: UUID) {
    let observed = player
    let item = player.currentItem
    let token = generation
    let controllerID = ObjectIdentifier(controller)
    pipTransportObservation = NotificationCenter.default.addObserver(
      forName: AVPlayer.rateDidChangeNotification, object: observed, queue: .main) {
      [weak self, weak observed, weak item] note in
      guard let self, let observed, let item else { return }
      let value = note.userInfo?[AVPlayer.rateDidChangeReasonKey]
      let reason = (value as? AVPlayer.RateDidChangeReason)
        ?? (value as? String).map { AVPlayer.RateDidChangeReason(rawValue: $0) }
      guard reason == .setRateCalled else { return }
      self.mirrorPiPTransport(observed, item: item, controllerID: controllerID,
        sessionID: sessionID, generation: token)
    }
  }

  private func finishPiPPlaybackSession(_ controller: AVPictureInPictureController,
                                       terminal: AVPlayerPiPTerminal) {
    guard let session = pipPlaybackSession,
          session.controller == ObjectIdentifier(controller),
          session.generation == generation else { return }
    if terminal == .didStop, session.restoreToken != nil, pip === controller {
      // AVKit restores the same player's transport. Keep a passive, item-scoped
      // mirror until the app next takes control; do not retain the controller.
      pipPlaybackSession?.inline = true
      if let item = player.currentItem {
        mirrorPiPTransport(player, item: item, controllerID: session.controller,
          sessionID: session.id, generation: session.generation)
      }
    } else {
      pipPlaybackSession = nil
      clearPiPTransportObservation()
    }
    // Product policy: ending an accepted current PiP without a UI restore
    // request pauses. This is not an assertion that AVKit exposes an X event.
    // Failed starts, replacement and retired controllers use their own paths.
    if terminal == .didStop && session.restoreToken == nil {
      recordLifecycle("PiP closed without UI restoration; pause current media")
      pause()
    }
  }

  private func mirrorPiPTransport(_ observed: AVPlayer, item: AVPlayerItem,
                                       controllerID: ObjectIdentifier,
                                       sessionID: UUID, generation token: Int) {
    guard observed === player, item === player.currentItem,
          token == generation,
          avPlayerTransportMutationDepth == 0,
          let session = pipPlaybackSession, session.id == sessionID,
          session.controller == controllerID, session.generation == generation,
          session.inline || pip.map({ ObjectIdentifier($0) }) == controllerID,
          mediaKit == nil, pendingReplacement == nil, deferredPresentationLoad == nil,
          hasValidAVPlayerPresentationItem, timelineReady, !loading, !isSeeking, !scrubbing,
          !interrupted, !audioRecoveryPending, !controlBusy, trackSelection == nil,
          replayOperation == nil, !atPlaybackEnd,
          !PlaybackEndGate.isAtEnd(position, duration: duration) else { return }
    // Mirror actual requested transport, never infer a user action or feed a
    // temporary AVKit transition back into play()/pause(). Waiting keeps its
    // requested rate. A queued notification samples the latest native state.
    let playing = observed.rate != 0
    guard wantsPlayback != playing else { return }
    wantsPlayback = playing
    recordLifecycle("PiP transport mirrored playing=\(playing) inline=\(session.inline)")
    persist(); publish()
  }

  func finishAVPlayerPiP(_ controller: AVPictureInPictureController,
                         terminal: AVPlayerPiPTerminal = .didStop) {
    guard pip === controller else { return }
    if finishPendingReplacement(controller, avTerminal: terminal) { return }
    let restoringNativeTransport = terminal == .didStop
      && pipPlaybackSession?.controller == ObjectIdentifier(controller)
      && pipPlaybackSession?.generation == generation
      && pipPlaybackSession?.restoreToken != nil
    finishPiPPlaybackSession(controller, terminal: terminal)
    // This callback proves the old controller is terminal. Release it before
    // foreground reconciliation may create a new, unauthorized idle preparation.
    cancelPendingAVPlayerPiP()
    pip = nil
    controller.delegate = nil
    observedPiPStarts.remove(ObjectIdentifier(controller))
    revokeManualPiP()
    recordLifecycle("AV PiP terminal consumed result=\(terminal.rawValue)")
    reconcileAVPlayerPresentation(reason: "AV PiP terminal: \(terminal.rawValue)")
    // Apple's normal restore flow owns the existing player's actual transport.
    // Explicit recovery remains only for failed/unaccepted internal transitions.
    if !restoringNativeTransport { resumeHealthyPlaybackAfterPiPStop() }
    publish()
  }

  func didStartAVPlayerPiP(_ controller: AVPictureInPictureController) {
    guard pip === controller else { return }
    observedPiPStarts.insert(ObjectIdentifier(controller))
    guard avPlayerPiPAuthorized, let requestID = avPlayerPiPRequest?.id,
          matchesAVPlayerPiPRequest(controller, requestID: requestID) else {
      _ = rejectUnauthorizedAVPlayerPiPStart(controller)
      return
    }
    avPlayerPiPRequest?.deadline = nil
    acceptPiPPlaybackSession(controller)
    recordAVPlayerPiPEvent("active accepted", controller: controller)
    pipPossibleObservation?.invalidate(); pipPossibleObservation = nil
    pipActivationTimeout?.cancel()
    pipActivationTimeout = nil
    publish()
  }

  func rejectUnauthorizedAVPlayerPiPStart(_ controller: AVPictureInPictureController) -> Bool {
    guard pip === controller else { return false }
    observedPiPStarts.insert(ObjectIdentifier(controller))
    if avPlayerPiPAuthorized, let requestID = avPlayerPiPRequest?.id,
       matchesAVPlayerPiPRequest(controller, requestID: requestID) {
      // Keep the observed-start guard for synchronous/reentrant AVKit callbacks.
      // Only the current explicit request can authorize this presentation;
      // readiness KVO itself never issues a start.
      let wasPreparing = pipPossibleObservation != nil
      pipPossibleObservation?.invalidate(); pipPossibleObservation = nil
      if wasPreparing && !pipStartIssued {
        authorizeManualPiP(seconds: 8)
        armAVPlayerPiPTimeout(controller, requestID: requestID, seconds: 8)
      }
      return false
    }
    recordLifecycle("unauthorized PiP start rejected controller=\(ObjectIdentifier(controller))")
    revokeManualPiP()
    if pendingReplacement?.controller === controller {
      // The replacement already owns the stop fence; do not steal its callback.
      controller.stopPictureInPicture()
    } else {
      // observedPiPStarts makes this explicit retirement even during willStart,
      // when AVKit still reports isPictureInPictureActive=false.
      discardAVPlayerPiP()
    }
    publish()
    return true
  }

  private func cancelPendingAVPlayerPiP() {
    avPlayerPiPRequest = nil
    pipPossibleObservation?.invalidate(); pipPossibleObservation = nil
    pipActivationTimeout?.cancel()
    pipActivationTimeout = nil
    pipStartIssued = false
  }

  func startMediaKitPiP(handle: Int64, requestID: String, sourceView: UIView,
                        delegate: AVPictureInPictureControllerDelegate,
                        completion: @escaping (Bool) -> Void) {
    guard mediaKit != nil, mediaKitPiPPreparing, mediaKitPiPRequestID == requestID,
          mediaKitPiP == nil, !mediaKitPiPRestoring else {
      completion(false)
      return
    }
    attemptMediaKitPiP(handle: handle, requestID: requestID, sourceView: sourceView,
                       delegate: delegate, deadline: .now() + 8, completion: completion)
  }

  private func attemptMediaKitPiP(handle: Int64, requestID: String, sourceView: UIView,
                                  delegate: AVPictureInPictureControllerDelegate,
                                  deadline: DispatchTime, completion: @escaping (Bool) -> Void) {
    guard mediaKit != nil, mediaKitPiPPreparing, mediaKitPiPRequestID == requestID,
          mediaKitPiP == nil, !mediaKitPiPRestoring else {
      completion(false)
      return
    }
    guard sourceView.window != nil else {
      mediaKitPiPPreparationTimeout?.cancel()
      mediaKitPiPPreparationTimeout = nil
      mediaKitPiPPreparing = false
      mediaKitPiPRequestID = nil
      revokeManualPiP()
      recordPiPFailure("source page closed")
      publish()
      completion(false)
      return
    }
    do {
      let renderer = try MediaKitPiPRenderer(playerHandle: handle, sourceView: sourceView,
                                             delegate: delegate)
      mediaKitPiPPreparationTimeout?.cancel()
      mediaKitPiPPreparationTimeout = nil
      mediaKitPiPPreparing = false
      mediaKitPiPRequestID = nil
      let rendererGeneration = generation
      renderer.playRequested = { [weak self, weak renderer] in
        guard let self, let renderer, self.generation == rendererGeneration,
              self.mediaKitPiP === renderer else { return }
        self.play()
      }
      renderer.diagnostic = { [weak engine = mediaKit] message in engine?.recordDiagnostic(message) }
      renderer.pauseRequested = { [weak self, weak renderer] in
        guard let self, let renderer, self.generation == rendererGeneration,
              self.mediaKitPiP === renderer else { return }
        self.pause()
      }
      renderer.startTimedOut = { [weak self, weak renderer] in
        guard let self = self, let renderer = renderer, self.mediaKitPiP === renderer else { return }
        self.stopMediaKitPiPAndRestoreVideoOutput()
      }
      let seekGeneration = generation
      renderer.seekRequested = { [weak self, weak renderer, weak engine = mediaKit] seconds, completion in
        guard let self, let renderer, let engine,
          self.generation == seekGeneration, self.mediaKit === engine,
          self.mediaKitPiP === renderer else { completion(false); return }
        self.seek(seconds) { [weak self, weak renderer, weak engine] finished in
          guard let self, let renderer, let engine,
            self.generation == seekGeneration, self.mediaKit === engine,
            self.mediaKitPiP === renderer else { completion(false); return }
          completion(finished)
        }
      }
      renderer.positionProvider = { [weak self] in self?.position ?? 0 }
      renderer.durationProvider = { [weak self] in self?.duration ?? 0 }
      renderer.playingProvider = { [weak self] in
        guard let self else { return false }
        return self.enginePlaying && !self.isSeeking
      }
      renderer.rateProvider = { [weak self] in Double(self?.rate ?? 1) }
      mediaKitPiP = renderer
      mediaKitPiPActiveRequestID = requestID
      renderer.start()
      publish()
      completion(true)
    } catch {
      if DispatchTime.now() < deadline {
        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(100)) { [weak self, weak sourceView] in
          guard let self = self, let sourceView = sourceView else { completion(false); return }
          self.attemptMediaKitPiP(handle: handle, requestID: requestID, sourceView: sourceView,
                                  delegate: delegate, deadline: deadline, completion: completion)
        }
        return
      }
      mediaKitPiPPreparationTimeout?.cancel()
      mediaKitPiPPreparationTimeout = nil
      mediaKitPiPPreparing = false
      mediaKitPiPRequestID = nil
      revokeManualPiP()
      recordPiPFailure("media_kit output takeover failed")
      publish()
      completion(false)
    }
  }

  func finishMediaKitPiP(_ controller: AVPictureInPictureController,
                         terminal: AVPlayerPiPTerminal = .didStop) {
    if finishPendingReplacement(controller) { return }
    guard let renderer = mediaKitPiP, renderer.controller === controller else { return }
    finishPiPPlaybackSession(controller, terminal: terminal)
    revokeManualPiP()
    mediaKitPiP = nil
    mediaKitPiPActiveRequestID = nil
    observedPiPStarts.remove(ObjectIdentifier(controller))
    renderer.stop()
    restoreMediaKitVideoOutput()
  }

  /// Abort only the renderer created for this exact engine/request pair. This
  /// is used when Flutter handed rendering to native PiP successfully but then
  /// failed to rebuild its inline video track.
  func abortMediaKitPiP(engineID: String, requestID: String,
                        completion: @escaping (Bool) -> Void) {
    guard mediaKit?.id == engineID else { completion(false); return }
    if mediaKitPiPPreparing,
       Self.matchesPiPAbort(engineID: engineID, requestID: requestID,
         currentEngineID: mediaKit?.id, currentRequestID: mediaKitPiPRequestID),
       mediaKitPiP == nil {
      mediaKitPiPPreparationTimeout?.cancel()
      mediaKitPiPPreparationTimeout = nil
      mediaKitPiPPreparing = false
      mediaKitPiPRequestID = nil
      revokeManualPiP()
      publish()
      completion(true)
      return
    }
    guard let renderer = mediaKitPiP,
          Self.matchesPiPAbort(engineID: engineID, requestID: requestID,
            currentEngineID: mediaKit?.id, currentRequestID: mediaKitPiPActiveRequestID),
          !mediaKitPiPRestoring else { completion(false); return }
    let controller = renderer.controller
    let key = ObjectIdentifier(controller)
    let waitForDidStop = AVPlayerPresentationPolicy.requiresTerminal(
      startIssued: renderer.startIssued, startObserved: observedPiPStarts.contains(key),
      active: renderer.isActive)
    if waitForDidStop {
      let abortToken = UUID()
      retiringPiPAbortCompletions[key] = (abortToken, completion)
      // Return false before Flutter's own 2 s deadline if UIKit never confirms
      // that the visible PiP window stopped. Flutter will then full-release.
      DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
        guard let self = self,
          self.retiringPiPAbortCompletions[key]?.token == abortToken else { return }
        self.retiringPiPAbortCompletions.removeValue(forKey: key)?.completion(false)
      }
    }
    mediaKitPiPActiveRequestID = nil
    revokeManualPiP()
    mediaKitPiP = nil
    retirePiP(controller, renderer: renderer)
    publish()
    if !waitForDidStop { completion(true) }
  }

  func allowsPiPRestore(_ controller: AVPictureInPictureController) -> Bool {
    pendingReplacement == nil && (pip === controller || mediaKitPiP?.controller === controller)
  }

  func ownsMediaKitPiP(_ controller: AVPictureInPictureController) -> Bool {
    mediaKitPiP?.controller === controller
  }

  private func stopMediaKitPiPAndRestoreVideoOutput() {
    // A timed-out start may still be in AVKit. Never rebuild inline output
    // until its stop is confirmed; a never-issued renderer can release now.
    if let renderer = mediaKitPiP, let engine = mediaKit {
      retiringPiPRestores[ObjectIdentifier(renderer.controller)] = (engine, generation)
      // The renderer is releasing its mpv output. Keep the desired user intent,
      // but do not play audio against missing video while AVKit still owns it.
      pauseEngine()
      revokeManualPiP()
      discardMediaKitPiP()
    } else {
      discardMediaKitPiP()
      restoreMediaKitVideoOutput()
    }
  }

  private func restoreMediaKitVideoOutput() {
    guard !mediaKitPiPRestoring else { return }
    guard let mediaKit = mediaKit else { mediaKitPiPRestoring = false; publish(); return }
    let token = generation
    pauseEngine()
    mediaKitPiPRestoring = true
    mediaKitPiPRestoreTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self, weak mediaKit] in
      guard let self = self, let mediaKit = mediaKit, self.mediaKit === mediaKit,
            self.generation == token, self.mediaKitPiPRestoring else { return }
      self.mediaKitPiPRestoreTimeout = nil
      self.recoverMediaKitVideoOutput()
    }
    mediaKitPiPRestoreTimeout = timeout
    DispatchQueue.main.asyncAfter(deadline: .now() + 24, execute: timeout)
    publish()
    mediaKit.restoreVideoOutput { [weak self, weak mediaKit] success in
      DispatchQueue.main.async {
        guard let self = self, let mediaKit = mediaKit, self.mediaKit === mediaKit,
              self.generation == token, self.mediaKitPiPRestoring else { return }
        self.mediaKitPiPRestoreTimeout?.cancel()
        self.mediaKitPiPRestoreTimeout = nil
        self.mediaKitPiPRestoring = false
        if success {
          self.resumeHealthyPlaybackAfterPiPStop()
          self.publish()
        } else {
          self.recoverMediaKitVideoOutput()
        }
      }
    }
  }

  private func recoverMediaKitVideoOutput() {
    mediaKitPiPRestoreTimeout?.cancel()
    mediaKitPiPRestoreTimeout = nil
    mediaKitPiPRestoring = false
    guard currentPath != nil else { publish(); return }
    // An already accepted recovery owns its one reload. A late timeout/error
    // must not replace that transaction or spend another output-recovery try.
    guard currentSessionPositionRestore == nil else { return }
    captureRememberedProgress()
    guard let engine = mediaKit, let path = currentPath,
          let checkpoint = currentSessionCheckpoint,
          checkpoint.sessionID == currentSessionID, checkpoint.path == path,
          checkpoint.generation == generation, checkpoint.engineID == engine.id,
          pendingReplacement == nil, deferredPresentationLoad == nil,
          pip == nil, mediaKitPiP == nil, !mediaKitPiPPreparing,
          !blockingRetiringPiP else {
      fail("media_playback_failed")
      lastDiagnostic = "inline output recovery has no safe current-session position"
      publish()
      return
    }
    let shouldResume = wantsPlayback
    persist()
    currentSessionPositionRestore = CurrentSessionPositionRestore(id: UUID(),
      checkpoint: checkpoint, sourceEngineID: engine.id, targetGeneration: generation + 1)
    // This is a same-selection MK output rebuild, never a historical reopen.
    // The guards above make load immediate; it cannot enter a stop/defer fence.
    load(resume: false, autoplay: shouldResume)
  }

  private func resetCurrentSessionCheckpoint() {
    currentSessionID = UUID()
    currentSessionCheckpoint = nil
    currentSessionPositionRestore = nil
  }

  /// Returns true when an explicit internal restore consumes the ready event.
  /// No checkpoint/intent is applied to an ordinary open, even of the same path.
  private func restoreCurrentSessionPositionIfNeeded(engine: LeeMediaKitEngine,
                                                    generation token: Int) -> Bool {
    guard let restore = currentSessionPositionRestore else { return false }
    guard generation == token, mediaKit === engine else { return true }
    guard restore.targetGeneration == token, restore.targetEngineID == engine.id,
          restore.checkpoint.sessionID == currentSessionID,
          let path = currentPath, restore.checkpoint.path == path else {
      currentSessionPositionRestore = nil
      fail("media_playback_failed")
      lastDiagnostic = "inline output recovery identity no longer matches"
      publish()
      return true
    }
    guard !restore.seekIssued else { return true }
    guard engine.seekable,
          let target = restore.checkpoint.position(sessionID: currentSessionID,
            path: path, origin: timelineOrigin, duration: duration) else {
      currentSessionPositionRestore = nil
      fail("media_playback_failed")
      lastDiagnostic = "inline output recovery cannot restore the confirmed position"
      publish()
      return true
    }
    currentSessionPositionRestore?.seekIssued = true
    initialHistoricalSeekPending = false
    loading = false
    let operation = playbackOperation
    enqueueSeek(target, precise: true) { [weak self, weak engine] finished in
      DispatchQueue.main.async {
        guard let self, let engine, self.mediaKit === engine,
              self.generation == token, self.playbackOperation == operation,
              self.currentSessionPositionRestore?.id == restore.id,
              self.currentSessionPositionRestore?.targetEngineID == engine.id,
              self.currentSessionID == restore.checkpoint.sessionID,
              self.currentPath == path else { return }
        self.currentSessionPositionRestore = nil
        guard finished else {
          self.fail("media_playback_failed")
          self.lastDiagnostic = "inline output position restoration failed"
          self.publish()
          return
        }
        self.initialPositionEstablished = true
        self.sessionCompleted = false; self.atPlaybackEnd = false; self.pendingEndAction = false
        self.endGate.settled(operation: operation, rawTarget: target,
          position: self.position, duration: self.duration)
        // Playback intent is always live. The checkpoint contains no autoplay,
        // background, interruption or pause state to replay over newer input.
        if self.wantsPlayback { self.attemptAudioRecovery() }
        self.persist(); self.publish()
      }
    }
    return true
  }

  private func discardMediaKitPiP() {
    mediaKitPiPPreparationTimeout?.cancel()
    mediaKitPiPPreparationTimeout = nil
    mediaKitPiPRestoreTimeout?.cancel()
    mediaKitPiPRestoreTimeout = nil
    mediaKitPiPPreparing = false
    mediaKitPiPRequestID = nil
    mediaKitPiPActiveRequestID = nil
    let renderer = mediaKitPiP
    if let renderer { clearPiPPlaybackSession(renderer.controller) }
    mediaKitPiP = nil
    mediaKitPiPRestoring = false
    if let renderer = renderer { retirePiP(renderer.controller, renderer: renderer) }
  }

  private func clearBoundary() {
    if let observer = boundaryObserver { player.removeTimeObserver(observer); boundaryObserver = nil }
  }

  private func updateLoop() {
    clearBoundary()
    guard mediaKit == nil else { return } // media_kit commits through requestConfiguration.
    guard let a = aPoint, let b = bPoint else { return }
    let token = generation
    boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: b, preferredTimescale: 600))], queue: .main) { [weak self] in
      guard let self = self, self.generation == token, self.wantsPlayback, self.playbackEnvironmentAllowsPlayback, !self.interrupted, !self.scrubbing, !self.isSeeking else { return }
      self.seek(a)
    }
  }

  private func setupRemoteCommands() {
    let center = MPRemoteCommandCenter.shared()
    func bind(_ command: MPRemoteCommand, _ action: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
      command.isEnabled = true
      let target = command.addTarget { event in
        if Thread.isMainThread { return action(event) }
        return DispatchQueue.main.sync { action(event) }
      }
      remoteTargets.append((command, target))
    }
    bind(center.playCommand) { [weak self] _ in guard let self = self, self.currentPath != nil else { return .noSuchContent }; guard self.playbackEnvironmentAllowsPlayback else { return .commandFailed }; self.play(); return .success }
    bind(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
    bind(center.togglePlayPauseCommand) { [weak self] _ in guard let self = self else { return .commandFailed }; guard self.wantsPlayback || self.playbackEnvironmentAllowsPlayback else { return .commandFailed }; self.wantsPlayback ? self.pause() : self.play(); return .success }
    bind(center.nextTrackCommand) { [weak self] _ in self?.skip(1); return .success }
    bind(center.previousTrackCommand) { [weak self] _ in self?.skip(-1); return .success }
    center.skipForwardCommand.preferredIntervals = [NSNumber(value: forwardSeconds)]
    center.skipBackwardCommand.preferredIntervals = [NSNumber(value: rewindSeconds)]
    bind(center.skipForwardCommand) { [weak self] event in guard let self = self, let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }; self.seek(self.position + e.interval); return .success }
    bind(center.skipBackwardCommand) { [weak self] event in guard let self = self, let e = event as? MPSkipIntervalCommandEvent else { return .commandFailed }; self.seek(self.position - e.interval); return .success }
    bind(center.changePlaybackPositionCommand) { [weak self] event in guard let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }; self?.seek(e.positionTime); return .success }
  }

  private func updateNowPlaying() {
    guard let path = currentPath else { MPNowPlayingInfoCenter.default().nowPlayingInfo = nil; return }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = [
      MPMediaItemPropertyTitle: URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent,
      MPMediaItemPropertyAlbumTitle: URL(fileURLWithPath: path).deletingLastPathComponent().lastPathComponent,
      MPMediaItemPropertyPlaybackDuration: duration,
      MPNowPlayingInfoPropertyElapsedPlaybackTime: position,
      MPNowPlayingInfoPropertyPlaybackRate: wantsPlayback && playbackEnvironmentAllowsPlayback && enginePlaying ? rate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate]
  }

  private static func prefersMediaKit(_ url: URL) -> Bool {
    ["mkv", "flv", "avi", "webm", "ts", "m2ts", "mts", "mpeg", "mpg", "wmv", "vob",
     "ogg", "opus", "wma", "ape", "dts", "ac3", "eac3"].contains(url.pathExtension.lowercased())
  }
}

/// Removes only a shared leading absence of media, never encoded black frames.
/// Runs in a generation-scoped task; the source file is only referenced, never rewritten.
private enum PlaybackTimeline {
  static func prepare(url: URL) async throws -> (asset: AVAsset, origin: Double) {
    let source = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let tracks = try await source.load(.tracks)
    try Task.checkCancellation()
    let duration = try await source.load(.duration)
    try Task.checkCancellation()
    let relevant = tracks.filter {
      [.video, .audio, .subtitle, .text, .closedCaption].contains($0.mediaType)
    }
    guard !relevant.isEmpty, duration.seconds.isFinite else { return (source, 0) }
    var starts: [CMTime] = []
    for track in relevant {
      try Task.checkCancellation()
      // Segment targets are in the movie clock. Ignore explicit empty edits.
      let populated = track.segments.filter { !$0.isEmpty }
      guard let start = populated.map({ $0.timeMapping.target.start })
        .filter({ $0.seconds.isFinite }).min(by: { CMTimeCompare($0, $1) < 0 }) else {
        // Unknown timing must not remove possible content in another track.
        return (source, 0)
      }
      starts.append(start)
    }
    guard let origin = starts.min(by: { CMTimeCompare($0, $1) < 0 }),
      origin.seconds > 0.15, CMTimeCompare(origin, duration) < 0 else { return (source, 0) }
    let composition = AVMutableComposition()
    // Copy references with the original common clock first, then remove the shared gap.
    // This preserves delayed video/audio starts relative to one another.
    for track in tracks {
      try Task.checkCancellation()
      guard let target = composition.addMutableTrack(withMediaType: track.mediaType,
        preferredTrackID: track.trackID) else {
        throw LibraryFailure.app("timeline_adjustment_failed")
      }
      try target.insertTimeRange(track.timeRange, of: track, at: track.timeRange.start)
      target.preferredTransform = track.preferredTransform
      target.preferredVolume = track.preferredVolume
      target.languageCode = track.languageCode
      target.extendedLanguageTag = track.extendedLanguageTag
    }
    composition.removeTimeRange(CMTimeRange(start: .zero, duration: origin))
    return (composition, origin.seconds)
  }
}

final class PlayerSurface: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  private var replacementVideoLayer: AVPlayerLayer?
  var videoLayer: AVPlayerLayer { replacementVideoLayer ?? (layer as! AVPlayerLayer) }

  func isolateVideoLayer(_ retained: AVPlayerLayer) {
    guard videoLayer === retained else { return }
    let replacement = AVPlayerLayer()
    replacement.frame = bounds
    replacement.backgroundColor = UIColor.black.cgColor
    replacement.isOpaque = true
    replacement.videoGravity = retained.videoGravity
    // Keep AVKit's layer/player relationship intact. The independent opaque
    // layer covers the old image and remains below captions.
    layer.insertSublayer(replacement, below: caption.layer)
    replacementVideoLayer = replacement
  }

  func releaseIsolatedVideoLayer(_ retained: AVPlayerLayer) {
    if retained !== layer && retained !== videoLayer { retained.removeFromSuperlayer() }
  }

  let caption = UILabel()
  var onLayout: (() -> Void)?
  override func layoutSubviews() { super.layoutSubviews(); replacementVideoLayer?.frame = bounds; onLayout?() }
  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .black
    caption.textColor = .white; caption.font = .systemFont(ofSize: 19, weight: .medium)
    caption.numberOfLines = 0; caption.textAlignment = .center
    caption.backgroundColor = UIColor.black.withAlphaComponent(0.55)
    caption.isHidden = true; caption.translatesAutoresizingMaskIntoConstraints = false
    addSubview(caption)
    NSLayoutConstraint.activate([
      caption.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 16),
      caption.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -16),
      caption.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -12)])
  }
  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }
}


/// Decodes only a bounded opening range; uncertain media always keeps its intro.
private final class IntroScanJob {
  private let lock = NSLock()
  private var cancelled = false
  private var reader: AVAssetReader?
  let deadline = ProcessInfo.processInfo.systemUptime + 8
  func cancel() {
    lock.lock(); cancelled = true; let active = reader; lock.unlock()
    active?.cancelReading()
  }
  func check() throws {
    lock.lock(); let stopped = cancelled; lock.unlock()
    if stopped || ProcessInfo.processInfo.systemUptime >= deadline { throw IntroScanError.uncertain }
  }
  func attach(_ value: AVAssetReader) throws {
    lock.lock(); reader = value; let stopped = cancelled; lock.unlock()
    if stopped { value.cancelReading(); throw IntroScanError.uncertain }
    try check()
  }
}

private enum IntroScanError: Error { case uncertain }

private final class IntroScanner {
  private let work = DispatchQueue(label: "雷player.intro", qos: .utility)
  private var job: IntroScanJob?
  private let cacheURL: URL
  // Accessed exclusively on work.
  private var cache: [String: Double]?
  init(support: URL) { cacheURL = support.appendingPathComponent("intro-cache-v2.json") }
  func cancel() { job?.cancel(); job = nil }
  func detect(url: URL, asset: AVAsset, origin: Double, completion: @escaping (Double?) -> Void) {
    cancel()
    let task = IntroScanJob(); job = task
    // Main-thread gate also bounds the wait if a decoder is slow to return.
    var delivered = false
    func deliver(_ value: Double?) {
      guard !delivered else { return }
      delivered = true; completion(value)
    }
    DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
      task.cancel(); deliver(nil)
    }
    work.async {
      let result: Double?
      do {
        try task.check()
        let fingerprint = try self.fingerprint(url, origin: origin)
        if self.cache == nil {
          self.cache = (try? Data(contentsOf: self.cacheURL))
            .flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
        }
        if let saved = self.cache?[fingerprint], saved.isFinite, saved >= 0, saved < 60 {
          result = saved
        } else {
          let value = try self.scan(asset: asset, job: task)
          try task.check()
          guard try self.fingerprint(url, origin: origin) == fingerprint else { throw IntroScanError.uncertain }
          self.cache?[fingerprint] = value
          if let cache = self.cache, let data = try? JSONEncoder().encode(cache) {
            try? data.write(to: self.cacheURL, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
          }
          result = value
        }
      } catch { result = nil }
      DispatchQueue.main.async { deliver(result) }
    }
  }
  private func fingerprint(_ url: URL, origin: Double) throws -> String {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    guard let size = attributes[.size] as? NSNumber,
      let modified = attributes[.modificationDate] as? Date else { throw IntroScanError.uncertain }
    let identity = "v2|\(origin)|\(url.standardizedFileURL.resolvingSymlinksInPath().path)|\(size)|\(modified.timeIntervalSince1970)|\(attributes[.systemFileNumber] ?? "")"
    return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
  }
  private func scan(asset: AVAsset, job: IntroScanJob) throws -> Double {
    let videos = asset.tracks(withMediaType: .video)
    let audios = asset.tracks(withMediaType: .audio)
    // Do not skip possible subtitle-only content or ambiguous multi-video assets.
    guard videos.count == 1, audios.count <= 4,
      asset.tracks(withMediaType: .subtitle).isEmpty,
      asset.tracks(withMediaType: .text).isEmpty,
      asset.tracks(withMediaType: .closedCaption).isEmpty else { throw IntroScanError.uncertain }
    let duration = asset.duration.seconds
    guard duration.isFinite, duration > 3 else { return 0 }
    let limit = min(60, duration)
    let visual = try firstPicture(asset: asset, track: videos[0], limit: limit, job: job)
    if visual < 2 { return 0 }
    var boundary = visual
    for track in audios {
      boundary = min(boundary, try firstSound(asset: asset, track: track, limit: boundary, job: job))
      if boundary < 2 { return 0 }
    }
    guard boundary < limit else { throw IntroScanError.uncertain }
    // At least two seconds of confirmed blankness, with a half-second lead-in.
    return max(0, boundary - 0.5)
  }
  private func firstPicture(asset: AVAsset, track: AVAssetTrack, limit: Double, job: IntroScanJob) throws -> Double {
    let reader = try AVAssetReader(asset: asset)
    try job.attach(reader)
    defer { reader.cancelReading() }
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA])
    output.alwaysCopiesSampleData = false
    guard reader.canAdd(output) else { throw IntroScanError.uncertain }
    reader.add(output)
    guard reader.startReading() else { throw IntroScanError.uncertain }
    var previousEnd = 0.0
    while true {
      try job.check()
      let observation: (Double, Double, Bool)? = try autoreleasepool {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let sampleDuration = CMSampleBufferGetDuration(sample).seconds
        guard time.isFinite, time >= 0, time <= previousEnd + 0.15,
          sampleDuration.isFinite, sampleDuration > 0,
          let pixels = CMSampleBufferGetImageBuffer(sample) else { throw IntroScanError.uncertain }
        return (time, time + sampleDuration, try self.isBlack(pixels, job: job))
      }
      guard let (time, end, black) = observation else { break }
      if !black { return time }
      previousEnd = end
    }
    guard reader.status == .completed, previousEnd >= limit - 0.05 else { throw IntroScanError.uncertain }
    return limit
  }
  private func isBlack(_ pixels: CVPixelBuffer, job: IntroScanJob) throws -> Bool {
    guard CVPixelBufferGetPixelFormatType(pixels) == kCVPixelFormatType_32BGRA,
      CVPixelBufferLockBaseAddress(pixels, .readOnly) == kCVReturnSuccess else { throw IntroScanError.uncertain }
    defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }
    guard let base = CVPixelBufferGetBaseAddress(pixels) else { throw IntroScanError.uncertain }
    let width = CVPixelBufferGetWidth(pixels), height = CVPixelBufferGetHeight(pixels)
    let stride = CVPixelBufferGetBytesPerRow(pixels)
    guard width > 0, height > 0 else { throw IntroScanError.uncertain }
    // Inspect every pixel: even a small title/logo should keep the opening.
    for y in 0..<height {
      if y % 32 == 0 { try job.check() }
      let row = base.advanced(by: y * stride).assumingMemoryBound(to: UInt8.self)
      for x in 0..<width {
        let offset = x * 4
        if row[offset] > 12 || row[offset + 1] > 12 || row[offset + 2] > 12 { return false }
      }
    }
    return true
  }
  private func firstSound(asset: AVAsset, track: AVAssetTrack, limit: Double, job: IntroScanJob) throws -> Double {
    let reader = try AVAssetReader(asset: asset)
    try job.attach(reader)
    defer { reader.cancelReading() }
    reader.timeRange = CMTimeRange(start: .zero, duration: CMTime(seconds: limit, preferredTimescale: 600))
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
      AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 32,
      AVLinearPCMIsFloatKey: true, AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsNonInterleaved: false])
    guard reader.canAdd(output) else { throw IntroScanError.uncertain }
    reader.add(output)
    guard reader.startReading() else { throw IntroScanError.uncertain }
    var covered = 0.0
    while true {
      try job.check()
      let observation: (Double, Double, Bool)? = try autoreleasepool {
        guard let sample = output.copyNextSampleBuffer() else { return nil }
        let time = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let duration = CMSampleBufferGetDuration(sample).seconds
        guard time.isFinite, duration.isFinite, duration > 0,
          time <= covered + 0.05, time >= 0,
          let block = CMSampleBufferGetDataBuffer(sample) else { throw IntroScanError.uncertain }
        let bytes = CMBlockBufferGetDataLength(block)
        guard bytes > 0, bytes <= 8 * 1024 * 1024, bytes % MemoryLayout<Float>.size == 0 else { throw IntroScanError.uncertain }
        var values = [Float](repeating: 0, count: bytes / MemoryLayout<Float>.size)
        let status = values.withUnsafeMutableBytes {
          CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes, destination: $0.baseAddress!)
        }
        guard status == kCMBlockBufferNoErr else { throw IntroScanError.uncertain }
        var sound = false
        for value in values {
          guard value.isFinite else { throw IntroScanError.uncertain }
          if abs(value) > 0.001 { sound = true; break }
        }
        return (time, time + duration, sound)
      }
      guard let (time, end, sound) = observation else { break }
      if sound { return max(0, time) }
      covered = end
      if covered >= limit { return limit }
    }
    guard reader.status == .completed, covered >= limit - 0.05 else { throw IntroScanError.uncertain }
    return limit
  }
}
