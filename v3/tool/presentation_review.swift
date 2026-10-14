import Foundation
import Dispatch

// PRODUCTION_POLICY

// Plain deterministic collaborators, not subclasses or mocks of Apple SDK
// classes. Production method bodies are inserted unchanged by the runner.
enum ReviewStatus: Int { case unknown = 0, readyToPlay = 1, failed = 2 }
final class AVPlayerItem { var status = ReviewStatus.readyToPlay }
final class AVPlayer: NSObject {
  struct RateDidChangeReason: RawRepresentable, Equatable {
    var rawValue: String
    static let setRateCalled = Self(rawValue: "setRateCalled")
    static let appBackgrounded = Self(rawValue: "appBackgrounded")
    static let audioSessionInterrupted = Self(rawValue: "audioSessionInterrupted")
    static let setRateFailed = Self(rawValue: "setRateFailed")
  }
  static let rateDidChangeNotification = Notification.Name("review.playerRateDidChange")
  static let rateDidChangeReasonKey = "review.rateReason"
  enum TimeControlStatus: Int { case paused, waitingToPlayAtSpecifiedRate, playing }
  var timeControlStatus = TimeControlStatus.paused
  var currentItem: AVPlayerItem?
  var status = ReviewStatus.readyToPlay
  var isMuted = false
  var rate: Float = 1 { didSet { rateChanged?() } }
  var rateChanged: (() -> Void)?
  var volume: Float = 1
  var allowsExternalPlayback = false
  enum BackgroundPolicy { case continuesIfPossible }
  var audiovisualBackgroundPlaybackPolicy = BackgroundPolicy.continuesIfPossible
  var pauses = 0
  func pause() { pauses += 1; rate = 0 }
  func replaceCurrentItem(with item: AVPlayerItem?) { currentItem = item }
  func observe<T>(_ keyPath: KeyPath<AVPlayer, T>, options: ReviewObservationOptions,
                  change: @escaping (AVPlayer, Int) -> Void) -> NSKeyValueObservation {
    rateChanged = { [weak self] in if let self { change(self, 0) } }
    return NSKeyValueObservation { [weak self] in self?.rateChanged = nil }
  }
}
enum ReviewGravity { case resizeAspect, resizeAspectFill, resize }
class CALayer {
  var bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
  var frame = CGRect(x: 0, y: 0, width: 320, height: 180)
  var isHidden = false
  var opacity: Float = 1
  weak var superlayer: CALayer?
  func convert(_ rect: CGRect, to layer: CALayer?) -> CGRect { rect }
}
final class VideoLayer: CALayer {
  var isReadyForDisplay = true
  var player: AVPlayer?
  var videoRect = CGRect(x: 0, y: 0, width: 320, height: 180)
  var videoGravity = ReviewGravity.resizeAspect
}
class UIView {
  var layer: CALayer = CALayer()
  var bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
  var isHidden = false
  var alpha: CGFloat = 1
  var clipsToBounds = false
  var superview: UIView?
  var window: ReviewWindow?
  func convert(_ rect: CGRect, to view: UIView?) -> CGRect { rect }
}
final class ReviewScene {
  enum State: Int { case foregroundActive, foregroundInactive, background }
  var activationState = State.foregroundActive
}
final class ReviewWindow: UIView {
  var isKeyWindow = true
  var windowScene: ReviewScene? = ReviewScene()
}
final class ReviewCaption { var text: String?; var isHidden = true }
final class PlayerSurface: UIView {
  var videoLayer = VideoLayer()
  var isolatedLayers: [VideoLayer] = []
  override init() {
    super.init(); layer = videoLayer; window = ReviewWindow()
  }
  func isolateVideoLayer(_ retained: VideoLayer) {
    guard videoLayer === retained else { return }
    isolatedLayers.append(retained); videoLayer = VideoLayer(); videoLayer.superlayer = layer
  }
  func releaseIsolatedVideoLayer(_ retained: VideoLayer) {
    isolatedLayers.removeAll { $0 === retained }
  }
  let caption = ReviewCaption()
  var onLayout: (() -> Void)?
}
// Read-only diagnostic collaborators. Geometry conversion is identity here;
// UIKit transforms, window composition and actual audio routes require iOS.
struct ReviewAudioValue { let rawValue: String }
struct ReviewAudioOptions { let rawValue: UInt }
struct ReviewPort { let portType: ReviewAudioValue; let portName = "PRIVATE_DEVICE_NAME" }
final class ReviewRoute {
  var inputs: [ReviewPort] = []
  var outputs = [ReviewPort(portType: ReviewAudioValue(rawValue: "Speaker"))]
}
final class AVAudioSession {
  static let shared = AVAudioSession()
  static func sharedInstance() -> AVAudioSession { shared }
  var category = ReviewAudioValue(rawValue: "AVAudioSessionCategoryPlayback")
  var mode = ReviewAudioValue(rawValue: "AVAudioSessionModeMoviePlayback")
  var categoryOptions = ReviewAudioOptions(rawValue: 0)
  let currentRoute = ReviewRoute()
}
final class UIApplication {
  enum State: Int { case active, inactive, background }
  static let shared = UIApplication()
  var applicationState = State.active
}
protocol AVPictureInPictureControllerDelegate: AnyObject {}
final class ReviewDelegate: AVPictureInPictureControllerDelegate {}
final class NSKeyValueObservation {
  var cancelled: (() -> Void)?
  init(_ cancelled: @escaping () -> Void = {}) { self.cancelled = cancelled }
  func invalidate() { cancelled?(); cancelled = nil }
  deinit { invalidate() }
}
struct ReviewObservationOptions: OptionSet {
  let rawValue: Int
  static let initial = Self(rawValue: 1)
  static let new = Self(rawValue: 2)
}
typealias AVPlayerLayer = VideoLayer
struct LibraryFailure: Error {
  let code: String
  static func app(_ code: String) -> Self { Self(code: code) }
}
final class AVPictureInPictureController {
  static var initialPossible = false
  static var onCreate: ((AVPictureInPictureController) -> Void)?
  // AVPictureInPictureController.playerLayer is non-optional in Apple's Swift
  // interface. Only ContentSource.playerLayer is optional.
  final class ContentSource {
    var playerLayer: VideoLayer?
    init(playerLayer: VideoLayer?) { self.playerLayer = playerLayer }
  }
  var contentSourceClearCount = 0
  var onContentSourceClear: (() -> Void)?
  var contentSource: ContentSource? {
    didSet {
      if contentSource == nil {
        contentSourceClearCount += 1
        onContentSourceClear?()
      }
    }
  }
  var playerLayerReads = 0
  var playerLayer: VideoLayer {
    playerLayerReads += 1
    guard let sourceLayer = contentSource?.playerLayer else {
      fatalError("Review forbids controller.playerLayer access after contentSource release")
    }
    return sourceLayer
  }
  var delegate: AVPictureInPictureControllerDelegate?
  var canStartPictureInPictureAutomaticallyFromInline = true
  private var active = false
  var activeReadSequence: [Bool] = []
  var isPictureInPictureActive: Bool {
    get { activeReadSequence.isEmpty ? active : activeReadSequence.removeFirst() }
    set { active = newValue }
  }
  var isPictureInPictureSuspended = false
  private var possible = false
  var possibleReadSequence: [Bool] = []
  var isPictureInPicturePossible: Bool {
    get { possibleReadSequence.isEmpty ? possible : possibleReadSequence.removeFirst() }
    set { possible = newValue; changed?() }
  }
  var changed: (() -> Void)?
  var starts = 0
  var onStart: (() -> Void)?
  var onStop: (() -> Void)?
  var stops = 0
  init?(playerLayer: VideoLayer) {
    self.contentSource = ContentSource(playerLayer: playerLayer)
    isPictureInPicturePossible = Self.initialPossible
    Self.onCreate?(self)
  }
  func startPictureInPicture() { starts += 1; onStart?() }
  static func isPictureInPictureSupported() -> Bool { true }
  func stopPictureInPicture() { stops += 1; onStop?() }
  func observe<T>(_ keyPath: KeyPath<AVPictureInPictureController, T>,
                  options: ReviewObservationOptions,
                  change: @escaping (AVPictureInPictureController, Int) -> Void) -> NSKeyValueObservation {
    changed = { [weak self] in if let self { change(self, 0) } }
    if options.contains(.initial) { changed?() }
    return NSKeyValueObservation { [weak self] in self?.changed = nil }
  }
}
final class MediaKitPiPRenderer {
  let controller: AVPictureInPictureController
  var startIssued = false
  var isActive: Bool { controller.isPictureInPictureActive }
  var stopping = false
  init(_ controller: AVPictureInPictureController) { self.controller = controller }
  func stop() { guard !stopping else { return }; stopping = true; controller.stopPictureInPicture() }
}
final class ReviewEngine {
  let id = UUID().uuidString
  var positionVersion = 0
  var playIntentVersion = 0
  var failure = ""
  var ready = true
  var seekable = true
  var restoreCalls = 0
  var outputRestoreCompletions: [(Bool) -> Void] = []
  var outputRestoreRequestIDs: [String] = []
  func restoreVideoOutput(requestID: String, completion: @escaping (Bool) -> Void) {
    restoreCalls += 1; outputRestoreRequestIDs.append(requestID); outputRestoreCompletions.append(completion)
  }
  var controls: [(String, (Bool) -> Void)] = []
  func recordDiagnostic(_ message: String) {}
  func control(_ method: String, arguments: [String: Any], completion: @escaping (Bool) -> Void) {
    controls.append((method, completion))
  }
  func startPiP(requestID: String, completion: @escaping (Bool) -> Void) {}
}
typealias LeeMediaKitEngine = ReviewEngine
struct ReviewLibrary {
  func url(_ path: String) throws -> URL { URL(fileURLWithPath: path) }
}
// Virtual scheduler includes cancellation and queued (not inline) KVO delivery.
// It controls our request state machine, not AVKit's platform behavior.
struct ProcessInfo {
  static let processInfo = Self()
  var systemUptime: Double { DispatchQueue.main.now }
}
struct DispatchTime {
  let time: Double
  static func now() -> Self { Self(time: DispatchQueue.main.now) }
  static func +(lhs: Self, rhs: Double) -> Self { Self(time: lhs.time + rhs) }
}
final class DispatchWorkItem {
  let work: () -> Void
  var cancelled = false
  init(block: @escaping () -> Void) { work = block }
  func cancel() { cancelled = true }
  func perform() { if !cancelled { work() } }
}
enum DispatchQueue {
  static let main = Queue()
  final class Queue {
    var now = 0.0
    var scheduled: [(time: Double, work: () -> Void)] = []
    func async(execute work: @escaping () -> Void) { scheduled.append((now, work)) }
    func asyncAfter(deadline: DispatchTime, execute work: @escaping () -> Void) {
      scheduled.append((deadline.time, work))
    }
    func asyncAfter(deadline: DispatchTime, execute work: DispatchWorkItem) {
      scheduled.append((deadline.time, { work.perform() }))
    }
    func advance(_ seconds: Double = 0) {
      let end = now + seconds
      while let next = scheduled.indices.min(by: { scheduled[$0].time < scheduled[$1].time }),
            scheduled[next].time <= end {
        let item = scheduled.remove(at: next); now = max(now, item.time); item.work()
      }
      now = end
    }
    func fireAll() { advance(60) }
  }
}

