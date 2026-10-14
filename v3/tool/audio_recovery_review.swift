import Foundation
// These collaborators exercise extracted production decisions. They do not
// emulate AVAudioSession, AVKit, media decoding or suspended iOS processes.
// PRODUCTION_POLICY
// PRODUCTION_TIMING
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


let AVAudioSessionInterruptionTypeKey = "type"
let AVAudioSessionInterruptionReasonKey = "reason"
let AVAudioSessionInterruptionOptionKey = "options"
let AVAudioSessionRouteChangeReasonKey = "route"
let AVAudioSessionRouteChangePreviousRouteKey = "previousRoute"
struct ReviewError: Error { }
final class UIApplication {
 enum State { case active, inactive, background }
 static let shared = UIApplication()
 var applicationState = State.active
}
final class AVAudioSessionRouteDescription { var outputs: [ReviewPort] = []; init(_ p: [AVAudioSession.Port] = []) { outputs = p.map(ReviewPort.init) } }
struct ReviewPort { let portType: AVAudioSession.Port }
final class AVAudioSession {
 enum InterruptionType: UInt { case began = 1, ended = 0 }
 enum InterruptionReason: UInt { case `default` = 0, routeDisconnected = 2 }
 struct InterruptionOptions: OptionSet { let rawValue: UInt; static let shouldResume = Self(rawValue: 1) }
 enum RouteChangeReason: UInt { case oldDeviceUnavailable = 2, newDeviceAvailable = 1 }
 enum Port { case builtInSpeaker, headphones, bluetoothA2DP, bluetoothHFP, bluetoothLE }
 enum Category { case playback, ambient }
 enum Mode { case moviePlayback, `default` }
 static let instance = AVAudioSession()
 static func sharedInstance() -> AVAudioSession { instance }
 var category = Category.playback
 var mode = Mode.moviePlayback
 var categoryOptions: [Int] = []
 var currentRoute = AVAudioSessionRouteDescription([.builtInSpeaker])
 var activations = 0, activationFailures = 0
 func setCategory(_ c: Category, mode m: Mode, options: [Int]) throws { category=c;mode=m;categoryOptions=options }
 func setActive(_ active: Bool) throws { if active { activations += 1; if activationFailures > 0 { activationFailures -= 1; throw ReviewError() } } }
}
enum Status { case ready, failed }
final class Item { var status=Status.ready }
final class ReviewPlayer { var status=Status.ready; var currentItem: Item?=Item(); func pause() {}; func replaceCurrentItem(with: Item?) { currentItem=with } }
final class Layer { var player: ReviewPlayer? }
final class Caption { var isHidden=false }
final class Surface { let videoLayer=Layer(); let caption=Caption() }
final class Store { func readPlaybackRecord(path: String, _ completion: ([String:Any])->Void) { completion([:]) } }
final class Library { let recordStore=Store() }
struct LibraryFailure: Error { static func app(_ _:String) -> Self { Self() } }
final class LeeMediaKitEngine {
 let id = UUID().uuidString
 var playIntentVersion=0
 var failure="", ready=true, duration=120.0, seekabilityKnown=true, seekable=false, position=0.0, playing=false, buffering=false, ended=false
 var rate: Float=1, volume: Float=1, changed:(()->Void)?
 init(transport: @escaping (String, [String:Any], @escaping (Bool)->Void)->Void) {}
 func open(url:URL,isAudio:Bool) {}
}
struct Pending { var autoplay:Bool }
final class Service {
 var avPlayerTransportMutationDepth = 0
 func endInlinePiPTransportFollow() {}
 var currentSessionID = UUID()
 var currentSessionPositionRestore: CurrentSessionPositionRestore?
 func restoreCurrentSessionPositionIfNeeded(engine: LeeMediaKitEngine, generation: Int) -> Bool { false }
 var nativePlaybackTiming = NativePlaybackTiming()
 var pip: NSObject?
 func recordAVPlayerPiPEvent(_ event:String,controller:NSObject,error:Error?=nil) {}
 var audioRecoveryRequest:UUID?
 var audioRecoveryRequiresAutoResume=false, rebuildPlayerAfterMediaServicesReset=false
 var currentPath:String?="a.mkv", generation=1, playbackOperation=0, wantsPlayback=true, inBackground=false, autoResume=true
 var interrupted=false, resumeAfterInterruption=false, routeLossRecoveryDeadline=0.0, audioSessionActivated=false
 var sleepUntil:Date?, sleepTimer:Timer?, audioRecoveryPending=false, audioRecoveryExhausted=false, audioRecoveryAttempt=0, audioRecoveryWorkItem:DispatchWorkItem?
 var errorMessage="", lastDiagnostic="", timelineReady=true, loading=false, isSeeking=false, scrubbing=false, presentationWaiting=false, environmentAllowed=true
 var playbackEnvironmentAllowsPlayback:Bool { environmentAllowed }
 var pendingEndAction=false, atPlaybackEnd=false, aPoint:Double?, bPoint:Double?, replayOperation:Int?, decoderRecoveryAttempted=false, seekFault=false
 var pendingReplacement:Pending?, deferredPresentationLoad:Pending?, detectingIntro=false, introToken=1
 let player=ReviewPlayer(), library=Library()
 var mediaKit:LeeMediaKitEngine?, surface:Surface?, mediaIsAudio=false, rate:Float=1, mediaVolume:Float=1
 var installedAVPlayerItem:Item?, observations:[Int]=[], timelineOrigin=0.0, preparedMediaKit=false
 var initialPositionEstablished=false, initialHistoricalSeekPending=false, sessionCompleted=false, nonSeekableStartPosition:Double?, pendingResume=true, rememberProgress=true, duration=120.0, engineNotice="", openingTimeout:DispatchWorkItem?
 var mediaKitTransport:((String,[String:Any],@escaping (Bool)->Void)->Void)? = { _,_,completion in completion(true) }
 var plays=0, pauses=0, loads:[Bool]=[], foregroundRepairs=0, retries=0
 func publish() {}; func persist() {}; func recordLifecycle(_ s:String) {}
 // Video-output lifecycle is covered by the production presentation harness.
 func resumeDeferredMediaKitVideoOutput() {}
 func ensureAVPlayerPresentation(reason:String) { foregroundRepairs += 1 }
 func tick() { if let d=sleepUntil,d <= Date() { pause() } }
 func resolveEndCandidate() {}; func performPendingEndAction() {}; func restartCurrentItem() {}; func seek(_ n:Double) {}
 func pauseEngine() { pauses += 1; mediaKit?.playIntentVersion += 1 }
 func resumeEngine(completion:@escaping (Bool)->Void) { plays += 1; mediaKit?.playIntentVersion += 1; completion(true) }
 func cancelIntroDetection() { detectingIntro=false }
 func finishStart(_ seconds:Double,token:Int,itemGeneration:Int) {}
 func resumeDeferredPresentationLoadIfPossible() {}
 func enforcePlaybackEnvironment() { if !environmentAllowed { pause() } }
 func load(resume:Bool,autoplay:Bool=true) { loads.append(autoplay); wantsPlayback=autoplay }
 func clearBoundary() {}; func revokeManualPiP() {}; func discardAVPlayerPiP() {}; func cancelSeeks() {}; func scheduleOpenTimeout(token:Int) {}
 func fail(_ s:String) { errorMessage=s }
 func offerEndCandidate(source:String) {}; func captureRememberedProgress() {}
 func becomeActive() {
 // PRODUCTION_FOREGROUND
 }
 // PRODUCTION_METHODS
}
func began(_ s:Service) { s.interruption(Notification(name:Notification.Name("interruption"),userInfo:[AVAudioSessionInterruptionTypeKey:UInt(1)])) }
func ended(_ s:Service,_ permission:Bool) { s.interruption(Notification(name:Notification.Name("interruption"),userInfo:[AVAudioSessionInterruptionTypeKey:UInt(0),AVAudioSessionInterruptionOptionKey:UInt(permission ? 1:0)])) }
func fresh()->Service { DispatchQueue.main.scheduled = []; DispatchQueue.main.now = 100; UIApplication.shared.applicationState = .active; AVAudioSession.instance.activations=0; AVAudioSession.instance.activationFailures=0;AVAudioSession.instance.currentRoute=AVAudioSessionRouteDescription([.builtInSpeaker]);return Service() }
var failures=0,tests=0
func check(_ value:Bool,_ name:String) { tests += 1;print("\(value ? "PASS":"FAIL") \(name)");if !value { failures += 1 } }
// AUDIO_RECOVERY_SCENARIOS
do {
 var timing=NativePlaybackTiming()
 timing.observeTick(now:0,eligible:true,generation:1)
 timing.observeTick(now:0.25,eligible:true,generation:1)
 check(timing.tickCount==2 && timing.gapCount==1 && timing.maxGapExcessMs==0, "native tick baseline preserves the existing 250ms cadence")
 timing.observeTick(now:0.8,eligible:true,generation:1)
 check(abs(timing.maxGapExcessMs-300)<0.001, "native timing counts only excess over configured cadence")
 timing.observeTick(now:20,eligible:false,generation:1)
 timing.observeTick(now:100,eligible:true,generation:1)
 check(timing.tickCount==4 && timing.gapCount==2 && abs(timing.maxGapExcessMs-300)<0.001, "ineligible time does not become a playback delay")
 timing.clearTickBaseline();timing.observeTick(now:200,eligible:true,generation:1)
 check(timing.gapCount==2 && abs(timing.maxGapExcessMs-300)<0.001, "lifecycle and pause reset only the timing baseline")
 timing.recordAudioCall(activate:true,reason:"activate:explicit-play",generation:1)
 timing.recordAudioCall(activate:false,reason:"deactivate:idle",generation:1)
 check(timing.audioActivateCount==1 && timing.audioDeactivateCount==1 && timing.audioLastReason=="deactivate:idle", "audio timing counts app calls without claiming hardware output")
 timing.observeTick(now:300,eligible:true,generation:2)
 check(timing.tickCount==1 && timing.gapCount==0 && timing.maxGapExcessMs==0 && timing.audioActivateCount==0, "new media generation resets all native measurements")
 timing.recordAudioCall(activate:true,reason:String(repeating:"x",count:100),generation:2)
 check(timing.audioLastReason.count==64, "audio diagnostic reason stays bounded")
}
do { let s=fresh();s.autoResume=false;began(s);s.becomeActive();check(s.plays==0 && s.interrupted && AVAudioSession.instance.activations==0,"autoResume OFF: began -> foreground without ended must remain interrupted and silent") }
do { let s=fresh();began(s);s.becomeActive();check(s.plays==0 && s.interrupted && AVAudioSession.instance.activations==0,"autoResume ON: foreground before ended must not invent shouldResume") }
do { let s=fresh();began(s);ended(s,false);s.becomeActive();check(s.plays==0 && !s.wantsPlayback,"ended without shouldResume remains paused on foreground") }
do { let s=fresh();s.autoResume=false;began(s);ended(s,true);check(s.plays==0 && !s.wantsPlayback,"autoResume OFF remains paused despite shouldResume") }
do { let s=fresh();began(s);ended(s,true);check(s.plays==1,"eligible interruption-ended resumes") }
do { let s=fresh();began(s);s.pause();ended(s,true);s.becomeActive();check(s.plays==0 && !s.wantsPlayback,"manual pause wins over late ended and foreground") }
do { let s=fresh();began(s);s.sleepUntil=Date().addingTimeInterval(-1);ended(s,true);check(s.plays==0 && !s.wantsPlayback,"sleep deadline wins over resume") }
do { let s=fresh();began(s);s.environmentAllowed=false;ended(s,true);check(s.plays==0 && !s.wantsPlayback,"background disabled blocks ended resume") }
do { let s=fresh();s.mediaServicesWereReset();check(s.loads==[false] && !s.wantsPlayback,"media services reset rebuilds without autoplay") }
do { let s=fresh();began(s);s.openMediaKit(url:URL(fileURLWithPath:"/a.mkv"),resume:true,token:s.generation);check(s.interrupted && AVAudioSession.instance.activations==0,"opening media_kit while interrupted cannot reactivate session") }
do { let s=fresh();let engine=LeeMediaKitEngine(transport:{_,_,cb in cb(true)});s.mediaKit=engine;began(s);s.mediaKitChanged(engine,token:s.generation);check(s.plays==0 && s.interrupted && AVAudioSession.instance.activations==0,"automatic nonseekable ready is not an explicit Play command") }
do { let s=fresh();began(s);s.play();check(s.plays==1 && !s.interrupted,"explicit foreground Play can recover a missing-ended interruption") }
do { let s=fresh();began(s);s.routeChanged(Notification(name:Notification.Name("route"),userInfo:[AVAudioSessionRouteChangeReasonKey:UInt(2),AVAudioSessionRouteChangePreviousRouteKey:AVAudioSessionRouteDescription([.headphones])]));ended(s,true);s.becomeActive();check(s.plays==0 && !s.wantsPlayback,"headphone unplug wins over shouldResume and foreground") }
do { let s=fresh();s.wantsPlayback=false;began(s);ended(s,true);check(s.plays==0,"paused before interruption does not resume") }
do { let s=fresh();s.pendingReplacement=Pending(autoplay:true);s.deferredPresentationLoad=Pending(autoplay:true);s.routeChanged(Notification(name:Notification.Name("route"),userInfo:[AVAudioSessionRouteChangeReasonKey:UInt(2),AVAudioSessionRouteChangePreviousRouteKey:AVAudioSessionRouteDescription([.headphones])]));check(s.pendingReplacement?.autoplay==false && s.deferredPresentationLoad?.autoplay==false,"route loss cancels both queued autoplay intents") }
do { let s=fresh();s.pendingReplacement=Pending(autoplay:true);s.deferredPresentationLoad=Pending(autoplay:true);s.interruption(Notification(name:Notification.Name("interruption"),userInfo:[AVAudioSessionInterruptionTypeKey:UInt(1),AVAudioSessionInterruptionReasonKey:UInt(2)]));check(s.pendingReplacement?.autoplay==false && s.deferredPresentationLoad?.autoplay==false,"routeDisconnected interruption cancels queued autoplay intents") }
do { let s=fresh();s.pendingReplacement=Pending(autoplay:true);s.deferredPresentationLoad=Pending(autoplay:true);began(s);ended(s,false);check(s.pendingReplacement?.autoplay==false && s.deferredPresentationLoad?.autoplay==false,"ended without permission cancels queued autoplay intents") }
do { let s=fresh();began(s);AVAudioSession.instance.activationFailures=1;ended(s,true);s.configureAutoResume(["autoResume":false]);check(!s.wantsPlayback && !s.audioRecoveryPending && s.audioRecoveryWorkItem==nil,"disabling autoResume cancels an authorized automatic activation retry") }
do { let s=fresh();s.autoResume=false;began(s);s.play();check(s.plays==1 && !s.interrupted,"explicit Play is independent of disabled autoResume") }
do { let s=fresh();UIApplication.shared.applicationState = .background;s.inBackground=true;began(s);ended(s,true);check(s.plays==1,"eligible shouldResume can resume directly in permitted background") }

