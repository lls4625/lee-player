import Foundation

// PRODUCTION_POLICY

// Plain deterministic collaborators, not subclasses or mocks of Apple SDK
// classes. Production method bodies are inserted unchanged by the runner.
enum ReviewStatus: Int { case unknown = 0, readyToPlay = 1, failed = 2 }
final class AVPlayerItem { var status = ReviewStatus.readyToPlay }
final class AVPlayer {
  enum TimeControlStatus: Int { case paused, waitingToPlayAtSpecifiedRate, playing }
  var timeControlStatus = TimeControlStatus.paused
  var currentItem: AVPlayerItem?
  var status = ReviewStatus.readyToPlay
  var isMuted = false
  var rate: Float = 0 { didSet { rateChanged?() } }
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
final class VideoLayer {
  var isReadyForDisplay = true
  var bounds = CGRect(x: 0, y: 0, width: 320, height: 180)
  var player: AVPlayer?
  var isHidden = false
  var videoGravity = ReviewGravity.resizeAspect
}
final class ReviewCaption { var text: String?; var isHidden = true }
final class PlayerSurface {
  var window: ReviewWindow? = ReviewWindow()
  var videoLayer = VideoLayer()
  var isolatedLayers: [VideoLayer] = []
  func isolateVideoLayer(_ retained: VideoLayer) {
    guard videoLayer === retained else { return }
    isolatedLayers.append(retained); videoLayer = VideoLayer()
  }
  func releaseIsolatedVideoLayer(_ retained: VideoLayer) {
    isolatedLayers.removeAll { $0 === retained }
  }
  let caption = ReviewCaption()
  var onLayout: (() -> Void)?
}
final class ReviewWindow {}
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
  // AVPictureInPictureController.playerLayer is non-optional in Apple's Swift
  // interface. Only ContentSource.playerLayer is optional.
  let playerLayer: VideoLayer
  var delegate: AVPictureInPictureControllerDelegate?
  var canStartPictureInPictureAutomaticallyFromInline = true
  var isPictureInPictureActive = false
  var isPictureInPictureSuspended = false
  var isPictureInPicturePossible = false { didSet { changed?() } }
  var changed: (() -> Void)?
  var starts = 0
  var onStop: (() -> Void)?
  var stops = 0
  init?(playerLayer: VideoLayer) {
    self.playerLayer = playerLayer
    isPictureInPicturePossible = Self.initialPossible
  }
  func startPictureInPicture() { starts += 1 }
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
  func restoreVideoOutput(completion: @escaping (Bool) -> Void) {
    restoreCalls += 1; outputRestoreCompletions.append(completion)
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
  func cancelIntroDetection() {}
  func cancelSeeks() {}
  func pauseEngine() { pauses += 1; player.pause(); enginePlaying = false }
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
    audioRecoveryCalls += 1
    player.rate = wantsPlayback && !interrupted && playbackEnvironmentAllowsPlayback ? 1 : 0
  }