final class PresentationReviewHost {
  let library = ReviewLibrary()
  var replayStarts: [Double] = []
  var player = AVPlayer()
  var surface: PlayerSurface? = PlayerSurface()
  var pip: AVPictureInPictureController?
  let ownedDelegate = ReviewDelegate()
  weak var pipDelegate: AVPictureInPictureControllerDelegate?
  var pipPossibleObservation: NSKeyValueObservation?
  var pipActivationTimeout: DispatchWorkItem?
  var pipStartIssued = false
  var pipPlaybackSession: (id: UUID, controller: ObjectIdentifier, generation: Int,
    restoreToken: UUID?, stopping: Bool, inline: Bool)?
  var pipTransportObservation: NSObjectProtocol?
  var avPlayerTransportMutationDepth = 0
  var avPlayerPiPRequest: (id: UUID, generation: Int, item: AVPlayerItem, layer: AVPlayerLayer, deadline: Double?)?
  var avPlayerPiPTraceRequests: [(controller: ObjectIdentifier, request: UUID, generation: Int)] = []
  var avPlayerPiPAuthorized = false
  var installedAVPlayerItem: (item: AVPlayerItem, path: String, generation: Int)?
  var mediaKit: ReviewEngine?
  var mediaKitPiP: MediaKitPiPRenderer?
  var mediaKitPiPPreparing = false
  var mediaKitPiPRequestID: String?
  var mediaKitPiPActiveRequestID: String?
  var mediaKitPiPPreparationTimeout: DispatchWorkItem?
  var mediaKitPiPRestoring = false
  var mediaKitPiPRestoreRequestID: String?
  var deferredMediaKitVideoRestore: (engine: LeeMediaKitEngine, generation: Int, requestID: String?)?
  var mediaKitPiPRestoreTimeout: DispatchWorkItem?
  var retiringPiP: [ObjectIdentifier: (controller: AVPictureInPictureController,
    renderer: MediaKitPiPRenderer?, requiresTerminal: Bool)] = [:]
  var retiredAVPlayerOutputs: [ObjectIdentifier: (player: AVPlayer, item: AVPlayerItem?,
    layer: AVPlayerLayer, isolated: Bool, rateObservation: NSKeyValueObservation?)] = [:]
  var observedPiPStarts: Set<ObjectIdentifier> = []
  var unconfirmedPiPStops: Set<ObjectIdentifier> = []
  var retiringPiPRestores: [ObjectIdentifier: (engine: LeeMediaKitEngine, generation: Int)] = [:]
  var retiringPiPAbortCompletions: [ObjectIdentifier: (token: UUID, completion: (Bool) -> Void)] = [:]
  var pendingReplacement: (id: UUID, controller: AVPictureInPictureController,
    resume: Bool, autoplay: Bool, clearOnly: Bool)?
  var replacementTimeout: DispatchWorkItem?
  var deferredPresentationLoad: (resume: Bool, autoplay: Bool, clearOnly: Bool)?
  var observations: [NSKeyValueObservation] = []
  var playerObservations: [NSKeyValueObservation] = []
  var playerCreations = 1
  var mediaVolume: Float = 1
  var lastDiagnostic = ""
  var background = true
  var audioRecoveryPending = false
  var audioRecoveryExhausted = false
  var audioRecoveryRequiresAutoResume = false
  var rebuildPlayerAfterMediaServicesReset = false
  var audioSessionActivations = 0
  var audioSessionActivated = false
  var nativePlaybackTiming = NativePlaybackTiming()
  var resumeAfterInterruption = false
  var enginePlaying = false
  var detectingIntro = false
  var introToken = 0
  var pendingEndAction = false
  var replayOperation: Int?
  var atPlaybackEnd = false
  var sleepUntil: Date?
  var sleepTimer: Timer?
  var fit = "fit"
  var subtitleText = ""
  var currentPath: String? = "a.mp4"
  var generation = 1
  var decoderRecoveryRequest: (id: UUID, generation: Int)?
  var decoderRecoveryAttempted = false
  var inBackground = false
  var isSeeking = false
  var scrubbing = false
  var interrupted = false
  var controlBusy = false
  var trackSelection: String?
  var playbackOperation = 0
  var currentSessionID = UUID()
  var currentSessionCheckpoint: CurrentSessionCheckpoint?
  var currentSessionPositionRestore: CurrentSessionPositionRestore?
  var position = 0.0
  var duration = 120.0
  var timelineOrigin = 0.0
  var progressValid = true
  var rememberProgress = true
  var sessionCompleted = false
  var initialPositionEstablished = true
  var initialHistoricalSeekPending = false
  var lastValidRememberedProgress: [String: Any]?
  var endGate = PlaybackEndGate()
  var requestedSeeks: [Double] = []
  var seekCompletions: [(Bool) -> Void] = []
  var pipCreations = 0
  var seekFault = false
  var errorMessage = ""
  var wantsPlayback = true
  var timelineReady = true
  var loading = false
  var openingTimeout: DispatchWorkItem?
  var assetPreparationTask: Task<Void, Never>?
  var lifecycleEvents: [String] = []
  var publications = 0
  var loads = 0
  var loadedPaths: [String] = []
  var loadedAutoplay: [Bool] = []
  var clears = 0
  var restores: Int { mediaKit?.restoreCalls ?? 0 }
  var audioRecoveryCalls = 0
  var boundaryRemovalOwners: [ObjectIdentifier] = []
  var pauses = 0
  var mediaIsAudio = false
  var notices: [String] = []
  var notice: ((String) -> Void)?
  var manualPiPSession: Int?
  var manualPiPDeadline: Double?
  var busy: Bool { pipRequesting }
  var waiting: Bool { presentationWaiting }
  var presentationOwned: Bool { avPlayerPiPOwnsPresentation }
  var pipActive: Bool { mediaKitPiP?.isActive ?? (pip?.isPictureInPictureActive == true) }
  init() {
    pipDelegate = ownedDelegate; installIdentity()
    notice = { [weak self] in self?.notices.append($0) }
  }
  deinit {
    if let observation = pipTransportObservation { NotificationCenter.default.removeObserver(observation) }
  }
  func queuePiPTransport(reason: AVPlayer.RateDidChangeReason? = .setRateCalled) -> () -> Void {
    let owner = player; let item = player.currentItem!; let controllerID = ObjectIdentifier(pip!)
    let id = pipPlaybackSession!.id; let token = generation
    return { [weak self] in
      guard reason == .setRateCalled else { return }
      self?.mirrorPiPTransport(owner, item: item, controllerID: controllerID,
        sessionID: id, generation: token)
    }
  }
  func installIdentity() {
    let item = AVPlayerItem()
    player.currentItem = item
    installedAVPlayerItem = (item, currentPath!, generation)
  }
  func publish() { publications += 1 }
  func authorizeManualPiP(seconds: Double) {
    manualPiPSession = generation; manualPiPDeadline = DispatchQueue.main.now + seconds
  }
  func cancelAudioRecovery() {}
  func finishTrackSelection(_ message: String) {}
  func cancelSubtitleLoad() {}
  func cancelIntroDetection() {}
  func cancelSeeks() {}
  func pauseEngine() { endInlinePiPTransportFollow(); pauses += 1; player.pause(); enginePlaying = false }
  func clearBoundary() { boundaryRemovalOwners.append(ObjectIdentifier(player)) }
  func bindPlayerObservers() {}
  func activateAudioSession(reason: String = "playback") throws { audioSessionActivations += 1 }
  func restoreBrightness() {}
  func deactivateAudioSessionIfIdle() {}
  func updateNowPlaying() {}
  func finishStart(_ position: Double, token: Int, itemGeneration: Int) { replayStarts.append(position) }
  func prepareStart(url: URL, saved: Double) { replayStarts.append(saved) }
  func replayCurrent() { restartCurrentItem() }
  func resolveEndCandidate() {}
  func persist() {}
  func enqueueSeek(_ seconds: Double, precise: Bool, done: @escaping (Bool) -> Void) {
    requestedSeeks.append(seconds); seekCompletions.append(done)
  }
  func capturePosition() { captureRememberedProgress() }
  func recoverOutput() { recoverMediaKitVideoOutput() }
  func willContinueMKRecovery(path: String, token: Int) -> Bool {
    // PRODUCTION_MK_RECOVERY_ROUTE
  }
  func clearSessionPosition() { resetCurrentSessionCheckpoint() }
  @discardableResult func restorePositionReady(seekable: Bool = true) -> Bool {
    guard let engine = mediaKit else { return false }
    engine.seekable = seekable; timelineReady = true
    return restoreCurrentSessionPositionIfNeeded(engine: engine, generation: generation)
  }
  func attemptAudioRecovery(resetAttempts: Bool = false) {
    endInlinePiPTransportFollow()
    audioRecoveryCalls += 1
    player.rate = wantsPlayback && !interrupted && playbackEnvironmentAllowsPlayback ? 1 : 0
  }

  func performLoad(resume: Bool, autoplay: Bool) {
    discardAVPlayerPiP()
    discardMediaKitPiP()
    loads += 1; generation += 1
    loadedPaths.append(currentPath ?? ""); loadedAutoplay.append(autoplay)
    wantsPlayback = autoplay && playbackEnvironmentAllowsPlayback
    player.rate = wantsPlayback ? 1 : 0
    seekFault = false; errorMessage = ""; timelineReady = true; loading = false
    if currentSessionPositionRestore?.targetGeneration == generation {
      let engine = ReviewEngine(); mediaKit = engine
      currentSessionPositionRestore?.targetEngineID = engine.id
      position = 0; timelineOrigin = 0; timelineReady = false; loading = true
      progressValid = false; initialPositionEstablished = false
      player.rate = 0
    } else { currentSessionPositionRestore = nil }
    if currentPath != nil { installIdentity(); repair() }
  }
  func loadLatest(_ path: String, autoplay: Bool = true) {
    currentPath = path; load(resume: false, autoplay: autoplay)
  }
  func clearLatest() {
    currentPath = nil
    if let controller = pendingReplacement?.controller ?? (presentationOwned ? pip : nil) ?? mediaKitPiP?.controller {
      awaitPresentationStop(controller, resume: false, autoplay: false, clearOnly: true)
    } else {
      deferPresentationLoad(resume: false, autoplay: false, clearOnly: true)
    }
  }
  func enterBackground(enabled: Bool) {
    inBackground = true; background = enabled; enforcePlaybackEnvironment()
  }

  func clearPlaybackEnginesAfterMutation() {
    discardAVPlayerPiP()
    discardMediaKitPiP()
    clears += 1; installedAVPlayerItem = nil; player.currentItem = nil; mediaKit = nil; loading = false
  }
  func sourceSnapshot(_ layer: AVPlayerLayer?) -> String { avPlayerPiPSourceSnapshot(layer: layer) }
  func repair() { ensureAVPlayerPresentation(reason: "review") }
  func rebuildResetPlayer() { replaceFailedPlayerIfNeeded() }
  func initialAttach() { attachAVPlayerPresentationIfAllowed(reason: "initial load") }
  func discard() { discardAVPlayerPiP() }
  func discardRenderer() { discardMediaKitPiP() }
  func reconcile() { reconcileAVPlayerPresentation(reason: "review") }
  var available: Bool { pipAvailable }
  func prepare(ready: Bool = false) -> AVPictureInPictureController {
    AVPictureInPictureController.initialPossible = ready
    repair()
    let controller = pip!
    controller.isPictureInPicturePossible = ready
    return controller
  }
  func resign() { discardUnrequestedAVPlayerPiP() }
  func resignDuringOutputRestore() {
    let notification = { [weak self] in
      // PRODUCTION_MK_RESTORE_RESIGN
    }
    notification()
  }
  func request(ready: Bool = true) -> AVPictureInPictureController {
    let controller = prepare(ready: ready)
    try! startPiP(delegate: ownedDelegate)
    return controller
  }
  func failPlayback() { fail("media_playback_failed") }
  func cancel() { revokeManualPiP(); discardAVPlayerPiP() }
  func timeoutRenderer() { stopMediaKitPiPAndRestoreVideoOutput() }
  func terminal(_ controller: AVPictureInPictureController) {
    // The bridge uses this same routing order; the Python runner checks wiring.
    if finishRetiringPiP(controller, avTerminal: .didStop) { return }
    if pip === controller { finishAVPlayerPiP(controller) }
    else if mediaKitPiP?.controller === controller { finishMediaKitPiP(controller) }
  }
  func heartbeatPiPExpiry() {
    // PRODUCTION_AV_PIP_HEARTBEAT
    enforcePlaybackEnvironment()
  }
  // PRODUCTION_METHODS
}

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  assertions += 1
  if !condition() { fatalError(message) }
}
func fresh() -> PresentationReviewHost {
  DispatchQueue.main.scheduled = []; DispatchQueue.main.now = 0
  AVPictureInPictureController.initialPossible = false
  AVPictureInPictureController.onCreate = nil
  UIApplication.shared.applicationState = .active
  return PresentationReviewHost()
}

final class PiPBridgeReviewHost {
  let playback: PresentationReviewHost
  var pipRestoreCompletion: ((Bool) -> Void)?
  var pipRestoreToken: UUID?
  weak var pipRestoreController: AVPictureInPictureController?
  var events: [[String: Any]] = []
  var sink: (([String: Any]) -> Void)?
  init(_ service: PresentationReviewHost) {
    playback = service
    sink = { [weak self] in self?.events.append($0) }
  }
  func acknowledgeRestore(_ success: Bool) { completePiPRestore(success) }
  // PRODUCTION_BRIDGE_METHODS
}

// Exhaustive input matrices execute the actual production policy declaration.
for backgroundEnabled in [false, true] {
  let s=fresh(); s.repair(); let c=s.request(ready:true); DispatchQueue.main.advance()
  UIApplication.shared.applicationState = .background
  s.inBackground=true; s.background=backgroundEnabled
  DispatchQueue.main.now=8.01
  s.heartbeatPiPExpiry()
  check(s.pip === c && s.avPlayerPiPAuthorized && s.wantsPlayback && s.retiringPiP.isEmpty,
        "heartbeat cannot preempt the pending AV phase or its background permission")
  c.isPictureInPictureActive=true
  DispatchQueue.main.advance()
  check(s.pip === c && s.retiringPiP.isEmpty && s.avPlayerPiPRequest?.deadline == nil,
        "single phase watchdog accepts active-before-didStart after delayed heartbeat")
}
for terminal in [AVPlayerPiPTerminal.didStop, .failedToStart] {
  let s=fresh(); s.repair(); let c=s.request(ready:true); DispatchQueue.main.advance()
  s.discard(); c.isPictureInPictureActive=true
  check(s.finishRetiringPiP(c, avTerminal:terminal) && s.retiringPiP.isEmpty,
        "typed AV terminal wins over stale active snapshot")
  c.isPictureInPictureActive=false
  check(s.request().starts == 1, "AV entry is available after confirmed terminal")
}
do {
  let s=fresh(); s.repair(); let c=s.request(ready:true); DispatchQueue.main.advance()
  s.discard(); c.isPictureInPictureActive=true
  _=s.finishRetiringPiP(c)
  check(s.retiringPiP.count==1, "non-terminal cleanup cannot bypass active ownership")
  s.mediaKit=ReviewEngine()
  _=s.finishRetiringPiP(c,avTerminal:.didStop)
  var allowed=false
  do { try s.startPiP(delegate:s.ownedDelegate,requestID:"mk-next");allowed=true } catch {}
  check(allowed, "confirmed AV retirement unlocks the existing MK entry")
}