// Background retries remain bounded and are driven only while the app process
// can run. This scheduler is not evidence that iOS will execute suspended work.
do {
 let s=fresh(); UIApplication.shared.applicationState = .background; s.inBackground=true
 began(s); AVAudioSession.instance.activationFailures=1; ended(s,true)
 check(s.audioRecoveryWorkItem != nil && s.plays==0, "background activation failure schedules a permitted retry")
 DispatchQueue.main.advance(0.25)
 check(s.plays==1 && AVAudioSession.instance.activations==2, "permitted background retry restores playback once")
}
do {
 let s=fresh(); UIApplication.shared.applicationState = .background; s.inBackground=true
 began(s); AVAudioSession.instance.activationFailures=100; ended(s,true)
 DispatchQueue.main.advance(10)
 check(AVAudioSession.instance.activations==4 && s.audioRecoveryExhausted && !s.audioRecoveryPending && s.plays==0,
       "background activation failure stops after initial attempt plus three retries")
}
for cancellation in 0..<6 {
 let s=fresh(); UIApplication.shared.applicationState = .background; s.inBackground=true
 began(s); AVAudioSession.instance.activationFailures=1; ended(s,true)
 switch cancellation {
 case 0: s.pause()
 case 1: s.configureAutoResume(["autoResume":false])
 case 2: s.environmentAllowed=false
 case 3: s.sleepUntil=Date().addingTimeInterval(-1)
 case 4: began(s)
 default: s.mediaServicesWereReset()
 }
 DispatchQueue.main.advance(10)
 check(s.plays==0 && AVAudioSession.instance.activations==1,
       "latest pause/setting/background/sleep/interruption/reset cancels pending retry \(cancellation)")
}
do {
 let s=fresh(); began(s); AVAudioSession.instance.activationFailures=1; s.play(); s.becomeActive()
 check(s.interrupted && s.plays==0 && AVAudioSession.instance.activations==1,
       "failed explicit interruption recovery does not authorize later foreground activation")
}

print("RESULT \(tests-failures)/\(tests) passed; \(failures) failures; deterministic production decision tests only")
exit(failures==0 ? 0:1)