  func performLoad(resume: Bool, autoplay: Bool) {
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
    clears += 1; installedAVPlayerItem = nil; player.currentItem = nil; mediaKit = nil; loading = false
  }
  func repair() { ensureAVPlayerPresentation(reason: "review") }
  func rebuildResetPlayer() { replaceFailedPlayerIfNeeded() }
  func initialAttach() { attachAVPlayerPresentationIfAllowed(reason: "initial load") }
  func discard() { discardAVPlayerPiP() }
  func discardRenderer() { discardMediaKitPiP() }
  func reconcile() { reconcileAVPlayerPresentation(reason: "review") }
  func request(ready: Bool = false) -> AVPictureInPictureController {
    AVPictureInPictureController.initialPossible = ready
    try! startPiP(delegate: ownedDelegate)
    return pip!
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
  UIApplication.shared.applicationState = .active
  return PresentationReviewHost()
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
  check(s.request().starts == 0, "AV entry is available after confirmed terminal")
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

// Ordinary playback, repair, page recreation, inactive and background never
// create any PiP controller. This is the product invariant, not a fake SDK claim.
do {
  let service = fresh(); let player = service.player; let item = player.currentItem
  service.repair(); service.repair()
  check(service.surface?.videoLayer.player === player && service.pip == nil,
        "ordinary repair binds only the player layer")
  for state in [UIApplication.State.inactive, .background, .active] {
    UIApplication.shared.applicationState = state; service.reconcile()
    check(service.pip == nil && service.surface?.videoLayer.player === player,
          "ordinary app transitions preserve layer with zero controllers")
  }
  service.attachSurface(PlayerSurface())
  check(service.pipCreations == 0 && player.currentItem === item,
        "surface replacement retains media without preparing PiP")
}
do {
  let service = fresh(); service.installedAVPlayerItem = nil; service.player.currentItem = nil
  service.repair()
  check(service.surface?.videoLayer.player == nil, "ordinary repair requires valid item")
  service.initialAttach()
  check(service.surface?.videoLayer.player === service.player && service.pip == nil,
        "initial load may bind before async install without a controller")
  service.installIdentity(); service.repair()
  check(service.pip == nil && service.pipCreations == 0, "item ready still does not prepare PiP")
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
  let service = fresh(); service.repair(); let controller = service.request()
  check(service.busy && service.pipCreations == 1 && controller.starts == 0,
        "explicit cold request publishes preparation without synchronous rejection")
  DispatchQueue.main.advance()
  check(controller.starts == 0, "not possible keeps bounded observation")
  do { try service.startPiP(delegate: service.ownedDelegate); check(false, "repeat must reject") }
  catch { check(service.pipCreations == 1, "repeat cannot create another controller") }
  controller.isPictureInPicturePossible = true; DispatchQueue.main.advance()
  check(controller.starts == 1 && service.pipStartIssued, "possible KVO issues one start")
  controller.isPictureInPicturePossible = false; controller.isPictureInPicturePossible = true
  DispatchQueue.main.advance()
  check(controller.starts == 1, "repeat readiness cannot start twice")
  controller.isPictureInPictureActive = true; service.didStartAVPlayerPiP(controller)
  DispatchQueue.main.fireAll()
  check(service.pip === controller && service.notices.isEmpty, "successful activation cancels watchdog")
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(service.pip == nil && !service.busy && service.pipCreations == 1,
        "normal stop releases controller without automatic reprepare")
  service.repair(); check(service.pip == nil, "post-stop repair remains controller free")
}
for state in [UIApplication.State.inactive, .background] {
  let service = fresh(); service.repair(); let controller = service.request()
  UIApplication.shared.applicationState = state
  service.reconcile(); controller.isPictureInPicturePossible = true; DispatchQueue.main.advance()
  check(controller.starts == 1 && service.avPlayerPiPAuthorized,
        "tap then immediate Home/inactive must retain the authorized request")
  check(service.surface?.videoLayer.player === service.player,
        "manual handoff keeps source attached")
  check(BackgroundPlaybackPolicy.permitsPlayback(backgroundEnabled: false, inBackground: true,
    session: service.generation, pipSession: service.manualPiPSession, pipActive: false,
    pipDeadline: service.manualPiPDeadline, now: DispatchQueue.main.now),
    "manual request allows bounded background startup when preference is off")
}
do {
  let service = fresh(); service.repair(); let old = service.request()
  DispatchQueue.main.advance(5)
  check(service.pip == nil && !service.busy && service.retiringPiP.isEmpty,
        "never-issued preparation timeout releases immediately and unblocks button")
  check(old.delegate == nil && service.notices.isEmpty && !service.lastDiagnostic.isEmpty, "timeout is diagnostic-only; healthy playback has no popup")
  let next = service.request(ready: true); DispatchQueue.main.advance()
  old.isPictureInPicturePossible = true; service.terminal(old)
  check(next.starts == 1 && service.pip === next, "old KVO/terminal cannot affect new request")
}
do {
  let service = fresh(); service.repair(); let controller = service.request()
  UIApplication.shared.applicationState = .background
  // The bridge observes all starts for retirement before authorization check.
  _ = service.rejectRetiringPiPStart(controller)
  check(!service.rejectUnauthorizedAVPlayerPiPStart(controller),
        "AVKit observed start for explicit request remains authorized before queued KVO")
  check(service.presentationOwned && !service.pipStartIssued,
        "observed-only start owns source before isActive or issued")
  controller.isPictureInPicturePossible = true; DispatchQueue.main.advance()
  check(controller.starts == 0, "observed start prevents duplicate explicit AVKit call")
  controller.isPictureInPictureActive = true; service.didStartAVPlayerPiP(controller)
  DispatchQueue.main.fireAll()
  check(service.pip === controller && service.notices.isEmpty, "observed authorized startup stays active")
  controller.isPictureInPictureActive = false; service.terminal(controller)
  check(service.pip == nil && !service.busy, "observed authorized terminal releases")
}
for observed in [false, true] {
  let service = fresh(); service.repair(); let controller = service.request()
  // Simulate a suspended main queue: monotonic time passes without watchdog delivery.
  DispatchQueue.main.now = 6
  if observed {
    _ = service.rejectRetiringPiPStart(controller)
    check(!service.rejectUnauthorizedAVPlayerPiPStart(controller), "current observed start stays authorized despite delayed main queue")
    check(service.retiringPiP.isEmpty, "clock expiry alone is not a new cancellation intent")
  } else {
    controller.isPictureInPicturePossible = true; DispatchQueue.main.advance()
    check(controller.starts == 0 && service.pip == nil, "expired queued KVO cannot issue start before watchdog")
  }
}
for mutation in 0..<4 {
  let service = fresh(); service.repair(); let controller = service.request()
  controller.isPictureInPicturePossible = true // queue KVO before cancellation/mutation
  switch mutation {
  case 0: service.cancel()
  case 1: service.generation += 1
  case 2: service.player.currentItem = AVPlayerItem()
  default: service.surface = PlayerSurface()
  }
  DispatchQueue.main.advance()
  check(controller.starts == 0 && service.pip == nil && !service.busy,
        "cancel/generation/item/layer supersession invalidates queued readiness")
  check(service.retiringPiP.isEmpty, "unissued cancellation never waits for impossible didStop")
}
do {
  let service = fresh(); service.repair(); _ = service.request()
  service.failPlayback(); DispatchQueue.main.fireAll()
  check(service.pip == nil && !service.busy && service.notices.isEmpty,
        "playback failure cancels preparation and stale timeout")
}
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance(); service.discard()
  check(service.retiringPiP.count == 1 && service.pip == nil, "issued inactive start awaits terminal")
  service.repair(); check(service.pip == nil && service.pipCreations == 1, "retirement prevents replacement controller")
  service.terminal(old)
  check(service.retiringPiP.isEmpty && service.pip == nil && !service.busy,
        "terminal restores only layer, never prebuilt controller")
  DispatchQueue.main.fireAll(); check(service.errorMessage.isEmpty, "old timer cannot fail terminal")
}
do {
  let service = fresh(); service.repair(); let old = service.request(ready: true)
  DispatchQueue.main.advance()
  old.onStop = { [weak service, weak old] in if let old { service?.terminal(old) } }
  service.discard()
  check(service.retiringPiP.isEmpty && service.pip == nil, "synchronous didStop clears without reprepare")
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
  check(service.pip == nil && service.loads == 0 && service.wantsPlayback,
        "late terminal keeps the original healthy player and latest playback intent")
}
do {
  let service = fresh(); service.repair(); let old = service.request()
  service.avPlayerPiPAuthorized = false
  check(service.rejectUnauthorizedAVPlayerPiPStart(old), "observed start without authorization rejected")
  check(service.retiringPiP.count == 1 && service.surface?.videoLayer.player === service.player,
        "willStart observed identity retained without detaching source")
  service.terminal(old)
  check(service.pip == nil && service.retiringPiP.isEmpty, "rejection terminal does not reprepare")
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
  check(service.loads == 1 && service.pip == nil && service.loadedAutoplay == [false],
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
print("Presentation production policy/method harness: \(assertions) assertions passed")
print("Scope: extracted Swift decisions and deterministic callbacks; Apple SDK / device rendering not exercised.")