for bits in 0..<128 {
  func bit(_ index: Int) -> Bool { bits & (1 << index) != 0 }
  check(AVPlayerPresentationPolicy.permitsForegroundRepair(active: bit(0), validItem: bit(1),
    hasSurface: bit(2), replacing: bit(3), starting: bit(4), pipActive: bit(5), retiring: bit(6))
      == (bits == 7), "foreground repair matrix")
}
for bits in 0..<8 {
  let a = bits & 1 != 0, b = bits & 2 != 0, c = bits & 4 != 0
  check(AVPlayerPresentationPolicy.permitsAttachment(active: a, authorized: b, pipActive: c)
    == (bits != 0), "attachment preserves authorized/active handoff")
  check(AVPlayerPresentationPolicy.requiresTerminal(startIssued: a, startObserved: b, active: c)
    == (bits != 0), "retirement matrix")
}

// Foreground preparation does not request PiP, authorize background playback,
// or start when KVO changes. Resign removes only that idle registration.
do {
  let service = fresh(); let player = service.player; let item = player.currentItem
  service.repair(); service.repair(); let idle = service.pip!
  check(service.surface?.videoLayer.player === player && service.pipCreations == 1,
        "ordinary foreground repair prepares exactly one controller")
  check(!service.busy && !service.available && !service.avPlayerPiPAuthorized
        && service.manualPiPSession == nil && service.avPlayerPiPRequest == nil,
        "idle preparation is neither a request nor background permission")
  idle.isPictureInPicturePossible = true; DispatchQueue.main.advance()
  check(idle.starts == 0 && service.available && !service.busy,
        "KVO publishes readiness without ever issuing a start")
  service.resign()
  check(service.pip == nil && idle.delegate == nil && idle.changed == nil,
        "willResign releases idle controller and KVO before Home")
  for state in [UIApplication.State.inactive, .background] {
    UIApplication.shared.applicationState = state; service.reconcile()
    check(service.pip == nil && service.surface?.videoLayer.player === player && player.currentItem === item,
          "zero-click Home keeps healthy video graph and does not reprepare outside foreground")
  }
  UIApplication.shared.applicationState = .active; service.repair()
  check(service.pip !== idle && service.pipCreations == 2 && !service.busy,
        "return to foreground reprepares without a manual request")
  service.attachSurface(PlayerSurface())
  check(service.pipCreations == 3 && player.currentItem === item,
        "idle surface replacement prepares only for the new layer and preserves media")
}
do {
  let service = fresh(); service.installedAVPlayerItem = nil; service.player.currentItem = nil
  service.repair()
  check(service.surface?.videoLayer.player == nil, "ordinary repair requires valid item")
  service.initialAttach()
  check(service.surface?.videoLayer.player === service.player && service.pip == nil,
        "initial load may bind before async install without a controller")
  service.installIdentity(); service.repair()
  check(service.pip != nil && service.pipCreations == 1 && !service.busy,
        "item ready supplies idle preparation without authorization")
}
for invalid in 0..<6 {
  let service = fresh()
  switch invalid {
  case 0: service.generation += 1
  case 1: service.currentPath = "b.mp4"
  case 2: service.currentPath = nil
  case 3: service.player.currentItem = AVPlayerItem()
  case 4: service.seekFault = true
  default: service.errorMessage = "failed load"
  }
  service.repair()
  check(service.surface?.videoLayer.player == nil && service.pip == nil,
        "invalid current media/item cannot be revived")
  do { try service.startPiP(delegate: service.ownedDelegate); check(false, "invalid request rejected") }
  catch { check(service.pip == nil, "invalid explicit request creates no controller") }
}
do {
  let service = fresh(); let other = AVPlayer(); service.surface?.videoLayer.player = other
  UIApplication.shared.applicationState = .inactive
  service.initialAttach()
  check(service.surface?.videoLayer.player === other, "rejected attach is non-destructive")
  service.avPlayerPiPAuthorized = true; service.initialAttach()
  check(service.surface?.videoLayer.player === service.player, "authorized handoff allowed")
}
do {
  let service = fresh(); let controller = service.prepare()
  try! service.startPiP(delegate: service.ownedDelegate)
  DispatchQueue.main.advance(30)
  check(controller.starts == 0 && !service.busy && !service.avPlayerPiPAuthorized
        && service.avPlayerPiPRequest == nil && service.pipActivationTimeout == nil,
        "unready stale UI tap is quiet and creates neither a request nor an automatic future start")
  controller.isPictureInPicturePossible = true; DispatchQueue.main.advance()
  check(controller.starts == 0 && service.available, "readiness after an ignored tap still needs another explicit tap")
  try! service.startPiP(delegate: service.ownedDelegate)
  check(controller.starts == 1 && service.pipStartIssued && service.busy && service.pipCreations == 1,
        "ready button directly starts the already-prepared controller")
  do { try service.startPiP(delegate: service.ownedDelegate); check(false, "repeat must reject") }
  catch { check(controller.starts == 1 && service.pipCreations == 1, "repeat cannot duplicate controller or start") }
  controller.isPictureInPicturePossible = false; controller.isPictureInPicturePossible = true
  DispatchQueue.main.advance()
  check(controller.starts == 1, "repeat readiness cannot start twice")
  controller.isPictureInPictureActive = true; service.didStartAVPlayerPiP(controller)
  DispatchQueue.main.fireAll()
  check(service.pip === controller && service.notices.isEmpty, "successful activation cancels watchdog")
  service.repair(); check(service.pip === controller && service.pipCreations == 1,
        "active PiP return never builds a replacement")
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(service.pip !== controller && service.pip != nil && !service.busy && service.pipCreations == 2,
        "terminal restores a fresh idle preparation in foreground without starting")
}
for state in [UIApplication.State.inactive, .background] {
  let service = fresh(); let controller = service.request()
  service.resign(); UIApplication.shared.applicationState = state
  service.reconcile(); DispatchQueue.main.advance()
  check(controller.starts == 1 && service.pip === controller && service.avPlayerPiPAuthorized,
        "tap then immediate Home/inactive retains the authorized controller")
  check(service.surface?.videoLayer.player === service.player,
        "manual handoff keeps source attached")
  check(BackgroundPlaybackPolicy.permitsPlayback(backgroundEnabled: false, inBackground: true,
    session: service.generation, pipSession: service.manualPiPSession, pipActive: false,
    pipDeadline: service.manualPiPDeadline, now: DispatchQueue.main.now),
    "manual request allows bounded background startup when preference is off")
}
for mutation in 0..<3 {
  let service = fresh(); let old = service.prepare()
  let staleDelivery = old.changed!
  old.isPictureInPicturePossible = true // queue readiness before cancellation
  switch mutation {
  case 0: service.resign(); UIApplication.shared.applicationState = .background
  case 1: service.loadLatest("b.mp4")
  default: service.attachSurface(PlayerSurface())
  }
  staleDelivery(); DispatchQueue.main.advance()
  check(old.starts == 0 && old.delegate == nil && !service.busy
        && service.avPlayerPiPRequest == nil && !service.avPlayerPiPAuthorized,
        "stale idle readiness after Home/file/surface replacement cannot start or authorize")
  check(service.retiringPiP.isEmpty, "unissued cancellation never waits for impossible didStop")
}
do {
  let service = fresh(); let old = service.prepare()
  _ = service.rejectRetiringPiPStart(old)
  service.resign()
  check(service.pip === old && service.presentationOwned,
        "observed-only controller is not treated as idle during resign")
  check(service.rejectUnauthorizedAVPlayerPiPStart(old), "unsolicited observed start is rejected")
  check(service.retiringPiP.count == 1 && service.surface?.videoLayer.player === service.player,
        "unsolicited start uses existing terminal-safe retirement without video detachment")
  service.terminal(old)
  check(service.retiringPiP.isEmpty && service.pip !== old, "unsolicited terminal safely allows idle preparation")
}
do {
  let service = fresh(); _ = service.prepare()
  service.failPlayback(); DispatchQueue.main.fireAll()
  check(service.pip == nil && !service.busy && service.notices.isEmpty,
        "playback failure cancels idle preparation without stale timeout or popup")
}
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance(); service.discard()
  check(service.retiringPiP.count == 1 && service.pip == nil, "issued inactive start awaits terminal")
  service.repair(); check(service.pip == nil && service.pipCreations == 1, "retirement prevents replacement controller")
  service.terminal(old)
  check(service.retiringPiP.isEmpty && service.pip !== old && service.pip != nil && !service.busy,
        "terminal releases old owner before foreground idle preparation")
  DispatchQueue.main.fireAll(); check(service.errorMessage.isEmpty, "old timer cannot fail terminal")
}
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance()
  old.onStop = { [weak service, weak old] in if let old { service?.terminal(old) } }
  service.discard()
  check(service.retiringPiP.isEmpty && service.pip !== old && !service.busy, "synchronous didStop clears safely before idle preparation")
}
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance(); DispatchQueue.main.advance(8)
  check(service.pip == nil && service.retiringPiP.count == 1 && service.busy,
        "activation timeout retains issued identity while awaiting stop")
  DispatchQueue.main.advance(5)
  check(service.retiringPiP.count == 1 && old.delegate === service.ownedDelegate,
        "unconfirmed stop retains callback identity")
  check(service.errorMessage.isEmpty && !service.seekFault && service.timelineReady && !service.busy,
        "unconfirmed PiP stop preserves healthy media instead of a global playback fault")
  check(service.rejectRetiringPiPStart(old) && old.stops == 2, "late start rejected after timeout")
  service.terminal(old); service.repair()
  check(service.pip !== old && !service.busy && service.loads == 0 && service.wantsPlayback,
        "late terminal keeps the original healthy player and latest playback intent")
}
do {
  let service = fresh(); service.repair(); let old = service.request()
  service.avPlayerPiPAuthorized = false
  check(service.rejectUnauthorizedAVPlayerPiPStart(old), "observed start without authorization rejected")
  check(service.retiringPiP.count == 1 && service.surface?.videoLayer.player === service.player,
        "willStart observed identity retained without detaching source")
  service.terminal(old)
  check(service.pip !== old && !service.busy && service.retiringPiP.isEmpty, "rejection terminal permits only idle preparation")
}
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true); DispatchQueue.main.advance()
  let replacementSurface = PlayerSurface(); UIApplication.shared.applicationState = .inactive
  service.attachSurface(replacementSurface)
  check(replacementSurface.videoLayer.player === service.player && service.pip === old,
        "new surface during issued handoff preserves source controller")
  check(!service.rejectUnauthorizedAVPlayerPiPStart(old), "issued request remains valid after UI reattachment")
  service.generation += 1
  service.pendingReplacement = (UUID(), old, false, true, false)
  check(service.rejectUnauthorizedAVPlayerPiPStart(old), "replacement rejects stale start")
  check(service.retiringPiP.isEmpty && service.pendingReplacement != nil, "replacement keeps stop fence")
  service.terminal(old)
  check(service.loads == 1 && service.pendingReplacement == nil, "terminal finishes replacement once")
}
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true); DispatchQueue.main.advance()
  service.loadLatest("b.mp4"); service.pause()
  service.terminal(old); service.repair()
  check(service.loads == 1 && service.pip !== old && !service.busy && service.loadedAutoplay == [false],
        "new pause intent survives the replacement stop acknowledgement")
}
for issued in [false, true] {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = issued
  service.mediaKitPiP = renderer; service.discardRenderer()
  check(service.mediaKitPiP == nil, "renderer ownership cleared before stop")
  check(service.retiringPiP.isEmpty == !issued, "only never-issued renderer releases without terminal")
  if issued { DispatchQueue.main.fireAll(); check(service.retiringPiP.count == 1, "issued renderer retained"); service.terminal(old) }
}
for issued in [false, true] {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = issued
  service.mediaKitPiP = renderer; service.timeoutRenderer()
  check(service.restores == (issued ? 0 : 1), "MK timeout cannot rebuild output before issued stop confirmed")
  if issued { service.terminal(old); check(service.restores == 1, "matching terminal restores inline once") }
  service.terminal(old); check(service.restores == 1, "duplicate terminal does not duplicate restore")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = true
  service.mediaKitPiP = renderer; service.timeoutRenderer(); DispatchQueue.main.fireAll(); service.terminal(old)
  check(service.restores == 1 && service.errorMessage.isEmpty,
        "late MK terminal completes the still-current inline restoration without media poisoning")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  service.mediaKitPiP = MediaKitPiPRenderer(old)
  check(!service.rejectRetiringPiPStart(old), "owned MK start observed")
  service.discardRenderer(); check(service.retiringPiP.count == 1, "observed-only MK start requires terminal")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); service.mediaKitPiP = renderer
  old.onStop = { [weak service, weak old] in if let old { service?.terminal(old) } }
  service.pendingReplacement = (UUID(), old, false, true, false); service.terminal(old)
  check(service.restores == 0 && service.loads == 1 && service.mediaKitPiP == nil,
        "synchronous MK stop cannot restore while replacing")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = true
  service.mediaKitPiP = renderer; service.mediaKitPiPActiveRequestID = "request"
  var results: [Bool] = []
  service.abortMediaKitPiP(engineID: service.mediaKit!.id, requestID: "request") { results.append($0) }
  check(results.isEmpty && service.retiringPiP.count == 1, "MK abort waits for issued stop")
  service.terminal(old); check(results == [true], "matching terminal completes abort once")
  DispatchQueue.main.fireAll(); check(results == [true], "late timeout cannot complete abort twice")
}
// A fatal failure cancels pending MK preparation and retires an issued
// renderer without initiating another output before the terminal callback.
for issued in [false, true] {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = issued
  service.mediaKitPiP = renderer; service.mediaKitPiPPreparing = true
  service.mediaKitPiPRequestID = "old"; service.failPlayback()
  check(!service.mediaKitPiPPreparing && service.mediaKitPiPRequestID == nil,
        "fatal failure invalidates MK authorization before late readiness")
  check(service.mediaKitPiP == nil && service.retiringPiP.isEmpty == !issued,
        "fatal failure releases only unissued MK renderer")
  check(service.restores == 0, "failure cannot restore output while retiring")
}
for bits in 0..<128 {
  func bit(_ index: Int) -> Bool { bits & (1 << index) != 0 }
  check(MediaKitDecoderRecoveryPolicy.permitsRequest(identityMatches: bit(0), active: bit(1),
    wantsPlayback: bit(2), stable: bit(3), presentationOwned: bit(4), attempted: bit(5),
    recovering: bit(6)) == (bits == 15), "decoder recovery eligibility matrix")
}
for blocked in 0..<13 {
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  var id = engine.id, version = 0
  switch blocked {
  case 0: id = "stale"
  case 1: version = 1
  case 2: service.inBackground = true
  case 3: UIApplication.shared.applicationState = .inactive
  case 4: service.wantsPlayback = false
  case 5: service.isSeeking = true
  case 6: service.scrubbing = true
  case 7: service.interrupted = true
  case 8: service.loading = true
  case 9: service.controlBusy = true
  case 10: service.mediaKitPiPPreparing = true
  case 11: service.mediaKitPiPRestoring = true
  default:
    let controller = AVPictureInPictureController(playerLayer: VideoLayer())!
    let key = ObjectIdentifier(controller)
    service.retiringPiP[key] = (controller, nil, true)
    service.unconfirmedPiPStops.insert(key)
  }
  var results: [Bool] = []
  service.requestMediaKitDecoderRecovery(engineID: id, positionVersion: version) { results.append($0) }
  check(results == [false] && engine.controls.isEmpty && !service.decoderRecoveryAttempted,
        "unsafe/deferred decoder recovery consumes no budget or output")
}
do {
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  var results: [Bool] = []
  service.requestMediaKitDecoderRecovery(engineID: engine.id, positionVersion: 0) { results.append($0) }
  check(engine.controls.count == 1 && service.decoderRecoveryAttempted && results.isEmpty,
        "native reserves one recovery before sending command")
  service.requestMediaKitDecoderRecovery(engineID: engine.id, positionVersion: 0) { results.append($0) }
  check(results == [false] && engine.controls.count == 1, "reentrant recovery cannot issue twice")
  do { try service.startPiP(delegate: service.ownedDelegate); check(false, "PiP cannot race decoder repair") }
  catch { check(service.pip == nil, "PiP gate holds output during recovery") }
  service.wantsPlayback = false
  engine.controls[0].1(true); DispatchQueue.main.advance()
  check(results == [false, true] && !service.wantsPlayback, "completion respects latest paused intent")
  service.wantsPlayback = true
  service.requestMediaKitDecoderRecovery(engineID: engine.id, positionVersion: 0) { results.append($0) }
  check(results == [false, true, false] && service.errorMessage == "media_playback_failed" && service.lastDiagnostic.contains("media_decoder_recovery_failed"),
        "exhausted stable task ends with failure instead of repeated deferred retries")
}
for reason in 0..<3 {
  let superseded = reason != 0
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  var results: [Bool] = []
  service.requestMediaKitDecoderRecovery(engineID: engine.id, positionVersion: 0) { results.append($0) }
  if reason == 1 { engine.positionVersion = 1 }
  if reason == 2 { engine.playIntentVersion = 1; service.wantsPlayback = false }
  engine.controls[0].1(false); DispatchQueue.main.advance()
  check(results == [superseded], "stale recovery failure cannot poison newer seek")
  check(service.errorMessage.isEmpty == superseded, "only current repair failure is terminal")
}
do {
  let service = fresh(); let old = ReviewEngine(); service.mediaKit = old
  var results: [Bool] = []
  service.requestMediaKitDecoderRecovery(engineID: old.id, positionVersion: 0) { results.append($0) }
  service.generation += 1; service.mediaKit = ReviewEngine(); service.decoderRecoveryRequest = nil
  old.controls[0].1(false); DispatchQueue.main.advance()
  check(results == [false] && service.errorMessage.isEmpty, "stale engine repair cannot fail replacement")
}
// Regression contracts from the user's failed device trace: an active result
// wins over clock expiry, and PiP failure never poisons an unchanged item.
for delegateFirst in [false, true] {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance(); old.isPictureInPictureActive = true
  if delegateFirst {
    DispatchQueue.main.now = 8.1; service.didStartAVPlayerPiP(old)
  } else { DispatchQueue.main.advance(8) }
  check(service.pip === old && old.stops == 0 && service.retiringPiP.isEmpty,
        "active success cannot be rejected by an expired watchdog deadline")
  check(service.generation == 1 && !service.seekFault && service.notices.isEmpty,
        "delayed successful PiP has no media fault or error popup")
}
for newerIntent in 0..<5 {
  let service = fresh(); service.repair(); let owner = service.player
  let item = owner.currentItem; let old = service.request(ready: true)
  DispatchQueue.main.advance(); DispatchQueue.main.advance(8); DispatchQueue.main.advance(5)
  // Model the documented AVKit stop side effect, independently of wantsPlayback.
  owner.pause()
  switch newerIntent {
  case 1: service.pause()
  case 2: service.enterBackground(enabled: false)
  case 3: service.interrupted = true
  case 4: service.scrubbing = true
  default: break
  }
  service.terminal(old)
  check(owner.currentItem === item && service.player === owner && service.generation == 1,
        "PiP-only failure recovers the exact healthy player/item/generation")
  check(owner.rate == (newerIntent == 0 ? 1 : 0),
        "terminal restores actual playback only if the latest intent permits it")
  check(!service.seekFault && service.errorMessage.isEmpty && service.loads == 0,
        "automatic inline restoration needs neither a retry tap nor media reload")
}
// New opens merge while the original stop wait stays bounded. Pause, page
// dismissal, background-off, and explicit clear each supersede older autoplay.
for newerIntent in 0..<5 {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance(); service.loadLatest("b.mp4")
  let originalID = service.pendingReplacement?.id
  DispatchQueue.main.advance(2); service.loadLatest("c.mp4")
  check(service.pendingReplacement?.id == originalID && service.loads == 0,
        "newer selection updates intent without restarting the stop deadline")
  switch newerIntent {
  case 1: service.pause()
  case 2: service.playerDismissed()
  case 3: service.enterBackground(enabled: false)
  case 4: service.clearLatest()
  default: break
  }
  service.terminal(old); service.terminal(old); DispatchQueue.main.fireAll()
  if newerIntent == 4 {
    check(service.loads == 0 && service.clears == 1 && service.currentPath == nil,
          "clear cancels the queued open and consumes its terminal once")
  } else {
    check(service.loadedPaths == ["c.mp4"] && service.loadedAutoplay == [newerIntent == 0],
          "terminal consumes only the latest selection and current play intent")
  }
  check(service.errorMessage.isEmpty && service.pendingReplacement == nil,
        "bounded replacement never fails the entire media session")
}
// No terminal: AVPlayer gets exactly one retained, muted graph. It is not torn
// down to make room. New ordinary items use a separate graph, without new PiP.
do {
  let service = fresh(); service.repair(); let retainedPlayer = service.player
  let retainedItem = retainedPlayer.currentItem; let retainedLayer = service.surface!.videoLayer
  let old = service.request(ready: true); DispatchQueue.main.advance()
  service.loadLatest("b.mp4"); DispatchQueue.main.advance(5)
  let current = service.player
  check(current !== retainedPlayer && service.loadedPaths == ["b.mp4"],
        "unconfirmed AV stop permits a selected new item after bounded wait")
  check(retainedPlayer.currentItem === retainedItem && retainedLayer.player === retainedPlayer,
        "isolation never changes AVKit's retained item or source layer")
  check(service.boundaryRemovalOwners == [ObjectIdentifier(retainedPlayer)],
        "old boundary removal executes before current player changes")
  check(retainedPlayer.isMuted && retainedPlayer.rate == 0 && current.rate == 1,
        "one current audible player; old graph is paused and unconditionally muted")
  check(service.surface!.videoLayer !== retainedLayer && service.surface!.videoLayer.player === current,
        "current and quarantined output have independent layer ownership")
  retainedPlayer.rate = 1; DispatchQueue.main.advance()
  check(retainedPlayer.rate == 0 && retainedPlayer.isMuted && current.rate == 1,
        "late system play on the old PiP cannot emit sound or pause new playback")
  old.isPictureInPictureActive = true
  check(service.rejectRetiringPiPStart(old) && old.stops >= 2,
        "late old start is rejected by controller identity")
  check(!service.allowsPiPRestore(old), "retired PiP cannot restore a stale player page")
  do { try service.startPiP(delegate: service.ownedDelegate); check(false, "retained graph blocks another PiP") }
  catch { check(service.pipCreations == 1, "quarantine count cannot grow via repeated PiP taps") }
  service.loadLatest("c.mp4"); service.loadLatest("d.mp4")
  check(service.player === current && service.playerCreations == 2 && service.retiredAVPlayerOutputs.count == 1,
        "subsequent ordinary opens reuse current player; retention remains bounded")
  let calls = service.audioRecoveryCalls
  old.isPictureInPictureActive = false; service.terminal(old); service.terminal(old)
  check(retainedPlayer.currentItem == nil && retainedLayer.player == nil && retainedPlayer.rateChanged == nil,
        "only terminal proof releases the quarantined item, layer binding and KVO")
  check(service.loads == 3 && service.audioRecoveryCalls == calls && service.player === current,
        "stale terminal never reloads or resumes the newer playback task")
  check(service.retiringPiP.isEmpty && service.retiredAVPlayerOutputs.isEmpty,
        "one confirmed terminal frees all quarantined identities")
}
// A start already retired by its own timeout must also accept a later new open.
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance(); DispatchQueue.main.advance(8)
  service.loadLatest("b.mp4"); service.loadLatest("c.mp4"); service.pause()
  check(service.loads == 0 && service.deferredPresentationLoad != nil,
        "new request is retained during retirement, never dropped as global failure")
  DispatchQueue.main.advance(5)
  check(service.loadedPaths == ["c.mp4"] && service.loadedAutoplay == [false],
        "retirement timeout consumes the newest queued paused item")
  service.terminal(old); check(service.loads == 1, "late terminal cannot duplicate the deferred load")
}
for leaveAfterTimeout in [false, true] {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance(); service.loadLatest("b.mp4")
  if leaveAfterTimeout { DispatchQueue.main.advance(5) }
  service.clearLatest(); DispatchQueue.main.fireAll(); service.terminal(old)
  check(service.currentPath == nil && service.clears == 1,
        "clear before or after isolation does not leave a queued reopen")
  check(!service.wantsPlayback || service.player.currentItem == nil,
        "cleared session has no playable current item")
}
// Shared mpv output is deliberately not isolated by inventing a second owner.
// Its latest intent remains cancellable and terminal acknowledgement consumes it.
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = true
  service.mediaKitPiP = renderer; service.timeoutRenderer()
  service.errorMessage = "media_playback_failed"
  service.loadLatest("b.mkv")
  check(service.errorMessage.isEmpty && service.deferredPresentationLoad != nil,
        "new pending media clears stale failure and reports truthful ownership waiting")
  DispatchQueue.main.advance(5)
  service.loadLatest("c.mkv"); service.playerDismissed()
  check(service.loads == 0 && service.retiringPiP.count == 1 && service.deferredPresentationLoad != nil,
        "unconfirmed mpv output retains the latest request without unsafe replacement")
  check(service.errorMessage.isEmpty && !service.loading,
        "unconfirmed shared output is diagnostic and does not lock the player page")
  service.terminal(old)
  check(service.loadedPaths == ["c.mkv"] && service.loadedAutoplay == [false] && service.restores == 0,
        "MK terminal consumes latest paused selection instead of restoring stale output")
}
for issued in [false, true] {
  let service = fresh(); service.repair(); let old = service.request(ready: issued)
  DispatchQueue.main.advance(); service.playerDismissed(); DispatchQueue.main.fireAll()
  check(service.pip == nil && service.wantsPlayback && service.errorMessage.isEmpty,
        "return-to-library cancels unfinished PiP while keeping ordinary audio intent")
  check(service.retiringPiP.count == (issued ? 1 : 0),
        "page dismissal retains issued resources until terminal, never assumes inactive is safe")
  if issued { service.terminal(old) }
}
// The same MK video has no deferred load: its missing output must still be
// honestly waiting and paused until the actual restoration acknowledgement.
for newerIntent in 0..<5 {
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = true
  service.mediaKitPiP = renderer; service.player.rate = 1; service.enginePlaying = true
  service.timeoutRenderer()
  check(service.waiting && service.wantsPlayback && service.pauses == 1,
        "same-MK output retirement preserves intent but pauses real playback")
  service.play()
  check(service.audioRecoveryCalls == 0 && service.player.rate == 0,
        "play during missing output only saves intent; it cannot start audio")
  DispatchQueue.main.advance(5)
  check(service.waiting && service.restores == 0 && service.errorMessage.isEmpty,
        "no terminal keeps a truthful nonfatal waiting state, not false playing")
  service.terminal(old)
  check(service.waiting && service.restores == 1 && service.audioRecoveryCalls == 0,
        "terminal alone does not resume before inline output acknowledgement")
  switch newerIntent {
  case 1: service.pause()
  case 2: service.enterBackground(enabled: false)
  case 3: service.playerDismissed()
  case 4: service.loadLatest("new.mp4")
  default: break
  }
  let calls = service.audioRecoveryCalls
  engine.outputRestoreCompletions[0](true); DispatchQueue.main.advance()
  if newerIntent == 4 {
    check(service.audioRecoveryCalls == calls && service.loadedPaths == ["new.mp4"],
          "old output restoration cannot resume or overwrite a newer media task")
  } else {
    check(!service.waiting && service.player.rate == (newerIntent == 0 ? 1 : 0),
          "output-ready callback resumes only the latest permitted current intent")
  }
}
// Reset invalidates the player even when AVFoundation has not marked it failed.
do {
  let service = fresh(); let old = service.player
  service.rebuildResetPlayer()
  check(service.player === old && service.playerCreations == 1,
        "ordinary healthy loads never rebuild an AVPlayer")
  service.rebuildPlayerAfterMediaServicesReset = true
  service.rebuildResetPlayer()
  check(service.player !== old && service.playerCreations == 2 && !service.rebuildPlayerAfterMediaServicesReset,
        "media-server reset rebuilds one player even with a non-failed status")
  service.rebuildResetPlayer()
  check(service.playerCreations == 2, "reset rebuild request is consumed once")
}
// An isolated old AV graph cannot own a different MK inline decoder, while
// the system PiP gate must remain closed without the old terminal.
for retiredKind in 0..<4 {
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  let source = VideoLayer(); let owner = AVPlayer(); source.player = owner
  let old = AVPictureInPictureController(playerLayer: source)!
  let key = ObjectIdentifier(old)
  let renderer = retiredKind == 2 ? MediaKitPiPRenderer(old) : nil
  service.retiringPiP[key] = (old, renderer, true)
  service.unconfirmedPiPStops.insert(key)
  if retiredKind != 3 {
    service.retiredAVPlayerOutputs[key] = (owner, nil, source, retiredKind != 1, nil)
  }
  var results: [Bool] = []
  service.requestMediaKitDecoderRecovery(engineID: engine.id, positionVersion: 0) { results.append($0) }
  check(engine.controls.count == (retiredKind == 0 ? 1 : 0),
        "only positively isolated AV retirement is unrelated to current MK decoder recovery")
  if retiredKind == 0 { engine.controls[0].1(true); DispatchQueue.main.advance() }
  check(results == [retiredKind == 0], "MK/unknown/non-isolated output owners retain the decoder fence")
  do {
    try service.startPiP(delegate: service.ownedDelegate, requestID: "new-mk-request")
    check(false, "unknown system PiP cannot be bypassed by an isolated AV graph")
  } catch { check(service.pipCreations == 0 && service.retiringPiP.count == 1,
                  "local decoder recovery cannot clear system PiP quarantine") }
}
// Terminal-confirmed current MK output can restore despite another isolated
// AV retirement. A second MK or unknown owner still keeps the output fenced.
for otherKind in 0..<3 {
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  let source = VideoLayer(); let owner = AVPlayer(); source.player = owner
  let av = AVPictureInPictureController(playerLayer: source)!
  let avKey = ObjectIdentifier(av)
  service.retiringPiP[avKey] = (av, otherKind == 1 ? MediaKitPiPRenderer(av) : nil, true)
  service.unconfirmedPiPStops.insert(avKey)
  if otherKind != 2 { service.retiredAVPlayerOutputs[avKey] = (owner, nil, source, true, nil) }
  let current = AVPictureInPictureController(playerLayer: VideoLayer())!
  let key = ObjectIdentifier(current)
  service.retiringPiP[key] = (current, MediaKitPiPRenderer(current), true)
  service.retiringPiPRestores[key] = (engine, service.generation)
  service.terminal(current)
  check(engine.restoreCalls == (otherKind == 0 ? 1 : 0),
        "terminal-triggered MK inline restoration checks output ownership, not registry emptiness")
  check(service.retiringPiP[avKey] != nil && source.player === owner,
        "unrelated inline restoration never releases the old AV graph")
}
do {
  let service = fresh(); let owner = AVPlayer(); let layer = VideoLayer(); layer.player = owner
  let old = AVPictureInPictureController(playerLayer: layer)!
  let key = ObjectIdentifier(old)
  service.retiringPiP[key] = (old, nil, true)
  service.retiredAVPlayerOutputs[key] = (owner, nil, layer, true, nil)
  service.unconfirmedPiPStops.insert(key)
  let completed = AVPictureInPictureController(playerLayer: VideoLayer())!
  service.retiringPiP[ObjectIdentifier(completed)] = (completed, nil, true)
  service.currentPath = nil; service.terminal(completed)
  check(service.clears == 1 && service.retiringPiP[key] != nil && layer.player === owner,
        "clearing the current graph does not require destroying unrelated isolated AV output")
}
// The position-only checkpoint must not change persisted-history semantics.
do {
  let service = fresh(); service.mediaKit = ReviewEngine(); service.currentPath = "fallback.mp4"
  service.position = 60; service.recoverOutput()
  check(service.willContinueMKRecovery(path: "fallback.mp4", token: service.generation),
        "MK output recovery keeps an AV-fallback MP4 on MK for its position acknowledgment")
  check(!service.willContinueMKRecovery(path: "fallback.mp4", token: service.generation + 1),
        "internal MK routing requires the exact handoff generation")
  check(!service.willContinueMKRecovery(path: "different.mp4", token: service.generation),
        "internal MK routing cannot affect a different selected file")
  service.currentSessionID = UUID()
  check(!service.willContinueMKRecovery(path: "fallback.mp4", token: service.generation),
        "same-path explicit new session cannot inherit internal MK routing")
  service.clearSessionPosition()
  check(!service.willContinueMKRecovery(path: "fallback.mp4", token: service.generation),
        "ordinary open retains its original engine-selection policy")
}
for remember in [false, true] {
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  service.currentPath = "a.mkv"; service.rememberProgress = remember
  service.position = 61.25; service.timelineOrigin = 2; service.capturePosition()
  check(service.currentSessionCheckpoint?.sourcePosition == 63.25,
        "valid current position is captured even when rememberProgress is OFF")
  check((service.lastValidRememberedProgress != nil) == remember,
        "volatile capture never enables disk-history writes")
  service.progressValid = false; service.position = 99; service.capturePosition()
  check(service.currentSessionCheckpoint?.sourcePosition == 63.25,
        "preview/unacknowledged seek cannot overwrite last confirmed position")
  service.recoverOutput()
  let newEngine = service.mediaKit!
  check(service.loads == 1 && newEngine !== engine && service.currentSessionPositionRestore != nil,
        "output recovery hands one checkpoint to exactly one new engine generation")
  service.recoverOutput()
  check(service.loads == 1, "duplicate failure/timeout cannot issue a second recovery reload")
  service.restorePositionReady()
  check(service.requestedSeeks == [63.25], "new MK restores source time without consulting history")
  service.position = 63.25; service.seekCompletions[0](true); DispatchQueue.main.advance()
  check(service.currentSessionPositionRestore == nil && service.initialPositionEstablished,
        "one matching confirmed seek consumes the restoration request")
  service.seekCompletions[0](true); DispatchQueue.main.advance()
  check(service.audioRecoveryCalls == 1, "duplicate restore acknowledgment cannot resume twice")
}
for newerIntent in 0..<5 {
  let service = fresh(); service.mediaKit = ReviewEngine(); service.currentPath = "a.mkv"
  service.position = 119.5; service.recoverOutput(); service.restorePositionReady()
  check(service.requestedSeeks == [119.5], "near-EOF checkpoint is not filtered to zero")
  switch newerIntent {
  case 1: service.pause()
  case 2: service.enterBackground(enabled: false)
  case 3: service.interrupted = true
  case 4:
    service.playbackOperation += 1; service.currentSessionPositionRestore = nil
  default: break
  }
  service.position = 119.5
  service.seekCompletions[0](true); DispatchQueue.main.advance()
  check(service.audioRecoveryCalls == (newerIntent == 0 || newerIntent == 3 ? 1 : 0),
        "position acknowledgement preserves latest intent; real audio-recovery method owns interruption gate")
  check(service.player.rate == (newerIntent == 0 ? 1 : 0),
        "restored position does not grant playback during a newer pause/background/interruption")
  if newerIntent == 4 { check(!service.initialPositionEstablished,
                              "newer seek cancels old restore success before position is established") }
}
for invalid in 0..<4 {
  let service = fresh(); let engine = ReviewEngine(); service.mediaKit = engine
  service.currentPath = "a.mkv"; service.position = 27; service.capturePosition()
  service.progressValid = false
  switch invalid {
  case 0: service.currentSessionCheckpoint = nil
  case 1: service.currentSessionID = UUID()
  case 2: service.generation += 1
  default: service.mediaKit = ReviewEngine()
  }
  service.recoverOutput()
  check(service.loads == 0 && service.errorMessage == "media_playback_failed" && !service.wantsPlayback,
        "missing/stale checkpoint never falls back to history or a false zero-position recovery")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine(); service.currentPath = "a.mkv"
  service.position = 32; service.recoverOutput()
  service.restorePositionReady(seekable: false)
  check(service.requestedSeeks.isEmpty && service.currentSessionPositionRestore == nil && !service.wantsPlayback,
        "non-seekable rebuilt media fails visibly rather than restarting at zero")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine(); service.currentPath = "a.mkv"
  service.position = 45; service.recoverOutput(); service.restorePositionReady()
  service.clearSessionPosition(); service.loadLatest("a.mkv")
  let generation = service.generation, calls = service.audioRecoveryCalls
  service.seekCompletions[0](true); DispatchQueue.main.advance()
  check(service.currentSessionCheckpoint == nil && service.currentSessionPositionRestore == nil,
        "ordinary reopen of the same path clears both checkpoint and restore identity")
  check(service.generation == generation && service.audioRecoveryCalls == calls,
        "old restoration cannot change a newer same-path session")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine(); service.currentPath = "a.mkv"
  service.position = 45; service.recoverOutput(); service.restorePositionReady()
  service.restorePositionReady()
  check(service.requestedSeeks == [45], "duplicate ready keeps one in-flight restore seek")
  service.replayCurrent()
  check(service.currentSessionPositionRestore == nil && service.replayStarts == [0],
        "single-item replay accepts new zero-position intent and cancels old restore")
  service.seekCompletions[0](true); DispatchQueue.main.advance()
  check(service.audioRecoveryCalls == 0 && !service.initialPositionEstablished,
        "late cancelled restore cannot complete or resume the accepted replay")
  // Finish the replay collaborator, then encounter another output failure.
  service.replayOperation = nil; service.initialPositionEstablished = true
  service.progressValid = true; service.position = 0
  service.recoverOutput()
  check(service.loads == 2 && service.currentSessionPositionRestore?.seekIssued == false,
        "cancelled replay restore leaves no residual request blocking later recovery")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine(); service.currentPath = "a.mkv"
  service.position = 45; service.recoverOutput()
  service.currentSessionPositionRestore?.targetEngineID = "wrong-engine"
  service.restorePositionReady()
  check(service.currentSessionPositionRestore == nil && !service.loading && !service.wantsPlayback,
        "current ready identity mismatch ends recovery in a bounded paused failure")
  check(service.requestedSeeks.isEmpty && service.errorMessage == "media_playback_failed",
        "mismatched restoration cannot seek or silently start at zero")
}
// Idle PiP source-release regression scenarios execute the real idle method.
for ready in [false, true] {
  for backgroundEnabled in [false, true] {
    let service = fresh(); service.background = backgroundEnabled
    let controller = service.prepare(ready: ready)
    let player = service.player; let item = player.currentItem
    let layer = service.surface!.videoLayer
    let staleKVO = controller.changed!
    let previousLayerReads = controller.playerLayerReads
    var setterRan = false
    controller.onContentSourceClear = { [weak service, weak controller] in
      guard let service, let controller else { return }
      setterRan = true
      check(service.pip == nil && service.pipPossibleObservation == nil
            && controller.delegate == nil && controller.changed == nil,
            "source setter runs only after current ownership, delegate and KVO are cleared")
      check(controller.playerLayerReads == previousLayerReads,
            "idle release never asks the deprecated controller playerLayer getter")
      // Force both an already-captured KVO delivery and synchronous stale
      // delegate diagnostics while the ContentSource setter is running.
      staleKVO(); DispatchQueue.main.advance()
      service.recordPiPDelegateEntry("source-clear probe", controller: controller)
      service.recordAVPlayerPiPEvent("stale source-clear probe", controller: controller)
      check(controller.playerLayerReads == previousLayerReads && service.pip == nil,
            "setter-reentrant old callbacks cannot read a released layer or regain ownership")
    }
    service.resign()
    check(setterRan && controller.contentSource == nil && controller.contentSourceClearCount == 1,
          "unrequested idle Home explicitly clears the source exactly once")
    check(controller.starts == 0 && controller.stops == 0 && service.retiringPiP.isEmpty,
          "idle source release neither starts nor stops nor retires PiP")
    check(service.player === player && player.currentItem === item
          && service.surface?.videoLayer === layer && layer.player === player,
          "source release preserves the exact player, item, surface and layer binding")
    check(service.wantsPlayback && service.loads == 0 && service.requestedSeeks.isEmpty,
          "idle source release cannot alter playback intent or timeline")
    check(service.lifecycleEvents.contains { $0.contains("idle source clear before")
          && $0.contains("contentSourcePresent=true") && $0.contains("sourceMatchedCurrentLayer=true") }
          && service.lifecycleEvents.contains { $0.contains("sourceClear=after")
          && $0.contains("contentSourcePresent=false") && $0.contains("sourceMatchedCurrentLayerBefore=true") },
          "bounded diagnostics identify this controller's source before and after release")
    service.resign()
    check(controller.contentSourceClearCount == 1, "repeated Home cannot re-clear an unowned controller")
    let replacement = service.prepare(ready: true)
    staleKVO(); DispatchQueue.main.advance()
    check(replacement !== controller && service.pip === replacement && replacement.contentSource != nil
          && replacement.contentSourceClearCount == 0 && replacement.starts == 0,
          "foreground return obtains a new prepared controller unaffected by old KVO")
    try! service.startPiP(delegate: service.ownedDelegate)
    check(replacement.starts == 1 && replacement.contentSourceClearCount == 0,
          "the next explicit manual start still uses its intact prepared source")
  }
}
for activationAfterGuard in [false, true] {
  let service = fresh(); let controller = service.prepare(ready: true)
  // The first read is the outer idle gate, the second belongs to generic
  // discard, and the third (when not retired) is the added setter fence.
  controller.activeReadSequence = activationAfterGuard ? [false, false, true] : [false, true]
  service.resign()
  check(controller.contentSourceClearCount == 0 && controller.contentSource != nil,
        "system activation between idle sampling and clearing prevents source release")
  check(controller.stops == (activationAfterGuard ? 0 : 1),
        "R6 adds no stop beyond the unchanged generic-discard retirement decision")
  check((service.retiringPiP[ObjectIdentifier(controller)] != nil) == !activationAfterGuard,
        "post-discard fence preserves the original retirement ownership outcome")
}

