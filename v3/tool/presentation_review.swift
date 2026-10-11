import Foundation

// PRODUCTION_POLICY

// Plain deterministic collaborators, not subclasses or mocks of Apple SDK
// classes. Production method bodies are inserted unchanged by the runner.
enum ReviewStatus { case readyToPlay, unknown, failed }
final class AVPlayerItem { var status = ReviewStatus.readyToPlay }
final class AVPlayer {
  var currentItem: AVPlayerItem?
  var status = ReviewStatus.readyToPlay
}
enum ReviewGravity { case resizeAspect, resizeAspectFill, resize }
final class VideoLayer {
  var player: AVPlayer?
  var isHidden = false
  var videoGravity = ReviewGravity.resizeAspect
}
final class ReviewCaption { var text: String?; var isHidden = true }
final class PlayerSurface {
  let videoLayer = VideoLayer()
  let caption = ReviewCaption()
  var onLayout: (() -> Void)?
}
final class UIApplication {
  enum State: Int { case active, inactive, background }
  static let shared = UIApplication()
  var applicationState = State.active
}
protocol AVPictureInPictureControllerDelegate: AnyObject {}
final class ReviewDelegate: AVPictureInPictureControllerDelegate {}
final class NSKeyValueObservation { func invalidate() {} }
struct ReviewObservationOptions: OptionSet {
  let rawValue: Int
  static let initial = Self(rawValue: 1)
  static let new = Self(rawValue: 2)
}
final class AVPictureInPictureController {
  let playerLayer: VideoLayer
  var delegate: AVPictureInPictureControllerDelegate?
  var canStartPictureInPictureAutomaticallyFromInline = true
  var isPictureInPictureActive = false
  var isPictureInPicturePossible = true
  var onStop: (() -> Void)?
  var stops = 0
  init?(playerLayer: VideoLayer) { self.playerLayer = playerLayer }
  static func isPictureInPictureSupported() -> Bool { true }
  func stopPictureInPicture() { stops += 1; onStop?() }
  func observe<T>(_ keyPath: KeyPath<AVPictureInPictureController, T>,
                  options: ReviewObservationOptions,
                  change: (AVPictureInPictureController, Int) -> Void) -> NSKeyValueObservation {
    NSKeyValueObservation()
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
final class ReviewEngine { let id = "engine" }
enum DispatchQueue {
  static let main = Queue()
  final class Queue {
    var scheduled: [() -> Void] = []
    func async(execute work: () -> Void) { work() }
    func asyncAfter(deadline: DispatchTime, execute work: @escaping () -> Void) { scheduled.append(work) }
    func fireAll() { let work = scheduled; scheduled = []; work.forEach { $0() } }
  }
}

final class PresentationReviewHost {
  var player = AVPlayer()
  var surface: PlayerSurface? = PlayerSurface()
  var pip: AVPictureInPictureController?
  let ownedDelegate = ReviewDelegate()
  weak var pipDelegate: AVPictureInPictureControllerDelegate?
  var pipPossibleObservation: NSKeyValueObservation?
  var pipActivationTimeout: DispatchWorkItem?
  var pipStartIssued = false
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
  var observedPiPStarts: Set<ObjectIdentifier> = []
  var retiringPiPAbortCompletions: [ObjectIdentifier: (token: UUID, completion: (Bool) -> Void)] = [:]
  var pendingReplacement: (id: UUID, controller: AVPictureInPictureController,
    resume: Bool, autoplay: Bool, clearOnly: Bool, aborted: Bool)?
  var replacementTimeout: DispatchWorkItem?
  var fit = "fit"
  var subtitleText = ""
  var currentPath: String? = "a.mp4"
  var generation = 1
  var playbackOperation = 0
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
  var clears = 0
  var restores = 0
  var pauses = 0
  var pipActive: Bool { mediaKitPiP?.isActive ?? (pip?.isPictureInPictureActive == true) }
  init() { pipDelegate = ownedDelegate; installIdentity() }
  func installIdentity() {
    let item = AVPlayerItem()
    player.currentItem = item
    installedAVPlayerItem = (item, currentPath!, generation)
  }
  func publish() { publications += 1 }
  func revokeManualPiP(enforce: Bool = true) { avPlayerPiPAuthorized = false }
  func cancelAudioRecovery() {}
  func finishTrackSelection(_ message: String) {}
  func cancelIntroDetection() {}
  func cancelSeeks() {}
  func pauseEngine() { pauses += 1 }
  func restoreMediaKitVideoOutput() { restores += 1 }
  func performLoad(resume: Bool, autoplay: Bool) { loads += 1 }
  func clearPlaybackEnginesAfterMutation() {
    clears += 1; installedAVPlayerItem = nil; player.currentItem = nil; loading = false
  }
  func repair() { ensureAVPlayerPresentation(reason: "review") }
  func initialAttach() { attachAVPlayerPresentationIfAllowed(reason: "initial load") }
  func discard() { discardAVPlayerPiP() }
  func discardRenderer() { discardMediaKitPiP() }
  func confirmedBackgroundCleanup() { suspendAVPlayerPresentationForBackground() }
  func terminal(_ controller: AVPictureInPictureController) {
    // The bridge uses this same routing order; the Python runner checks wiring.
    if finishRetiringPiP(controller) { return }
    if pip === controller { finishAVPlayerPiP(controller) }
    else if mediaKitPiP?.controller === controller { finishMediaKitPiP(controller) }
  }
  // PRODUCTION_METHODS
}

var assertions = 0
func check(_ condition: @autoclosure () -> Bool, _ message: String) {
  assertions += 1
  if !condition() { fatalError(message) }
}
func fresh() -> PresentationReviewHost {
  DispatchQueue.main.scheduled = []
  UIApplication.shared.applicationState = .active
  return PresentationReviewHost()
}

// Exhaustive input matrices execute the actual production policy declaration.
for bits in 0..<128 {
  func bit(_ index: Int) -> Bool { bits & (1 << index) != 0 }
  check(AVPlayerPresentationPolicy.permitsForegroundRepair(active: bit(0), validItem: bit(1),
    hasSurface: bit(2), replacing: bit(3), starting: bit(4), pipActive: bit(5), retiring: bit(6))
      == (bits == 7), "foreground repair matrix")
}
for bits in 0..<64 {
  func bit(_ index: Int) -> Bool { bits & (1 << index) != 0 }
  check(AVPlayerPresentationPolicy.permitsBackgroundDetach(background: bit(0), replacing: bit(1),
    authorized: bit(2), starting: bit(3), pipActive: bit(4), retiring: bit(5)) == (bits == 1),
    "background detach matrix")
}
for bits in 0..<8 {
  let a = bits & 1 != 0, b = bits & 2 != 0, c = bits & 4 != 0
  check(AVPlayerPresentationPolicy.permitsAttachment(active: a, authorized: b, pipActive: c)
    == (bits != 0), "attachment preserves authorized/active handoff")
  check(AVPlayerPresentationPolicy.requiresTerminal(startIssued: a, startObserved: b, active: c)
    == (bits != 0), "retirement matrix")
}

do {
  let service = fresh(); let player = service.player; let item = player.currentItem
  service.repair(); let controller = service.pip
  service.repair()
  check(service.surface?.videoLayer.player === player && service.pip === controller,
        "ordinary repeated repair retains healthy binding/controller")
  check(service.pipCreations == 1 && player.currentItem === item, "repair never rebuilds player/item")
  UIApplication.shared.applicationState = .inactive
  service.repair(); service.confirmedBackgroundCleanup()
  check(service.pip === controller && service.surface?.videoLayer.player === player,
        "inactive state must not detach or discard prepared PiP")
  UIApplication.shared.applicationState = .active
  service.surface = PlayerSurface(); service.repair()
  check(service.surface?.videoLayer.player === player && service.pip !== controller,
        "a new surface gets the current player and its own prepared controller")
  check(service.pipCreations == 2 && player.currentItem === item, "surface replacement retains media")
}
do {
  let service = fresh(); service.installedAVPlayerItem = nil; service.player.currentItem = nil
  service.repair()
  check(service.surface?.videoLayer.player == nil, "ordinary repair requires valid item")
  service.initialAttach()
  check(service.surface?.videoLayer.player === service.player && service.pip == nil,
        "initial load may bind before async item install, without creating an empty PiP controller")
  service.installIdentity(); service.repair()
  check(service.pip != nil, "install provides recovery after first-load no-item phase")
}
do {
  let service = fresh(); let other = AVPlayer(); service.surface?.videoLayer.player = other
  UIApplication.shared.applicationState = .inactive
  service.initialAttach()
  check(service.surface?.videoLayer.player === other, "rejected attach is non-destructive")
  service.avPlayerPiPAuthorized = true; service.initialAttach()
  check(service.surface?.videoLayer.player === service.player, "authorized inactive handoff remains allowed")
}
do {
  let service = fresh(); service.repair(); let controller = service.pip!
  service.pipStartIssued = true; service.avPlayerPiPAuthorized = true
  UIApplication.shared.applicationState = .inactive
  let replacementSurface = PlayerSurface()
  service.attachSurface(replacementSurface)
  check(replacementSurface.videoLayer.player === service.player && service.pip === controller,
        "authorized starting PiP surface handoff attaches without rebuilding its controller")
  service.generation += 1
  let staleSurface = PlayerSurface(); service.attachSurface(staleSurface)
  check(staleSurface.videoLayer.player == nil, "authorized surface path cannot revive a stale media item")
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
        "invalid current media/item may never be revived")
}
do {
  let service = fresh(); service.repair(); let old = service.pip!
  service.pipStartIssued = true; service.discard()
  check(service.retiringPiP.count == 1 && service.pip == nil, "issued but inactive start awaits terminal")
  service.repair()
  check(service.pip == nil && service.pipCreations == 1, "active-before-didStop cannot repair through retirement")
  service.terminal(old)
  check(service.retiringPiP.isEmpty && service.pip != nil && service.pip !== old,
        "confirmed terminal supplies deferred foreground repair")
  DispatchQueue.main.fireAll()
  check(service.errorMessage.isEmpty, "old retirement timer cannot fail a completed/new controller")
}
do {
  let service = fresh(); service.repair(); let old = service.pip!
  old.onStop = { [weak service, weak old] in if let old { service?.terminal(old) } }
  service.pipStartIssued = true; service.discard()
  check(service.retiringPiP.isEmpty && service.pip != nil && service.pip !== old,
        "synchronous didStop repair survives the returning old discard stack")
}
do {
  let service = fresh(); service.repair(); let old = service.pip!
  service.loading = true; service.pipStartIssued = true; service.discard()
  DispatchQueue.main.fireAll()
  check(service.retiringPiP.count == 1 && old.delegate === service.ownedDelegate, "timeout retains controller even if inactive")
  check(service.errorMessage == "media_engine_cleanup_failed" && !service.loading && !service.wantsPlayback,
        "timeout ends loading and playback intent with existing cleanup error")
  check(service.rejectRetiringPiPStart(old) && old.stops == 2, "late start still rejected after timeout")
  service.terminal(old); service.repair()
  check(service.pip == nil && service.loads == 0, "late terminal cannot revive failed load or autoplay")
}
do {
  let service = fresh(); service.repair(); let old = service.pip!
  UIApplication.shared.applicationState = .inactive
  check(service.rejectUnauthorizedAVPlayerPiPStart(old), "unsolicited willStart rejected")
  check(service.retiringPiP.count == 1 && service.surface?.videoLayer.player === service.player,
        "willStart is retiring before stop and cannot detach the in-flight layer")
  UIApplication.shared.applicationState = .active; service.repair()
  check(service.pip == nil, "foreground alone cannot bypass unknown stop")
  service.terminal(old)
  check(service.pip != nil && service.retiringPiP.isEmpty, "terminal callback repairs current valid foreground item")
}
do {
  let service = fresh(); service.repair(); let old = service.pip!
  service.generation += 1
  service.pendingReplacement = (UUID(), old, false, true, false, false)
  check(service.rejectUnauthorizedAVPlayerPiPStart(old), "pending replacement rejects unauthorized start")
  check(service.retiringPiP.isEmpty && service.pendingReplacement != nil, "replacement keeps its own stop fence")
  service.terminal(old)
  check(service.loads == 1 && service.pendingReplacement == nil, "terminal finishes authorized replacement once")
}
do {
  let service = fresh(); service.repair(); let old = service.pip!
  service.generation += 1; service.seekFault = true
  service.pendingReplacement = (UUID(), old, false, false, false, true)
  service.terminal(old); service.repair()
  check(service.loads == 0 && service.pip == nil, "aborted replacement terminal never reopens retained item")
}
do {
  let service = fresh(); service.repair(); let old = service.pip!
  service.pipStartIssued = true; service.discard()
  service.currentPath = nil; service.generation += 1
  service.terminal(old)
  check(service.player.currentItem == nil && service.pip == nil && service.clears == 1,
        "deleted media is cleared after terminal and never reattached")
}
for issued in [false, true] {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = issued
  service.mediaKitPiP = renderer
  service.discardRenderer()
  check(service.mediaKitPiP == nil, "renderer ownership cleared before stop")
  check(service.retiringPiP.isEmpty == !issued, "only truly never-issued renderer releases without terminal")
  if issued {
    DispatchQueue.main.fireAll()
    check(service.retiringPiP.count == 1, "issued inactive renderer survives timeout")
    service.terminal(old)
  }
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  service.mediaKitPiP = MediaKitPiPRenderer(old)
  check(!service.rejectRetiringPiPStart(old), "owned MK start observed before retirement")
  service.discardRenderer()
  check(service.retiringPiP.count == 1, "observed-only MK start must await terminal")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); service.mediaKitPiP = renderer
  old.onStop = { [weak service, weak old] in if let old { service?.terminal(old) } }
  service.pendingReplacement = (UUID(), old, false, true, false, false)
  service.terminal(old)
  check(service.restores == 0 && service.loads == 1 && service.mediaKitPiP == nil,
        "synchronous MK stop cannot route back into restore while replacing")
}
do {
  let service = fresh(); service.mediaKit = ReviewEngine()
  let old = AVPictureInPictureController(playerLayer: VideoLayer())!
  let renderer = MediaKitPiPRenderer(old); renderer.startIssued = true
  service.mediaKitPiP = renderer; service.mediaKitPiPActiveRequestID = "request"
  var results: [Bool] = []
  service.abortMediaKitPiP(engineID: "engine", requestID: "request") { results.append($0) }
  check(results.isEmpty && service.retiringPiP.count == 1, "abort of issued inactive MK waits for terminal")
  service.terminal(old)
  check(results == [true], "matching terminal completes MK abort exactly once")
  DispatchQueue.main.fireAll()
  check(results == [true], "late timeout cannot complete MK abort twice")
}
print("Presentation production policy/method harness: \(assertions) assertions passed")
print("Scope: extracted Swift decisions and deterministic callbacks; Apple SDK / device rendering not exercised.")