// Each protection is exercised alone, including malformed-but-safe states.
for protection in 0..<9 {
  let service = fresh(); let controller = service.prepare(ready: true)
  let observation = service.pipPossibleObservation
  let source = controller.contentSource
  switch protection {
  case 0: service.avPlayerPiPAuthorized = true
  case 1:
    service.avPlayerPiPRequest = (UUID(), service.generation, service.player.currentItem!, service.surface!.videoLayer, nil)
  case 2: service.pipStartIssued = true
  case 3: service.observedPiPStarts.insert(ObjectIdentifier(controller))
  case 4: controller.isPictureInPictureActive = true
  case 5:
    service.pendingReplacement = (UUID(), controller, false, true, false)
  case 6:
    let retired = AVPictureInPictureController(playerLayer: VideoLayer())!
    service.retiringPiP[ObjectIdentifier(retired)] = (retired, nil, true)
  case 7: service.mediaKit = ReviewEngine()
  default: break // The last case enters the real production method off-main.
  }
  if protection == 8 {
    let finished = DispatchSemaphore(value: 0)
    let worker = Thread { service.resign(); finished.signal() }
    worker.start(); finished.wait()
    while !worker.isFinished { Thread.sleep(forTimeInterval: 0.001) }
  } else { service.resign() }
  check(service.pip === controller && service.pipPossibleObservation === observation
        && controller.contentSource === source && controller.contentSourceClearCount == 0,
        "every non-idle/thread/ownership fence preserves controller, observation and source")
  check(controller.starts == 0 && controller.stops == 0,
        "protected presentations receive no start or stop side effect")
}
do {
  let service = fresh(); let controller = service.prepare(ready: true)
  // An old restore's passive inline mirror is not ownership of this new idle controller.
  service.pipPlaybackSession = (UUID(), ObjectIdentifier(AVPictureInPictureController(playerLayer: VideoLayer())!),
    service.generation, UUID(), true, true)
  service.resign()
  check(controller.contentSourceClearCount == 1,
        "a previous inline mirror must not block release of a newly prepared idle source")
}
do {
  let service = fresh(); let controller = service.prepare(ready: true)
  controller.contentSource!.playerLayer = nil
  service.resign()
  check(controller.contentSourceClearCount == 1 && service.lifecycleEvents.contains {
    $0.contains("sourceClear=after") && $0.contains("sourceMatchedCurrentLayerBefore=false") },
    "a missing source layer is never reported as matching another nil layer")
}
do {
  let service = fresh(); let controller = service.prepare(ready: true)
  service.discard()
  check(controller.contentSourceClearCount == 0 && controller.contentSource != nil,
        "generic discard outside the Home idle path is unchanged by the experiment")
}

// Prepared manual PiP regression scenarios exercise the restored sequence.
for backgroundEnabled in [false, true] {
  let service = fresh(); service.background = backgroundEnabled
  let controller = service.prepare(ready: true)
  let oldPlayer = service.player; let oldItem = oldPlayer.currentItem
  DispatchQueue.main.advance(60)
  check(controller.starts == 0 && !service.busy && service.available && !service.avPlayerPiPAuthorized,
        "long-lived foreground preparation has no request timeout or authorization")
  service.resign(); UIApplication.shared.applicationState = .background
  service.enterBackground(enabled: backgroundEnabled)
  DispatchQueue.main.advance(30)
  check(service.pip == nil && controller.starts == 0 && controller.stops == 0
        && service.retiringPiP.isEmpty && service.player === oldPlayer && oldPlayer.currentItem === oldItem
        && service.surface?.videoLayer.player === oldPlayer,
        "zero-click Home releases idle registration while preserving the original video graph")
  check(service.wantsPlayback == backgroundEnabled,
        "idle preparation does not override the user's background-audio preference")
  UIApplication.shared.applicationState = .active; service.inBackground = false; service.repair()
  check(service.pip !== controller && service.pip != nil && !service.busy,
        "foreground return prepares again without a phantom request")
}
do {
  let service = fresh(); let controller = service.prepare(ready: true)
  var observationPresentAtCall = true
  controller.onStart = { [weak service, weak controller] in
    observationPresentAtCall = service?.pipPossibleObservation != nil || controller?.changed != nil
  }
  try! service.startPiP(delegate: service.ownedDelegate)
  check(!observationPresentAtCall && service.pipPossibleObservation == nil && controller.starts == 1,
        "button starts directly and consumes readiness observation before the call")
  let deadline = service.avPlayerPiPRequest!.deadline; let timeout = service.pipActivationTimeout
  controller.isPictureInPicturePossible = false; controller.isPictureInPicturePossible = true
  DispatchQueue.main.advance()
  check(!service.rejectRetiringPiPStart(controller) && !service.rejectUnauthorizedAVPlayerPiPStart(controller),
        "explicit willStart remains authorized")
  check(service.avPlayerPiPRequest!.deadline == deadline && service.pipActivationTimeout === timeout
        && controller.starts == 1 && controller.stops == 0,
        "late KVO/willStart cannot extend the watchdog or repeat AVKit start")
  service.resign(); UIApplication.shared.applicationState = .background
  service.reconcile()
  check(service.pip === controller && service.avPlayerPiPAuthorized && service.retiringPiP.isEmpty,
        "manual click followed by Home preserves request and output")
  controller.isPictureInPictureActive = true; service.didStartAVPlayerPiP(controller)
  UIApplication.shared.applicationState = .active; service.repair()
  check(service.pip === controller && service.pipCreations == 1,
        "return while PiP active never replaces its controller")
}
do {
  let service = fresh(); let controller = service.prepare(ready: true)
  // begin guard, requested diagnostic, then the final pre-start sample.
  controller.possibleReadSequence = [true, true, false]
  try! service.startPiP(delegate: service.ownedDelegate)
  check(controller.possibleReadSequence.isEmpty && controller.starts == 0
        && service.avPlayerPiPRequest == nil && !service.avPlayerPiPAuthorized && !service.busy,
        "readiness lost between checks cannot leave an unbounded pending authorization")
  check(service.pip === controller && service.pipPossibleObservation != nil
        && service.pipActivationTimeout == nil && service.manualPiPSession == nil,
        "lost readiness keeps idle KVO without creating a timeout or background permission")
  controller.isPictureInPicturePossible = true; DispatchQueue.main.advance()
  check(controller.starts == 0, "readiness recovery still requires another manual tap")
  try! service.startPiP(delegate: service.ownedDelegate)
  check(controller.starts == 1 && service.busy, "next ready tap starts the same prepared controller")
}
for cancelWithFailure in [false, true] {
  let service = fresh(); let controller = service.request()
  if cancelWithFailure { service.failPlayback() } else { service.cancel() }
  check(service.pipPossibleObservation == nil && controller.changed == nil && service.retiringPiP.count == 1,
        "failure/cancellation uses issued-controller terminal fencing")
}
do {
  let service = fresh(); let old = service.prepare(); let staleDelivery = old.changed!
  service.resign(); UIApplication.shared.applicationState = .active
  let current = service.prepare(ready: true)
  old.isPictureInPicturePossible = true; staleDelivery(); DispatchQueue.main.advance()
  check(old.starts == 0 && current.starts == 0 && service.pip === current && service.avPlayerPiPRequest == nil,
        "old idle KVO cannot start the replacement or create a request")
  try! service.startPiP(delegate: service.ownedDelegate)
  let requestID = service.avPlayerPiPRequest!.id; let timeout = service.pipActivationTimeout
  staleDelivery(); DispatchQueue.main.advance()
  check(service.avPlayerPiPRequest!.id == requestID && service.pipActivationTimeout === timeout
        && current.starts == 1 && old.starts == 0,
        "old queued KVO cannot mutate the new manual request")
}
do {
  let service = fresh(); let staleRequest = UUID()
  AVPictureInPictureController.onCreate = { [weak service] controller in
    service?.avPlayerPiPTraceRequests = [(ObjectIdentifier(controller), staleRequest, -99)]
  }
  let controller = service.prepare(ready: true)
  AVPictureInPictureController.onCreate = nil
  check(service.avPlayerPiPTraceRequests.isEmpty,
        "new preparation removes old trace at a reused controller address")
  controller.isPictureInPictureActive = true
  service.recordPiPDelegateEntry("willStart", controller: controller)
  service.recordAVPlayerPiPEvent("unauthorized probe", controller: controller)
  check(!service.lifecycleEvents.contains { $0.contains(staleRequest.uuidString) || $0.contains("requestGeneration=-99") },
        "active-before-unauthorized callback cannot inherit an older request identity")
  check(service.rejectUnauthorizedAVPlayerPiPStart(controller),
        "trace cleanup never grants permission to the unsolicited active controller")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  check(service.available, "MK video remains immediately available without AV preparation")
  service.repair(); service.resign()
  check(service.pip == nil && service.pipCreations == 0, "MK path never acquires an AV preparation")
  try! service.startPiP(delegate: service.ownedDelegate, requestID: "manual-mk")
  check(service.mediaKitPiPPreparing && service.manualPiPSession == service.generation,
        "MK explicit asynchronous preparation and bounded authorization remain unchanged")
}

// PiP close and restore regression scenarios
func acceptedAVPiP(_ service: PresentationReviewHost) -> AVPictureInPictureController {
  let controller = service.request()
  controller.isPictureInPictureActive = true
  service.player.rate = 1; service.player.timeControlStatus = .playing
  service.didStartAVPlayerPiP(controller)
  return controller
}
func acceptedMKPiP(_ service: PresentationReviewHost) -> AVPictureInPictureController {
  service.mediaKit = ReviewEngine()
  let controller = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(controller); renderer.startIssued = true
  service.mediaKitPiP = renderer; service.authorizeManualPiP(seconds: 8)
  controller.isPictureInPictureActive = true; service.didStartMediaKitPiP(controller)
  return controller
}
for mk in [false, true] {
  for background in [false, true] {
    let service = fresh(); service.background = background; service.position = 37
    let controller = mk ? acceptedMKPiP(service) : acceptedAVPiP(service)
    service.pendingEndAction = true
    service.willStopPiP(controller)
    controller.isPictureInPictureActive = false; service.terminal(controller)
    check(!service.wantsPlayback && !service.pendingEndAction && service.position == 37,
          "current accepted PiP close pauses and preserves position in both engines/settings")
    check(service.audioRecoveryCalls == 0 && service.requestedSeeks.isEmpty && service.loads == 0,
          "close cannot seek, reload, or auto-resume")
    if mk { service.mediaKit!.outputRestoreCompletions[0](true); DispatchQueue.main.advance() }
    check(service.audioRecoveryCalls == 0, "late inline output-ready cannot revive closed playback")
  }
  for playing in [false, true] {
    for stopFirst in [false, true] {
      let service = fresh(); let controller = mk ? acceptedMKPiP(service) : acceptedAVPiP(service)
      if !playing { service.pause() }
      let token = UUID()
      if stopFirst { service.willStopPiP(controller) }
      check(service.beginPiPRestore(controller, token: token), "owned restore accepted")
      if !stopFirst { service.willStopPiP(controller) }
      service.completePiPRestore(controller, token: token, restored: true)
      service.player.pause() // AVKit technical pause while its stop animation ends.
      if !mk { service.player.rate = playing ? 1 : 0 } // Native restore before didStop.
      controller.isPictureInPictureActive = false; service.terminal(controller)
      if mk { service.mediaKit!.outputRestoreCompletions[0](true); DispatchQueue.main.advance() }
      check(service.wantsPlayback == playing && service.audioRecoveryCalls == (mk && playing ? 1 : 0),
            "restore preserves latest playing/paused intent for both callback orders and engines")
    }
  }
  let service = fresh(); let controller = mk ? acceptedMKPiP(service) : acceptedAVPiP(service)
  let oldToken = UUID(); let newToken = UUID()
  check(service.beginPiPRestore(controller, token: oldToken), "first restore accepted")
  service.completePiPRestore(controller, token: oldToken, restored: false)
  check(service.pipPlaybackSession?.restoreToken == nil, "failed or cancelled restore cannot mark later X as restoration")
  check(service.beginPiPRestore(controller, token: newToken), "second restore accepted")
  service.completePiPRestore(controller, token: oldToken, restored: false)
  check(service.pipPlaybackSession?.restoreToken == newToken, "late old restore result cannot cancel newer restore")
  service.completePiPRestore(controller, token: newToken, restored: false)
  service.willStopPiP(controller); controller.isPictureInPictureActive = false; service.terminal(controller)
  check(!service.wantsPlayback, "X after failed/expired restore pauses")
}
for reason in [AVPlayer.RateDidChangeReason.appBackgrounded, .audioSessionInterrupted, .setRateFailed] {
  let service = fresh(); _ = acceptedAVPiP(service)
  service.player.pause(); service.player.timeControlStatus = .paused
  service.queuePiPTransport(reason: reason)()
  check(service.wantsPlayback, "background/interruption/rate-failure notification is not a user pause")
}
for gate in 0..<12 {
  let service = fresh(); let controller = acceptedAVPiP(service)
  let event = service.queuePiPTransport()
  service.player.pause(); service.player.timeControlStatus = .paused
  switch gate {
  case 0: service.avPlayerTransportMutationDepth = 1
  case 1: service.isSeeking = true
  case 2: service.scrubbing = true
  case 3: service.interrupted = true
  case 4: service.loading = true
  case 5: service.audioRecoveryPending = true
  case 6: service.controlBusy = true
  case 7: service.trackSelection = "audio"
  case 8: service.replayOperation = 9
  case 9: service.position = service.duration
  case 10: service.willStopPiP(controller)
  default: _ = service.beginPiPRestore(controller, token: UUID())
  }
  event()
  check(service.wantsPlayback == (gate < 10), "technical app pauses are excluded while AVKit transitions only mirror actual state")
  check(service.audioRecoveryCalls == 0 && service.pauses == 0,
        "transport mirror never calls engine play/pause, including pre-callback technical pauses")
}
do {
  let service = fresh(); let controller = acceptedAVPiP(service)
  let event = service.queuePiPTransport()
  service.player.pause(); service.player.timeControlStatus = .paused; event()
  check(!service.wantsPlayback, "AV PiP pause updates the user's playback intent")
  let token = UUID(); _ = service.beginPiPRestore(controller, token: token)
  service.completePiPRestore(controller, token: token, restored: true)
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(!service.wantsPlayback && service.audioRecoveryCalls == 0, "restoring system-paused AV PiP stays paused")
}
do {
  let service = fresh(); let controller = acceptedAVPiP(service)
  service.player.pause(); service.player.timeControlStatus = .paused; service.queuePiPTransport()()
  service.player.rate = 1; service.player.timeControlStatus = .waitingToPlayAtSpecifiedRate
  service.queuePiPTransport()()
  check(service.wantsPlayback, "waiting transport retains its requested nonzero play rate")
  service.player.rate = 0; service.queuePiPTransport()()
  check(!service.wantsPlayback, "explicit rate-zero pause wins even before waiting status changes")
  service.play()
  let token = UUID(); _ = service.beginPiPRestore(controller, token: token)
  service.pause(); service.player.pause()
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(!service.wantsPlayback, "a newer explicit pause during restore wins")
}
for newerPlaying in [false, true] {
  let service = fresh(); _ = acceptedAVPiP(service)
  let oldNotification = service.queuePiPTransport()
  if newerPlaying { service.pause(); service.play() } else { service.pause() }
  oldNotification()
  check(service.wantsPlayback == newerPlaying, "queued same-session notification samples latest transport and cannot replay an older intent")
}
for mutation in 0..<4 {
  let service = fresh(); let controller = acceptedAVPiP(service)
  let stale = service.queuePiPTransport()
  switch mutation {
  case 0: service.generation += 1
  case 1: service.installIdentity()
  case 2: service.pip = AVPictureInPictureController(playerLayer: service.surface!.videoLayer)
  default:
    controller.isPictureInPictureActive = false; service.terminal(controller)
    service.play(); _ = acceptedAVPiP(service)
  }
  service.player.pause(); service.player.timeControlStatus = .paused
  service.wantsPlayback = true; stale()
  check(service.wantsPlayback, "captured generation/item/controller/session fences reject delayed old transport callbacks")
}
for failed in [false, true] {
  let service = fresh(); let controller = service.request()
  if failed { service.finishAVPlayerPiP(controller, terminal: .failedToStart) }
  else { service.finishAVPlayerPiP(controller, terminal: .didStop) }
  check(service.wantsPlayback, "unaccepted start terminal is not an X close")
}
do {
  let service = fresh(); let controller = acceptedAVPiP(service)
  service.loadLatest("new.mp4", autoplay: true)
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(service.wantsPlayback && service.loadedPaths == ["new.mp4"], "accepted old PiP replacement never pauses the new media")
}

for reasonValue: Any in [AVPlayer.RateDidChangeReason.setRateCalled.rawValue,
                         AVPlayer.RateDidChangeReason.setRateCalled] {
  let service = fresh(); _ = acceptedAVPiP(service)
  service.player.pause(); service.player.timeControlStatus = .paused
  NotificationCenter.default.post(name: AVPlayer.rateDidChangeNotification, object: service.player,
    userInfo: [AVPlayer.rateDidChangeReasonKey: reasonValue])
  check(!service.wantsPlayback, "registered production notification adapter accepts native typed and Objective-C string reasons")
}

for initiallyPlaying in [false, true] {
  let service = fresh()
  var controller: AVPictureInPictureController? = acceptedAVPiP(service)
  weak var releasedController = controller
  let mirror = service.queuePiPTransport()
  if !initiallyPlaying { service.player.pause(); mirror() }
  // Deliberately model AVKit's technical pause before ANY stop/restore callback.
  service.player.pause(); mirror()
  check(!service.wantsPlayback && service.audioRecoveryCalls == 0 && service.pauses == 0,
        "early AVKit technical pause only mirrors state, never commands playback")
  let token = UUID(); _ = service.beginPiPRestore(controller!, token: token)
  service.completePiPRestore(controller!, token: token, restored: true)
  controller!.isPictureInPictureActive = false; service.terminal(controller!)
  controller = nil
  // In production the old controller can deallocate here; the mirror owns no strong reference.
  check(releasedController == nil, "inline follow does not retain a terminal AVKit controller")
  check(service.audioRecoveryCalls == 0 && service.pauses == 0,
        "normal restore terminal never forces pause or resume")
  service.player.rate = initiallyPlaying ? 1 : 0 // AVKit completes native transport restoration.
  mirror()
  check(service.wantsPlayback == initiallyPlaying && service.player.rate == (initiallyPlaying ? 1 : 0),
        "late native restore is reflected after controller release without influencing it")
  service.pause(); service.player.rate = 1; mirror()
  check(!service.wantsPlayback, "new explicit app pause ends inline follow and rejects delayed old mirror")
}

do {
  let service = fresh(); let controller = acceptedAVPiP(service)
  let oldMirror = service.queuePiPTransport(); let token = UUID()
  _ = service.beginPiPRestore(controller, token: token)
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(service.pipPlaybackSession?.inline == true, "normal restore owns an item-scoped inline mirror")
  service.loadLatest("replacement.mp4")
  check(service.pipPlaybackSession == nil && service.pipTransportObservation == nil,
        "media replacement explicitly releases the old inline mirror and observer")
  oldMirror()
  check(service.wantsPlayback && service.loadedPaths == ["replacement.mp4"],
        "released mirror cannot change new media playback")
}

// Real delegate method bodies with deterministic bridge/UI callbacks.
do {
  let service = fresh(); let controller = acceptedAVPiP(service)
  let bridge = PiPBridgeReviewHost(service)
  var completed: [Bool] = []
  bridge.pictureInPictureController(controller, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { completed.append($0) })
  let currentToken = bridge.pipRestoreToken
  let staleController = AVPictureInPictureController(playerLayer: VideoLayer())!
  var staleCompleted: [Bool] = []
  bridge.pictureInPictureController(staleController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { staleCompleted.append($0) })
  check(staleCompleted == [false] && completed.isEmpty && bridge.pipRestoreToken == currentToken,
        "late stale restore rejects only its own completion and cannot cancel current UI restoration")
  bridge.acknowledgeRestore(true)
  check(completed == [true], "valid restored UI completes exactly once")
  bridge.pictureInPictureControllerWillStopPictureInPicture(controller)
  controller.isPictureInPictureActive = false
  bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
  check(service.wantsPlayback && service.audioRecoveryCalls == 0,
        "actual delegate restore/didStop leaves native transport untouched")
  DispatchQueue.main.advance(5)
  check(completed == [true], "old restore timeout cannot complete an already-acknowledged request")
}
for failure in 0..<3 {
  let service = fresh(); let controller = acceptedAVPiP(service)
  let bridge = PiPBridgeReviewHost(service); var completed: [Bool] = []
  if failure == 0 { bridge.sink = nil }
  bridge.pictureInPictureController(controller, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler: { completed.append($0) })
  if failure == 1 { DispatchQueue.main.advance(5) }
  if failure == 2 { bridge.acknowledgeRestore(false) }
  check(completed == [false] && service.pipPlaybackSession?.restoreToken == nil,
        "missing UI, timeout, and navigation cancellation clear matching restore intent")
  controller.isPictureInPictureActive = false
  bridge.pictureInPictureControllerDidStopPictureInPicture(controller)
  check(!service.wantsPlayback, "actual delegate X after failed restore does not resume")
}
do {
  let service = fresh(); let controller = acceptedMKPiP(service)
  let bridge = PiPBridgeReviewHost(service)
  controller.isPictureInPictureActive = false
  bridge.pictureInPictureController(controller, failedToStartPictureInPictureWithError: LibraryFailure.app("review failure"))
  check(service.wantsPlayback, "typed sample-buffer failedToStart cannot be mistaken for a user close")
}
do {
  let service = fresh(); _ = acceptedAVPiP(service)
  let delayedInternal = service.queuePiPTransport()
  service.isSeeking = true; service.player.pause()
  delayedInternal(); check(service.wantsPlayback, "queued internal seek pause does not erase intent")
  service.isSeeking = false; service.play()
  delayedInternal(); check(service.wantsPlayback, "late internal rate notification observes resumed output, not its obsolete pause")
}

// Background MK output restoration regression scenarios. These exercise the
// extracted production methods and lifecycle body, never native GPU behavior.
for state in [UIApplication.State.inactive, .background] {
  for background in [false, true] {
    let service = fresh(); service.background = background
    let controller = acceptedMKPiP(service); let engine = service.mediaKit!
    UIApplication.shared.applicationState = state; service.inBackground = true
    service.willStopPiP(controller)
    controller.isPictureInPictureActive = false; service.terminal(controller)
    check(engine.restoreCalls == 0 && service.waiting && !service.wantsPlayback,
          "MK close outside active foreground defers output and preserves close pause")
    check(service.mediaKitPiPRestoreTimeout == nil && service.mediaKitPiPRestoreRequestID == nil,
          "waiting for foreground has no restore watchdog or in-flight command")
    check(service.busy, "deferred output remains visibly busy for a new PiP request")
    do {
      try service.startPiP(delegate: service.ownedDelegate, requestID: "repeat-while-deferred")
      check(false, "pending output must reject a second handoff")
    } catch {
      check(!service.mediaKitPiPPreparing && service.mediaKitPiPRequestID == nil,
            "repeat PiP during deferred restoration cannot take another rendering owner")
    }
    DispatchQueue.main.advance(120)
    service.resumeDeferredMediaKitVideoOutput(engineID: engine.id)
    check(engine.restoreCalls == 0 && service.loads == 0 && !service.seekFault,
          "inactive/background waiting never creates output or spends recovery timeout")
    UIApplication.shared.applicationState = .active; service.inBackground = false
    service.resumeDeferredMediaKitVideoOutput()
    service.resumeDeferredMediaKitVideoOutput(engineID: engine.id)
    check(engine.restoreCalls == 1 && service.waiting,
          "both foreground notifications issue exactly one MK restoration")
    engine.outputRestoreCompletions[0](true); DispatchQueue.main.advance()
    engine.outputRestoreCompletions[0](true); DispatchQueue.main.advance()
    check(!service.waiting && !service.wantsPlayback && service.audioRecoveryCalls == 0,
          "foreground output success and duplicate result cannot resume a closed PiP")
  }
}
for newerIntent in 0..<5 {
  let service = fresh(); let controller = acceptedMKPiP(service); let engine = service.mediaKit!
  let token = UUID(); check(service.beginPiPRestore(controller, token: token), "MK UI restore accepted")
  service.completePiPRestore(controller, token: token, restored: true)
  UIApplication.shared.applicationState = .background; service.inBackground = true
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(service.waiting && service.wantsPlayback && engine.restoreCalls == 0,
        "background MK UI restore retains live playback intent without output creation")
  switch newerIntent {
  case 1: service.pause()
  case 2: service.playerDismissed()
  case 3: service.interrupted = true
  case 4: service.enterBackground(enabled: false)
  default: break
  }
  UIApplication.shared.applicationState = .active; service.inBackground = false
  service.resumeDeferredMediaKitVideoOutput(); engine.outputRestoreCompletions[0](true)
  DispatchQueue.main.advance()
  check(!service.waiting && service.audioRecoveryCalls == (newerIntent == 0 ? 1 : 0),
        "MK UI restoration respects newer pause, page dismissal, interruption and background-off")
  check(service.loads == 0 && service.requestedSeeks.isEmpty,
        "healthy foreground reconstruction neither reloads nor seeks")
}
for oldSuccess in [false, true] {
  let service = fresh(); let controller = acceptedMKPiP(service); let engine = service.mediaKit!
  controller.isPictureInPictureActive = false; service.terminal(controller)
  let oldID = engine.outputRestoreRequestIDs[0]
  let oldTimeout = service.mediaKitPiPRestoreTimeout!
  UIApplication.shared.applicationState = .inactive
  service.resignDuringOutputRestore()
  check(service.deferredMediaKitVideoRestore?.requestID == oldID && oldTimeout.cancelled,
        "willResignActive immediately defers in-flight output and cancels its watchdog")
  check(service.deferMediaKitVideoOutput(engineID: engine.id, requestID: oldID),
        "Dart duplicate deferral after native lifecycle notification is idempotently accepted")
  DispatchQueue.main.advance(120)
  check(service.loads == 0 && engine.restoreCalls == 1 && service.waiting,
        "suspension time cannot become a foreground-recovery failure")
  UIApplication.shared.applicationState = .active; service.inBackground = false
  service.resumeDeferredMediaKitVideoOutput(engineID: engine.id)
  let newID = engine.outputRestoreRequestIDs[1]
  check(newID != oldID && service.mediaKitPiPRestoreRequestID == newID,
        "resumed same-engine restoration has a fresh attempt identity")
  check(!service.deferMediaKitVideoOutput(engineID: engine.id, requestID: oldID),
        "late old deferral cannot consume a newer foreground attempt")
  engine.outputRestoreCompletions[0](oldSuccess); oldTimeout.work(); DispatchQueue.main.advance()
  check(service.mediaKitPiPRestoreRequestID == newID && service.waiting && service.loads == 0,
        "old success, failure and even forced old watchdog body cannot complete current attempt")
  engine.outputRestoreCompletions[1](true); DispatchQueue.main.advance()
  check(!service.waiting && engine.restoreCalls == 2 && service.loads == 0,
        "only matching latest output result ends restoration")
}
for obsolete in 0..<4 {
  let service = fresh(); let controller = acceptedMKPiP(service); let engine = service.mediaKit!
  UIApplication.shared.applicationState = .background
  controller.isPictureInPictureActive = false; service.terminal(controller)
  switch obsolete {
  case 0: service.generation += 1
  case 1: service.mediaKit = ReviewEngine()
  case 2: service.loadLatest("new.mp4", autoplay: false)
  default: service.clearLatest()
  }
  UIApplication.shared.applicationState = .active; service.inBackground = false
  service.resumeDeferredMediaKitVideoOutput(engineID: engine.id)
  check(service.deferredMediaKitVideoRestore == nil && engine.restoreCalls == 0,
        "new generation, engine, selected item or cleared queue discards obsolete output intent")
}
do {
  let service = fresh(); let controller = acceptedMKPiP(service); let engine = service.mediaKit!
  controller.isPictureInPictureActive = false; service.terminal(controller)
  let oldID = engine.outputRestoreRequestIDs[0]
  service.failPlayback()
  check(!service.deferMediaKitVideoOutput(engineID: engine.id, requestID: nil),
        "late rollback without attempt ID cannot resurrect a failed same-engine session")
  check(!service.deferMediaKitVideoOutput(engineID: engine.id, requestID: oldID),
        "failed generation also rejects its old exact restoration attempt")
  engine.outputRestoreCompletions[0](true); DispatchQueue.main.advance()
  check(!service.waiting && !service.wantsPlayback && service.seekFault,
        "late output result after failure preserves terminal playback state")
}

// PiP diagnostics regression scenarios execute production logging methods.
// Real background entry; our deterministic main scheduler is drained only
// after this worker finishes, so the test has no concurrent array access.
func offMainDiagnostic(_ work: @escaping () -> Void) {
  let finished = DispatchSemaphore(value: 0)
  let worker = Thread { work(); finished.signal() }
  worker.start(); finished.wait()
  while !worker.isFinished { Thread.sleep(forTimeInterval: 0.001) }
}
do {
  let service = fresh()
  let controller = AVPictureInPictureController(playerLayer: VideoLayer())!
  let key = ObjectIdentifier(controller)
  service.pip = controller
  service.avPlayerPiPTraceRequests = [(key, UUID(), service.generation)]
  offMainDiagnostic { [weak service, weak controller] in
    guard let service, let controller else { return }
    service.recordPiPDelegateEntry("willStart", controller: controller)
    service.recordAVPlayerPiPEvent("delegate willStart", controller: controller, includeSource: true)
  }
  check(service.lifecycleEvents.isEmpty && controller.playerLayerReads == 0,
        "off-main raw/detailed diagnostics do not read playerLayer or mutate log arrays")
  check(DispatchQueue.main.scheduled.count == 1 && controller.starts == 0 && controller.stops == 0,
        "only raw diagnostic recording is queued; no PiP control work is added")
  service.pip = nil
  service.retiringPiP[key] = (controller, nil, true)
  DispatchQueue.main.now = 4
  DispatchQueue.main.advance()
  let line = service.lifecycleEvents.last!
  check(line.contains("originMain=false") && line.contains("main=true") && line.contains("entryUptime=0.000"),
        "deferred recording preserves the real off-main origin and earlier entry time")
  check(line.contains("owner=retiring") && line.contains("ownershipSample=deferred")
        && line.contains("avDetails=skippedOffMain"),
        "changed ownership is explicitly observed at deferred recording time")
  check(controller.playerLayerReads == 0, "deferred raw entry still never reads playerLayer")
}
do {
  let service = fresh()
  var controller: AVPictureInPictureController? = AVPictureInPictureController(playerLayer: VideoLayer())!
  weak var weakController = controller
  let key = ObjectIdentifier(controller!)
  service.avPlayerPiPTraceRequests = [(key, UUID(), service.generation)]
  offMainDiagnostic { [weak service, weak controller] in
    if let service, let controller { service.recordPiPDelegateEntry("didStop", controller: controller) }
  }
  controller = nil
  check(weakController == nil, "queued raw diagnostic does not extend controller lifetime")
  DispatchQueue.main.advance()
  let line = service.lifecycleEvents.last!
  check(line.contains("controller=\(key)") && line.contains("owner=unknown") && line.contains("objectAlive=false")
        && line.contains("request=unknown"),
        "released controller retains its arrival ID without inheriting historical ownership")
}
do {
  var service: PresentationReviewHost? = fresh()
  weak var weakService = service
  let controller = AVPictureInPictureController(playerLayer: VideoLayer())!
  offMainDiagnostic { [weak service, weak controller] in
    if let service, let controller { service.recordPiPDelegateEntry("restore", controller: controller) }
  }
  service = nil
  check(weakService == nil, "queued raw diagnostic does not extend service lifetime")
  DispatchQueue.main.advance()
  check(DispatchQueue.main.scheduled.isEmpty, "released service safely drops its deferred diagnostic")
}
do {
  let service = fresh(); let controller = service.prepare(ready: true)
  controller.onStart = { [weak service, weak controller] in
    guard let service, let controller else { return }
    check(service.pipStartIssued, "issued flag is set before a synchronous callback")
    service.recordPiPDelegateEntry("didStop", controller: controller)
    service.terminal(controller)
    service.generation += 1
    service.surface = PlayerSurface()
    service.avPlayerPiPTraceRequests.removeAll()
    DispatchQueue.main.now += 0.025
  }
  try! service.startPiP(delegate: service.ownedDelegate)
  DispatchQueue.main.advance()
  let events = service.lifecycleEvents
  let before = events.first { $0.contains("AVPiP start call before ") }!
  let after = events.first { $0.contains("AVPiP start call returned ") }!
  let beforeTrace = before.components(separatedBy: "AVPiP start call before ")[1].components(separatedBy: " main=")[0]
  let afterTrace = after.components(separatedBy: "AVPiP start call returned ")[1].components(separatedBy: " main=")[0]
  check(beforeTrace == afterTrace, "paired immutable identities survive synchronous release and generation change")
  check(after.contains("main=true elapsedMs=25.000"), "return log includes measured call duration and main thread")
  check(events.firstIndex(of: before)! < events.firstIndex(where: { $0.contains("PiP delegate entry didStop") })!
        && events.firstIndex(where: { $0.contains("PiP delegate entry didStop") })! < events.firstIndex(of: after)!,
        "raw callback is ordered between call entry and return")
  check(events.firstIndex(where: { $0.contains("AVPiP start issued") })! < events.firstIndex(of: before)!,
        "issued diagnostic remains before AVKit start")
  check(events.contains { $0.contains("source after start") && $0.contains("surface=nil") },
        "post-callback snapshot does not misattribute an old layer to a replacement surface")
  check(controller.starts == 1 && controller.stops == 0 && service.pip !== controller,
        "diagnostics neither repeat start nor manufacture a stop after synchronous terminal")
}
for ownership in ["currentAV", "currentMK", "retiringAV", "retiringMK", "unknown"] {
  let service = fresh()
  let controller = AVPictureInPictureController(playerLayer: VideoLayer())!
  let key = ObjectIdentifier(controller)
  // A historical identity alone must never classify unknown or MK as AV.
  service.avPlayerPiPTraceRequests = [(key, UUID(), service.generation)]
  switch ownership {
  case "currentAV": service.pip = controller
  case "currentMK": service.mediaKitPiP = MediaKitPiPRenderer(controller)
  case "retiringAV": service.retiringPiP[key] = (controller, nil, true)
  case "retiringMK": service.retiringPiP[key] = (controller, MediaKitPiPRenderer(controller), true)
  default: break
  }
  for event in ["willStart", "didStart", "failedToStart", "willStop", "didStop", "restore"] {
    let oldCount = service.lifecycleEvents.count
    service.recordPiPDelegateEntry(event, controller: controller,
      error: NSError(domain: "AVKitErrorDomain", code: -1,
        userInfo: [NSLocalizedDescriptionKey: "PRIVATE_MEDIA_FILENAME"]))
    check(service.lifecycleEvents.count == oldCount + 1, "every delegate entry is logged before filtering")
    let line = service.lifecycleEvents.last!
    let expectedOwner = ownership.hasPrefix("current") ? "current" : ownership.hasPrefix("retiring") ? "retiring" : "unknown"
    check(line.contains("owner=\(expectedOwner)") && line.contains("controller=\(key)") && line.contains("main=true"),
          "delegate entry identifies live owner, controller and thread")
    check(!line.contains("PRIVATE_MEDIA_FILENAME"), "raw callback diagnostic omits localized private error text")
    check(controller.playerLayerReads == 0, "raw callback diagnostic never accesses playerLayer")
  }
  if ownership == "unknown" || ownership.hasSuffix("MK") {
    service.recordAVPlayerPiPEvent("filtered probe", controller: controller, includeSource: true)
    check(controller.playerLayerReads == 0, "detailed AV diagnostic also excludes unknown and MK controllers")
    check(service.lifecycleEvents.last!.contains("request=unknown"), "unknown and MK cannot inherit AV request history")
  }
}
do {
  let service = fresh(); service.repair()
  let source = service.surface!
  let parent = UIView(); parent.isHidden = true; parent.clipsToBounds = true
  parent.bounds = CGRect(x: 0, y: 0, width: 100, height: 80)
  source.superview = parent
  let snapshot = service.sourceSnapshot(source.videoLayer)
  for field in ["sourceLayer=", "sourcePlayer=", "sourceItem=", "layerBounds=", "layerFrame=", "videoRect=",
                "layerHidden=", "layerOpacity=", "surfaceHidden=", "surfaceAlpha=", "window=", "sceneState=",
                "audioCategory=", "audioMode=", "audioOptions=", "audioInputs=", "audioOutputs="] {
    check(snapshot.contains(field), "source snapshot contains \(field)")
  }
  check(snapshot.contains("clippedIntersection=[0.0,0.0,100.0,80.0]") && snapshot.contains("visibleIntersection=null"),
        "snapshot reports ancestor clipping and hidden visibility")
  check(!snapshot.contains("PRIVATE_DEVICE_NAME") && !snapshot.contains(service.currentPath!),
        "snapshot contains neither route device names nor media filenames")
  var ancestor = parent
  for _ in 0..<10 { let next = UIView(); ancestor.superview = next; ancestor = next }
  let bounded = service.sourceSnapshot(source.videoLayer)
  check(bounded.count <= 2800 && bounded.contains("ancestorsTruncated=true") && bounded.contains("visibleIntersection=unknown"),
        "deep ancestry has bounded work and explicitly unknown visibility")
  let disconnected = service.sourceSnapshot(VideoLayer())
  check(disconnected.contains("surface=nil") && !disconnected.contains("visibleIntersection="),
        "unowned layer does not reuse the current surface's geometry")
  check(service.sourceSnapshot(nil).contains("sourceSnapshot=released"), "released weak source remains explicit")
}
do {
  let service = fresh(); _ = service.request()
  DispatchQueue.main.advance(8)
  check(service.lifecycleEvents.contains { $0.contains("AVPiP requested") && $0.contains("audioCategory=") },
        "manual request includes source and audio snapshot")
  check(service.lifecycleEvents.contains { $0.contains("phase watchdog fired") && $0.contains("sourceLayer=") && $0.contains("audioCategory=") },
        "activation timeout includes a source snapshot before cleanup")
}
print("Presentation production policy/method harness: \(assertions) assertions passed")
print("Scope: extracted Swift decisions and deterministic callbacks; Apple SDK / device rendering not exercised.")
