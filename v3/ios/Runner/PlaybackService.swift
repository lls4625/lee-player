import AVFoundation
import AVKit
import MediaPlayer
import UIKit
import CryptoKit

final class LeeMediaKitEngine {
  let id = UUID().uuidString
  var changed: (() -> Void)?
  private let transport: (String, [String: Any], @escaping (Bool) -> Void) -> Void
  private var opened = false
  private var stopped = false
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
  private(set) var failure = ""
  private(set) var trackState: [String: Any] = [:]
  var rate: Float = 1 { didSet { if opened && rate != oldValue { send("rate", ["value": Double(rate)]) } } }
  var volume: Float = 1 { didSet { if opened && volume != oldValue { send("volume", ["value": Double(volume)]) } } }

  init(transport: @escaping (String, [String: Any], @escaping (Bool) -> Void) -> Void) {
    self.transport = transport
  }

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
    transport(method, args) { [weak self] success in
      guard let self = self, !self.stopped else { completion?(false); return }
      if !success {
        self.recordDiagnostic("\(method) rejected")
        if method == "open" || method == "play" {
          self.failure = "media_kit \(method == "open" ? "打开" : "播放")失败，请重新打开媒体"
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

  func pausePlayback() { send("pause"); recordDiagnostic("pause") }
  func resumePlayback() { send("play"); recordDiagnostic("resume") }
  func stopPlayback() {
    guard !stopped else { return }
    stopped = true; changed = nil
    transport("stop", ["engineId": id]) { _ in }
  }

  func seek(seconds: Double, completion: @escaping (Bool) -> Void) {
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

  func addSubtitle(url: URL) -> Bool {
    guard !stopped, ready else { return false }
    send("subtitle", ["url": url.absoluteString]); return true
  }

  func setLoop(from: Double, to: Double) -> Bool {
    guard !stopped, ready, seekable else { return false }
    send("loop", ["from": from, "to": to]); return true
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
    guard !stopped else { return }
    if let value = state["position"] as? NSNumber, value.doubleValue.isFinite { position = max(0, value.doubleValue) }
    if let value = state["duration"] as? NSNumber, value.doubleValue.isFinite { duration = max(0, value.doubleValue) }
    if let value = state["playing"] as? Bool { playing = value }
    if let value = state["ready"] as? Bool { ready = value }
    if let value = state["buffering"] as? Bool, value != buffering {
      buffering = value; recordDiagnostic("buffering=\(value ? 1 : 0)")
    }
    if let value = state["ended"] as? Bool { ended = value }
    if let value = state["seekable"] as? Bool { seekable = value }
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
  let player = AVPlayer()
  var mediaKitTransport: ((String, [String: Any], @escaping (Bool) -> Void) -> Void)?
  private var mediaKit: LeeMediaKitEngine?
  var restoreRequested: (() -> Void)?
  private var heartbeat: Timer?
  private var engineNotice = ""
  private var fallbackUsed = false
  private var pendingResume = false
  private var mediaVolume: Float
  private var mediaBrightness: CGFloat
  private var seekSequence = 0
  private var activeSeek: Int?
  private var pendingSeek: (id: Int, seconds: Double, precise: Bool, done: (Bool) -> Void)?
  private var activeSeekCompletion: ((Bool) -> Void)?
  private var seekTimeout: DispatchWorkItem?
  private var scrubbing = false
  private var seekFault = false
  private var boundaryObserver: Any?
  private var preparedMediaKit = false
  private var openingTimeout: DispatchWorkItem?
  private var lastDiagnostic = ""
  private var mediaIsAudio: Bool { guard let path = currentPath else { return false }; return library.audioExtensions.contains(URL(fileURLWithPath: path).pathExtension.lowercased()) }
  private var enginePlaying: Bool { mediaKit?.playing ?? (player.timeControlStatus == .playing) }
  private var pipActive: Bool { mediaKitPiP?.isActive ?? (pip?.isPictureInPictureActive == true) }
  private var pipRequesting: Bool {
    mediaKitPiPPreparing || mediaKitPiP != nil || mediaKitPiPRestoring || pipStartIssued || pipStartTimeout != nil || pipActive || !retiringPiP.isEmpty
  }
  private var isSeeking: Bool { activeSeek != nil || pendingSeek != nil }
  private func pauseEngine() { if let mediaKit = mediaKit { mediaKit.pausePlayback() } else { player.pause() } }
  private func resumeEngine() { if let mediaKit = mediaKit { mediaKit.rate = rate; mediaKit.resumePlayback() } else { player.playImmediately(atRate: rate) } }

  let library: CourseLibrary
  var changed: (([String: Any]) -> Void)?
  var notice: ((String) -> Void)?
  var surface: PlayerSurface?
  var pip: AVPictureInPictureController?
  weak var pipDelegate: AVPictureInPictureControllerDelegate?
  private var pipPossibleObservation: NSKeyValueObservation?
  private var pipStartTimeout: DispatchWorkItem?
  private var pipActivationTimeout: DispatchWorkItem?
  private var pipStartIssued = false
  private var mediaKitPiP: MediaKitPiPRenderer?
  private var mediaKitPiPPreparing = false
  private var mediaKitPiPRequestID: String?
  private var mediaKitPiPPreparationTimeout: DispatchWorkItem?
  private var mediaKitPiPRestoring = false
  private var retiringPiP: [ObjectIdentifier: (AVPictureInPictureController, MediaKitPiPRenderer?)] = [:]

  private func discardAVPlayerPiP() {
    // Capture this before cancellation clears pipStartIssued. A start request
    // can still be in flight even when isPictureInPictureActive is false.
    let controller = pip
    let needsRetirement = pipStartIssued || controller?.isPictureInPictureActive == true
    cancelPendingAVPlayerPiP()
    if let controller = controller {
      if needsRetirement {
        retirePiP(controller)
      } else {
        // Prepared or already stopped controllers will not send another didStop.
        // Releasing them must not block the next media's PiP for the fallback wait.
        controller.delegate = nil
      }
    }
    pip = nil
  }

  private func retirePiP(_ controller: AVPictureInPictureController, renderer: MediaKitPiPRenderer? = nil) {
    let key = ObjectIdentifier(controller)
    guard retiringPiP[key] == nil else { return }
    retiringPiP[key] = (controller, renderer)
    if let renderer = renderer { renderer.stop() } else { controller.stopPictureInPicture() }
    // A controller which never became active may not produce didStop.
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard let self = self, self.retiringPiP[key] != nil else { return }
      controller.delegate = nil
      self.retiringPiP.removeValue(forKey: key)
      self.publish()
    }
    publish()
  }

  func finishRetiringPiP(_ controller: AVPictureInPictureController) -> Bool {
    let key = ObjectIdentifier(controller)
    guard retiringPiP[key] != nil else { return false }
    controller.delegate = nil
    retiringPiP.removeValue(forKey: key)
    publish()
    return true
  }

  func rejectRetiringPiPStart(_ controller: AVPictureInPictureController) -> Bool {
    guard retiringPiP[ObjectIdentifier(controller)] != nil else { return false }
    controller.stopPictureInPicture()
    return true
  }
  private var observations: [NSKeyValueObservation] = []
  private var notifications: [NSObjectProtocol] = []
  private var remoteTargets: [(MPRemoteCommand, Any)] = []
  private var queue: [String] = []
  private var index = 0
  private var wantsPlayback = false
  private var interrupted = false
  private var resumeAfterInterruption = false
  private var loading = false
  private var generation = 0
  private let assetPreparation = DispatchQueue(label: "雷player.timeline", qos: .userInitiated)
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
    background = true
    defaults.set(true, forKey: "playback.background")
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
    observations.append(player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
      DispatchQueue.main.async { self?.publish() }
    })
    let center = NotificationCenter.default
    notifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] in self?.interruption($0) })
    notifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      if (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        self?.pause(); self?.errorMessage = "音频设备已断开，点击播放继续"; self?.publish()
      }
    })
    notifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      guard let self = self else { return }
      if self.scrubbing { self.cancelScrub() }
      self.persist()
    })
    notifications.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in self?.tick() })
    notifications.append(center.addObserver(forName: AVAudioSession.mediaServicesWereResetNotification, object: nil, queue: .main) { [weak self] _ in
      self?.pause(); self?.errorMessage = "音频服务已重置，请重新选择课时播放"; self?.publish()
    })
    notifications.append(center.addObserver(forName: .AVPlayerItemDidPlayToEndTime, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
      self.ended()
    })
    notifications.append(center.addObserver(forName: .AVPlayerItemFailedToPlayToEndTime, object: nil, queue: .main) { [weak self] note in
      guard let self = self, let item = note.object as? AVPlayerItem, item === self.player.currentItem else { return }
      self.fail(item.error?.localizedDescription ?? "媒体播放中断，文件可能损坏")
    })
    setupRemoteCommands()
  }

  deinit {
    sleepTimer?.invalidate()
    heartbeat?.invalidate()
    openingTimeout?.cancel(); seekTimeout?.cancel()
    cancelPendingAVPlayerPiP()
    mediaKitPiP?.stop()
    mediaKit?.stopPlayback()
    if let boundary = boundaryObserver { player.removeTimeObserver(boundary) }
    notifications.forEach { NotificationCenter.default.removeObserver($0) }
    for (command, target) in remoteTargets { command.removeTarget(target) }
  }

  func snapshot() -> [String: Any] {
    let mediaKitTracks = mediaKit?.trackState ?? [:]
    return ["path": currentPath ?? "", "queue": queue, "index": index, "generation": generation,
      "trackSelecting": trackSelection != nil, "engineId": mediaKit?.id ?? "",
      "playing": enginePlaying, "loading": loading || isSeeking || (mediaKit?.buffering ?? (player.timeControlStatus == .waitingToPlayAtSpecifiedRate)),
      "seeking": isSeeking, "scrubbing": scrubbing, "isAudio": mediaIsAudio,
      "engine": mediaKit == nil ? "AVPlayer" : "media_kit", "engineNotice": engineNotice,
      "diagnostic": lastDiagnostic, "seekable": timelineReady && !seekFault && (mediaKit?.seekable ?? true),
      "position": position, "duration": duration, "rate": Double(rate), "mode": mode,
      "continuous": continuous, "background": background, "autoResume": autoResume, "rememberProgress": rememberProgress,
      "rewindSeconds": rewindSeconds, "forwardSeconds": forwardSeconds,
      "smartIntro": smartIntro, "detectingIntro": detectingIntro, "introSkipped": introSkipped,
      "error": errorMessage, "interrupted": interrupted, "volume": Double(mediaVolume),
      "brightness": Double(mediaBrightness), "fit": fit,
      "a": aPoint ?? -1, "b": bPoint ?? -1,
      "sleepRemaining": max(0, sleepUntil?.timeIntervalSinceNow ?? 0),
      "subtitleName": subtitleName, "audioTrack": mediaKitTracks["audioTrack"] ?? selectedAudio, "subtitleTrack": mediaKitTracks["subtitleTrack"] ?? selectedSubtitle,
      "audioTracks": mediaKitTracks["audioTracks"] ?? trackDescriptions(audioOptions, fallback: fallbackAudio),
      "subtitleTracks": mediaKitTracks["subtitleTracks"] ?? trackDescriptions(subtitleOptions, fallback: fallbackSubtitles),
      "pipAvailable": !mediaIsAudio && AVPictureInPictureController.isPictureInPictureSupported(),
      "pipRequesting": pipRequesting]
  }

  func publish() {
    UIApplication.shared.isIdleTimerDisabled = !mediaIsAudio && enginePlaying && UIApplication.shared.applicationState == .active
    changed?(snapshot())
    updateNowPlaying()
  }

  func playbackInfo() -> String {
    var lines = ["播放引擎：\(mediaKit == nil ? "AVPlayer" : "media_kit / libmpv")",
                 "时长：\(Int(duration)) 秒", "可定位：\((mediaKit?.seekable ?? timelineReady) ? "是" : "否")"]
    if let mediaKit = mediaKit {
      let info = mediaKit.diagnostics
      lines.append("解码策略：\(info["decoder"] ?? "自动选择")")
      lines.append("同步策略：libmpv 默认；音频：PCM")
      lines.append("倍速：设置 \(rate)；引擎 \(info["actualRate"] ?? "未知")")
      let session = AVAudioSession.sharedInstance()
      let output = session.currentRoute.outputs.map { "\($0.portName)（\($0.portType.rawValue)）" }.joined(separator: "、")
      lines.append("音频设备：\(output.isEmpty ? "未连接" : output)；采样率：\(Int(session.sampleRate)) Hz")
      lines.append("libmpv 版本：\(info["version"] ?? "未知")")
      lines.append("实际硬解：\(info["hwdec"] ?? "未知")；视频输出：\(info["vo"] ?? "未知")")
      lines.append("解码丢帧：\(info["decoderDrops"] ?? "未知")；输出丢帧：\(info["outputDrops"] ?? "未知")")
      let age = (info["sessionAge"] as? NSNumber)?.doubleValue ?? 0
      lines.append(String(format: "本次引擎运行 %.1f 秒；会话 %d", age, generation))
      lines.append("实际音视频输出时间戳及音画偏差：未测量；定位完成不代表首帧显示或同步完成")
      if let events = info["controlEvents"] as? [String], !events.isEmpty {
        lines.append("最近控制事件（原生会话起点；下方引擎日志以 Dart 引擎创建为起点）：")
        lines.append(events.joined(separator: "\n"))
      }
      if let errors = info["errors"] as? [String], !errors.isEmpty {
        lines.append("以下为历史引擎日志，[秒数]表示记录时间：")
        lines.append(errors.joined(separator: "\n"))
      }
    }
    let state = snapshot()
    for kind in ["audio", "subtitle"] {
      let rows = state["\(kind)Tracks"] as? [[String: Any]] ?? []
      let selected = (state["\(kind)Track"] as? NSNumber)?.intValue ?? -1
      lines.append("\(kind == "audio" ? "音轨" : "字幕")：\(rows.count) 条")
      for row in rows {
        let index = (row["index"] as? NSNumber)?.intValue ?? -1
        lines.append("\(index == selected ? "✓" : "○") \(row["name"] ?? "轨道") · \(row["details"] ?? "") · id=\(row["id"] ?? index)")
      }
    }
    if !lastDiagnostic.isEmpty { lines.append(lastDiagnostic) }
    return lines.joined(separator: "\n")
  }

  func open(paths: [String], selected: Int, resume: Bool) throws {
    guard !paths.isEmpty, paths.indices.contains(selected) else { throw LibraryFailure.message("播放队列为空") }
    for path in paths { _ = try library.url(path) }
    persist()
    queue = paths; index = selected
    load(resume: resume)
  }

  private func load(resume: Bool) {
    guard let path = currentPath else { return }
    finishTrackSelection("媒体已重新打开，请重新选择轨道")
    cancelIntroDetection()
    cancelSeeks()
    openingTimeout?.cancel()
    clearBoundary()
    discardMediaKitPiP()
    mediaKit?.stopPlayback(); mediaKit = nil
    discardAVPlayerPiP()
    engineNotice = ""; lastDiagnostic = ""; fallbackUsed = false; preparedMediaKit = false
    seekFault = false; pendingResume = resume
    introSkipped = 0
    generation += 1
    let token = generation
    player.pause(); timelineReady = false; loading = true; wantsPlayback = true; errorMessage = ""
    observations = Array(observations.prefix(1))
    player.replaceCurrentItem(with: nil)
    aPoint = nil; bPoint = nil
    cues = []; subtitleName = ""; subtitleText = ""; surface?.caption.text = ""; surface?.caption.isHidden = true
    audioOptions = []; subtitleOptions = []; selectedAudio = -1; selectedSubtitle = -1
    guard let transport = mediaKitTransport else { fail("播放通道尚未就绪"); return }
    scheduleOpenTimeout(token: token)
    publish()
    transport("release", [:]) { [weak self] success in
      guard let self = self, self.generation == token else { return }
      guard success else { self.fail("无法释放上一播放引擎，请重新启动应用"); return }
      self.loadPrepared(path: path, resume: resume, token: token)
    }
  }

  private func loadPrepared(path: String, resume: Bool, token: Int) {
    do {
      let url = try library.url(path)
      guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryFailure.message("视频已移动或删除，请刷新课程库") }
      timelineReady = false
      timelineOrigin = 0
      fallbackAudio = []; fallbackSubtitles = []
      observations = Array(observations.prefix(1))
      player.replaceCurrentItem(with: nil)
      surface?.videoLayer.isHidden = false
      surface?.videoLayer.player = player
      surface?.onLayout = nil
      if Self.prefersMediaKit(url) {
        openMediaKit(url: url, resume: resume, token: token)
        return
      }
      scheduleOpenTimeout(token: token)
      assetPreparation.async { [weak self] in
        do {
          let prepared = try PlaybackTimeline.prepare(url: url)
          DispatchQueue.main.async {
            guard let self = self, self.generation == token else { return }
            self.install(prepared.asset, origin: prepared.origin, url: url, path: path, resume: resume, token: token)
          }
        } catch {
          DispatchQueue.main.async {
            guard let self = self, self.generation == token else { return }
            self.fallbackToMediaKit(url: url, resume: resume, token: token, error: error)
          }
        }
      }
      publish()
    } catch { fail(error.localizedDescription) }
  }

  private func install(_ asset: AVAsset, origin: Double, url: URL, path: String, resume: Bool, token: Int) {
    timelineOrigin = origin
    let item = AVPlayerItem(asset: asset)
    item.audioTimePitchAlgorithm = .timeDomain
    var prepared = false
    observations.append(item.observe(\.status, options: [.new]) { [weak self] item, _ in
      DispatchQueue.main.async {
        guard let self = self, self.generation == token, self.mediaKit == nil else { return }
        if item.status == .failed {
          self.fallbackToMediaKit(url: url, resume: resume, token: token, error: item.error ?? LibraryFailure.message("iOS 不支持此媒体")); return
        }
        guard item.status == .readyToPlay, !prepared else { return }
        prepared = true
        self.openingTimeout?.cancel()
        self.timelineReady = true
        self.loadTracks(item)
        // Old records used the source movie clock. Convert once, including pauses inside its empty edit.
        var record = self.library.records[path] ?? [:]
        let previousOrigin = (record["timelineOrigin"] as? NSNumber)?.doubleValue ?? 0
        let saved = (record["position"] as? NSNumber)?.doubleValue ?? 0
        let migrated = saved.isFinite ? max(0, saved + previousOrigin - origin) : 0
        if self.rememberProgress {
          record["position"] = migrated
          record["duration"] = self.duration
          record["timelineOrigin"] = origin
          self.library.records[path] = record; self.library.save()
        }
        let start = self.rememberProgress && resume && migrated > 0 && migrated < self.duration - 2 ? migrated : 0
        self.prepareStart(url: url, saved: start)
      }
    })
    player.replaceCurrentItem(with: item)
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
    enqueueSeek(seconds, precise: true) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self = self, self.introToken == token, self.generation == itemGeneration else { return }
        self.loading = false
        if !finished { self.introSkipped = 0; self.endIntroBackgroundTask(); return }
        if self.wantsPlayback && !self.interrupted { self.play() }
        self.endIntroBackgroundTask()
        self.persist(); self.publish()
      }
    }
  }

  func play() {
    guard currentPath != nil else { return }
    if mediaKit?.ended == true { load(resume: false); return }
    if seekFault || (mediaKit?.failure.isEmpty == false) { load(resume: true); return }
    if !timelineReady || loading || isSeeking || scrubbing { wantsPlayback = true; publish(); return }
    if let deadline = sleepUntil, Date() >= deadline { sleepTimer?.invalidate(); sleepTimer = nil; sleepUntil = nil; pause(); return }
    guard !interrupted else { errorMessage = "通话或其他音频正在占用，结束后再继续"; publish(); return }
    if player.currentItem?.status == .failed { load(resume: true); return }
    do {
      let session = AVAudioSession.sharedInstance()
      if session.category != .playback || session.mode != .moviePlayback || !session.categoryOptions.isEmpty {
        try session.setCategory(.playback, mode: .moviePlayback, options: [])
      }
      try session.setActive(true)
      wantsPlayback = true; errorMessage = ""
      if duration > 0 && position >= duration - 0.1 { load(resume: false); return }
      resumeEngine()
      publish()
    } catch { fail("暂时无法取得音频播放权限：\(error.localizedDescription)") }
  }

  func pause() {
    cancelIntroDetection()
    wantsPlayback = false; resumeAfterInterruption = false
    scrubbing = false
    pauseEngine(); persist(); publish()
  }

  func seek(_ seconds: Double, completion: @escaping (Bool) -> Void = { _ in }) {
    guard timelineReady, !seekFault, seconds.isFinite, duration > 0, mediaKit?.seekable ?? true else { completion(false); return }
    cancelIntroDetection()
    introSkipped = 0
    scrubbing = false
    pauseEngine()
    enqueueSeek(seconds, precise: true) { [weak self] finished in
      guard let self = self else { completion(false); return }
      if finished {
        if self.wantsPlayback && !self.interrupted && !self.scrubbing { self.play() }
        self.persist()
      }
      self.publish(); completion(finished)
    }
  }

  func previewSeek(_ seconds: Double) {
    guard timelineReady, !seekFault, seconds.isFinite, duration > 0, mediaKit?.seekable ?? true else { return }
    if !scrubbing { cancelIntroDetection(); scrubbing = true; pauseEngine() }
    if mediaKit != nil { publish(); return }
    enqueueSeek(seconds, precise: false) { _ in }
  }

  func cancelScrub() {
    guard scrubbing else { return }
    scrubbing = false
    seek(position)
  }

  private func enqueueSeek(_ seconds: Double, precise: Bool, done: @escaping (Bool) -> Void) {
    guard timelineReady, !seekFault else { done(false); return }
    seekSequence += 1
    let previous = pendingSeek
    pendingSeek = (seekSequence, min(max(0, duration - 0.001), max(0, seconds)), precise, done)
    previous?.done(false)
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
      request.done(finished && !superseded)
      if !finished && !superseded {
        self.fail("无法完成定位，请点击重试重新打开媒体")
        return
      }
      self.runNextSeek(); self.publish()
    }
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.generation == token, self.activeSeek == request.id else { return }
      self.mediaKit?.recordDiagnostic("seek timeout session=\(token) request=\(request.id)")
      self.seekFault = true
      self.cancelSeeks()
      self.fail("定位超时，请点击重试重新打开媒体")
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
    publish()
  }

  private func cancelSeeks() {
    if isSeeking { mediaKit?.recordDiagnostic("seek cancelled session=\(generation) active=\(activeSeek ?? -1) pending=\(pendingSeek?.id ?? -1)") }
    seekTimeout?.cancel(); seekTimeout = nil
    let active = activeSeekCompletion; let pending = pendingSeek
    activeSeek = nil; activeSeekCompletion = nil; pendingSeek = nil; scrubbing = false
    player.currentItem?.cancelPendingSeeks()
    active?(false); pending?.done(false)
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
    index = next; load(resume: false)
  }

  private func ended() {
    guard wantsPlayback else { return }
    if let path = currentPath {
      var record = library.records[path] ?? [:]
      if rememberProgress {
        record["position"] = 0.0; record["completed"] = true
        record["duration"] = duration; record["timelineOrigin"] = timelineOrigin
      }
      library.records[path] = record; library.save()
    }
    if let a = aPoint, bPoint != nil { seek(a); return }
    if !continuous { wantsPlayback = false; pauseEngine(); publish(); return }
    if mode == "one" { load(resume: false); return }
    if index == queue.count - 1 && mode == "sequence" { wantsPlayback = false; publish(); return }
    skip(1)
  }

  private static func normalizedRate(_ value: Double) -> Float {
    guard value.isFinite else { return 1 }
    return Float((min(3, max(0.5, value)) * 20).rounded() / 20)
  }

  private static func normalizedJumpSeconds(_ value: Int) -> Int {
    min(300, max(1, value))
  }

  func configure(_ values: [String: Any]) throws {
    if let value = values["rememberProgress"] as? Bool {
      rememberProgress = value
      UserDefaults.standard.set(value, forKey: "playback.rememberProgress")
      if value { persist() }
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
    if values["background"] != nil {
      background = true
      player.audiovisualBackgroundPlaybackPolicy = .continuesIfPossible
    }
    if let value = values["autoResume"] as? Bool { autoResume = value }
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
        guard let a = aPoint, position > a + 0.5 else { throw LibraryFailure.message("请先设置 A 点，B 点需在 A 点至少半秒之后") }
        bPoint = position
        restartAt = a
      default: aPoint = nil; bPoint = nil
      }
      updateLoop()
      if let restartAt = restartAt { seek(restartAt) }
    }
    let defaults = UserDefaults.standard
    defaults.set(mode, forKey: "playback.mode")
    defaults.set(continuous, forKey: "playback.continuous"); defaults.set(true, forKey: "playback.background"); defaults.set(autoResume, forKey: "playback.resume")
    publish()
  }

  func restoreBrightness() {
    if let value = savedBrightness { UIScreen.main.brightness = value; savedBrightness = nil }
  }

  func attachSurface(_ view: PlayerSurface) {
    surface = view
    view.onLayout = nil
    if mediaKit != nil { view.videoLayer.player = nil; view.caption.isHidden = true; return }
    view.videoLayer.isHidden = false
    view.videoLayer.player = player
    view.videoLayer.videoGravity = fit == "fill" ? .resizeAspectFill : fit == "stretch" ? .resize : .resizeAspect
    view.caption.text = subtitleText
    view.caption.isHidden = subtitleText.isEmpty
  }

  private func tick() {
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

  func persist() {
    guard timelineReady, !detectingIntro, !loading, !isSeeking, !scrubbing, let path = currentPath else { return }
    var record = library.records[path] ?? [:]
    if rememberProgress {
      record["position"] = duration > 0 && position >= duration - 0.5 ? 0.0 : position
      record["duration"] = duration
      record["timelineOrigin"] = timelineOrigin
    }
    record["lastPlayed"] = Date().timeIntervalSince1970
    library.records[path] = record; library.save(); lastSave = Date()
  }

  private func fail(_ message: String) {
    finishTrackSelection("播放状态已变化，请重新选择轨道")
    cancelIntroDetection()
    openingTimeout?.cancel(); cancelSeeks(); generation += 1
    seekFault = true; timelineReady = false
    loading = false; wantsPlayback = false; pauseEngine(); errorMessage = message; publish()
  }

  private func interruption(_ note: Notification) {
    guard let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
          let type = AVAudioSession.InterruptionType(rawValue: raw) else { return }
    if type == .began {
      resumeAfterInterruption = wantsPlayback
      interrupted = true; scrubbing = false; pauseEngine(); persist(); publish()
    } else {
      interrupted = false
      let options = AVAudioSession.InterruptionOptions(rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
      let resume = resumeAfterInterruption && wantsPlayback && autoResume && options.contains(.shouldResume)
      resumeAfterInterruption = false
      if resume { play() } else { wantsPlayback = false; errorMessage = "音频中断已结束，点击播放继续"; publish() }
    }
  }

  private func trackDescriptions(_ options: [AVMediaSelectionOption], fallback: [AVPlayerItemTrack]) -> [[String: Any]] {
    if !options.isEmpty {
      return options.enumerated().map { ["index": $0.offset, "name": $0.element.displayName] }
    }
    return fallback.enumerated().map { index, itemTrack in
      let language = itemTrack.assetTrack?.extendedLanguageTag ?? itemTrack.assetTrack?.languageCode ?? "und"
      return ["index": index, "name": "轨道 \(index + 1) · \(language)"]
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
      throw LibraryFailure.message("媒体已变化或尚未就绪，请重新打开轨道列表")
    }
    guard ["audio", "subtitle"].contains(kind), trackSelection == nil else {
      throw LibraryFailure.message("轨道请求无效或正在切换，请稍后重试")
    }
    let disabled = kind == "subtitle" && index == -1 && id == nil
    guard disabled || index >= 0 else { throw LibraryFailure.message("轨道请求无效，请重新选择") }
    if let mediaKit = mediaKit {
      guard disabled || id?.isEmpty == false else { throw LibraryFailure.message("轨道身份已失效，请重新打开轨道列表") }
      guard mediaKit.select(kind: kind, trackID: disabled ? nil : id) else { throw LibraryFailure.message("轨道已变化，请重新选择") }
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
      finishTrackSelection("媒体已变化，请重新选择轨道"); return
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
      finishTrackSelection("未确认轨道切换，请查看实际选中项后重试")
    }
  }

  private func selectTrack(kind: String, index: Int) throws {
    if let mediaKit = mediaKit {
      guard mediaKit.select(kind: kind, index: index) else { throw LibraryFailure.message("音轨或字幕已变化，请重新选择") }
      if kind == "subtitle" { cues = []; subtitleName = ""; surface?.caption.text = ""; surface?.caption.isHidden = true }
      publish(); return
    }
    guard let item = player.currentItem else { return }
    let options = kind == "audio" ? audioOptions : subtitleOptions
    let fallback = kind == "audio" ? fallbackAudio : fallbackSubtitles
    let count = options.isEmpty ? fallback.count : options.count
    guard index == -1 || (0..<count).contains(index) else { throw LibraryFailure.message("音轨或字幕已变化，请重新选择") }
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

  func loadSubtitle(path: String) throws {
    guard trackSelection == nil else { throw LibraryFailure.message("正在切换轨道，请稍后加载字幕") }
    let url = try library.url(path)
    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
    guard size <= 10 * 1024 * 1024 else { throw LibraryFailure.message("字幕文件过大，请选择小于 10 MB 的字幕文件") }
    if let mediaKit = mediaKit {
      guard mediaKit.addSubtitle(url: url) else { throw LibraryFailure.message("MediaKit 无法加载该字幕") }
      cues = []; subtitleName = url.lastPathComponent; surface?.caption.isHidden = true; publish(); return
    }
    guard ["srt", "vtt"].contains(url.pathExtension.lowercased()) else {
      throw LibraryFailure.message("当前原生引擎支持外置 SRT / VTT；ASS / PGS 需在 MediaKit 媒体中使用")
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
    guard !parsed.isEmpty else { throw LibraryFailure.message("字幕没有可读时间轴，请使用 UTF-8 编码的 SRT 或 VTT") }
    if detectingIntro { seek(position) }
    try selectTrack(kind: "subtitle", index: -1)
    cues = parsed.sorted { $0.start < $1.start }; subtitleName = URL(fileURLWithPath: path).lastPathComponent; publish()
  }

  func stopForMutation(_ path: String) {
    if queue.contains(where: { $0 == path || $0.hasPrefix(path + "/") }) {
      finishTrackSelection("媒体已关闭，请重新选择轨道")
      pause(); cancelSeeks(); clearBoundary(); openingTimeout?.cancel(); generation += 1
      discardMediaKitPiP()
      mediaKit?.stopPlayback(); mediaKit = nil
      player.replaceCurrentItem(with: nil)
      timelineReady = false; timelineOrigin = 0
      queue = []; index = 0; aPoint = nil; bPoint = nil; cues = []; loading = false
      subtitleName = ""; subtitleText = ""; surface?.caption.text = ""; surface?.caption.isHidden = true
      sleepTimer?.invalidate(); sleepTimer = nil; sleepUntil = nil; errorMessage = ""
      discardAVPlayerPiP()
      publish()
    }
  }

  private func scheduleOpenTimeout(token: Int) {
    openingTimeout?.cancel()
    let timeout = DispatchWorkItem { [weak self] in
      guard let self = self, self.generation == token, !self.timelineReady else { return }
      self.fail("打开媒体超时，请检查文件是否完整下载或复制后重试")
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
    guard !fallbackUsed, mediaFailure else { fail("无法播放：\(detail.localizedDescription)"); return }
    fallbackUsed = true
    engineNotice = "当前媒体改用兼容引擎播放"
    openMediaKit(url: url, resume: resume, token: token)
  }

  private func openMediaKit(url: URL, resume: Bool, token: Int) {
    guard generation == token else { return }
    cancelIntroDetection()
    clearBoundary()
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(.playback, mode: .moviePlayback, options: [])
      try session.setActive(true)
    } catch { fail("暂时无法取得音频播放权限：\(error.localizedDescription)"); return }
    cancelSeeks()
    player.pause(); player.replaceCurrentItem(with: nil)
    observations = Array(observations.prefix(1))
    timelineReady = false; timelineOrigin = 0; preparedMediaKit = false
    pendingResume = resume; loading = true
    guard let transport = mediaKitTransport else { fail("media_kit 通道尚未就绪"); return }
    let engine = LeeMediaKitEngine(transport: transport)
    mediaKit = engine
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
    if engine.ready && engine.duration > 0 && !preparedMediaKit {
      preparedMediaKit = true; timelineReady = true; openingTimeout?.cancel()
      var record = library.records[currentPath ?? ""] ?? [:]
      let saved = (record["position"] as? NSNumber)?.doubleValue ?? 0
      let previousOrigin = (record["timelineOrigin"] as? NSNumber)?.doubleValue ?? 0
      let sourceTime = saved + previousOrigin
      let start = rememberProgress && pendingResume && sourceTime.isFinite && sourceTime > 0 && sourceTime < duration - 2 ? sourceTime : 0
      if rememberProgress, let path = currentPath {
        record["position"] = start; record["duration"] = duration; record["timelineOrigin"] = 0.0
        library.records[path] = record; library.save()
      }
      loading = false
      if engine.seekable {
        finishStart(start, token: introToken, itemGeneration: token)
      } else {
        engineNotice = "此媒体不支持定位，已从开头播放"
        if wantsPlayback && !interrupted { play() }
        publish()
      }
      return
    }
    if engine.ended && !isSeeking && !scrubbing { ended(); return }
  }

  func receiveMediaKitState(_ state: [String: Any]) {
    guard let engine = mediaKit, state["engineId"] as? String == engine.id else { return }
    engine.update(state)
  }

  func startPiP(delegate: AVPictureInPictureControllerDelegate, requestID: String? = nil) throws {
    guard retiringPiP.isEmpty else { throw LibraryFailure.message("画中画正在结束，请稍后重试") }
    guard !mediaIsAudio else { throw LibraryFailure.message("纯音频可在后台播放，无需画中画") }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      throw LibraryFailure.message("当前设备不支持画中画")
    }
    if let mediaKit = mediaKit {
      guard !mediaKitPiPPreparing, mediaKitPiP == nil, !mediaKitPiPRestoring else {
        throw LibraryFailure.message("画中画正在处理中，请勿连续点击")
      }
      guard let requestID = requestID, !requestID.isEmpty else {
        throw LibraryFailure.message("画中画请求无效，请重试")
      }
      mediaKitPiPPreparing = true
      mediaKitPiPRequestID = requestID
      let timeout = DispatchWorkItem { [weak self, weak mediaKit] in
        guard let self = self, let mediaKit = mediaKit,
              self.mediaKit === mediaKit, self.mediaKitPiPPreparing,
              self.mediaKitPiPRequestID == requestID else { return }
        self.mediaKitPiPPreparing = false
        self.mediaKitPiPRequestID = nil
        self.mediaKitPiPPreparationTimeout = nil
        self.notice?("画中画准备超时，请稍后重试")
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
          self.notice?("画中画启动失败，请稍后重试")
          self.publish()
        }
      }
    } else {
      if pipRequesting { throw LibraryFailure.message("画中画正在准备中，请勿连续点击") }
      guard let videoLayer = surface?.videoLayer, videoLayer.player === player else {
        throw LibraryFailure.message("当前视频画面尚未就绪，请稍后重试")
      }
      guard let controller = pip ?? AVPictureInPictureController(playerLayer: videoLayer) else {
        throw LibraryFailure.message("无法创建系统画中画控制器")
      }
      cancelPendingAVPlayerPiP()
      controller.delegate = delegate
      controller.canStartPictureInPictureAutomaticallyFromInline = false
      pip = controller
      let timeout = DispatchWorkItem { [weak self, weak controller] in
        guard let self = self, let controller = controller,
              self.pip === controller, !self.pipStartIssued else { return }
        self.cancelPendingAVPlayerPiP()
        self.notice?("当前视频画中画准备超时，请稍后重试")
        self.publish()
      }
      pipStartTimeout = timeout
      DispatchQueue.main.asyncAfter(deadline: .now() + 3, execute: timeout)
      pipPossibleObservation = controller.observe(\.isPictureInPicturePossible,
                                                   options: [.initial, .new]) { [weak self, weak controller] _, change in
        guard change.newValue == true else { return }
        DispatchQueue.main.async {
          guard let self = self, let controller = controller,
                self.pip === controller, self.pipStartTimeout != nil, !self.pipStartIssued else { return }
          self.pipStartIssued = true
          self.pipPossibleObservation?.invalidate()
          self.pipPossibleObservation = nil
          self.pipStartTimeout?.cancel()
          self.pipStartTimeout = nil
          let activationTimeout = DispatchWorkItem { [weak self, weak controller] in
            guard let self = self, let controller = controller, self.pip === controller else { return }
            if controller.isPictureInPictureActive {
              self.pipActivationTimeout = nil
              self.publish()
              return
            }
            self.retirePiP(controller)
            self.cancelPendingAVPlayerPiP()
            self.pip = nil
            self.notice?("系统未能启动画中画，请重试")
            self.publish()
          }
          self.pipActivationTimeout = activationTimeout
          DispatchQueue.main.asyncAfter(deadline: .now() + 8, execute: activationTimeout)
          controller.startPictureInPicture()
        }
      }
      publish()
    }
  }

  func finishAVPlayerPiP(_ controller: AVPictureInPictureController) {
    guard pip === controller else { return }
    cancelPendingAVPlayerPiP()
    controller.delegate = nil
    pip = nil
    publish()
  }

  func didStartAVPlayerPiP(_ controller: AVPictureInPictureController) {
    guard pip === controller else { return }
    pipActivationTimeout?.cancel()
    pipActivationTimeout = nil
    publish()
  }

  private func cancelPendingAVPlayerPiP() {
    pipPossibleObservation?.invalidate()
    pipPossibleObservation = nil
    pipStartTimeout?.cancel()
    pipStartTimeout = nil
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
      notice?("画中画准备期间播放页面已关闭，请重试播放")
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
      renderer.playRequested = { [weak self] in self?.play() }
      renderer.diagnostic = { [weak engine = mediaKit] message in engine?.recordDiagnostic(message) }
      renderer.pauseRequested = { [weak self] in self?.pause() }
      renderer.startTimedOut = { [weak self, weak renderer] in
        guard let self = self, let renderer = renderer, self.mediaKitPiP === renderer else { return }
        self.retirePiP(renderer.controller, renderer: renderer)
        self.mediaKitPiP = nil
        self.restoreMediaKitVideoOutput(successNotice: "画中画未能启动，已重新连接视频输出")
      }
      renderer.seekRequested = { [weak self] seconds in self?.seek(seconds) }
      renderer.positionProvider = { [weak self] in self?.position ?? 0 }
      renderer.durationProvider = { [weak self] in self?.duration ?? 0 }
      renderer.playingProvider = { [weak self] in self?.enginePlaying ?? false }
      renderer.rateProvider = { [weak self] in Double(self?.rate ?? 1) }
      mediaKitPiP = renderer
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
      notice?("画中画未能安全接管视频输出，请重试播放")
      publish()
      completion(false)
    }
  }

  func finishMediaKitPiP(_ controller: AVPictureInPictureController) {
    guard let renderer = mediaKitPiP, renderer.controller === controller else { return }
    renderer.stop()
    mediaKitPiP = nil
    restoreMediaKitVideoOutput(successNotice: nil)
  }

  func ownsMediaKitPiP(_ controller: AVPictureInPictureController) -> Bool {
    mediaKitPiP?.controller === controller
  }

  private func restoreMediaKitVideoOutput(successNotice: String?) {
    guard !mediaKitPiPRestoring else { return }
    guard let mediaKit = mediaKit else { mediaKitPiPRestoring = false; publish(); return }
    mediaKitPiPRestoring = true
    publish()
    mediaKit.restoreVideoOutput { [weak self, weak mediaKit] success in
      DispatchQueue.main.async {
        guard let self = self, let mediaKit = mediaKit, self.mediaKit === mediaKit else { return }
        self.mediaKitPiPRestoring = false
        if success {
          if let successNotice = successNotice { self.notice?(successNotice) }
          self.publish()
        } else {
          self.fail("画中画退出后视频画面恢复失败，请重新打开媒体")
        }
      }
    }
  }

  private func discardMediaKitPiP() {
    mediaKitPiPPreparationTimeout?.cancel()
    mediaKitPiPPreparationTimeout = nil
    mediaKitPiPPreparing = false
    mediaKitPiPRequestID = nil
    if let renderer = mediaKitPiP { retirePiP(renderer.controller, renderer: renderer) }
    mediaKitPiP = nil
    mediaKitPiPRestoring = false
  }

  private func clearBoundary() {
    if let observer = boundaryObserver { player.removeTimeObserver(observer); boundaryObserver = nil }
  }

  private func updateLoop() {
    clearBoundary()
    if let mediaKit = mediaKit {
      let success = mediaKit.setLoop(from: aPoint ?? -1, to: bPoint ?? -1)
      if !success && bPoint != nil { errorMessage = "当前媒体无法设置 A–B 循环"; aPoint = nil; bPoint = nil }
      return
    }
    guard let a = aPoint, let b = bPoint else { return }
    let token = generation
    boundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: CMTime(seconds: b, preferredTimescale: 600))], queue: .main) { [weak self] in
      guard let self = self, self.generation == token, self.wantsPlayback, !self.interrupted, !self.scrubbing, !self.isSeeking else { return }
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
    bind(center.playCommand) { [weak self] _ in guard let self = self, self.currentPath != nil else { return .noSuchContent }; self.play(); return .success }
    bind(center.pauseCommand) { [weak self] _ in self?.pause(); return .success }
    bind(center.togglePlayPauseCommand) { [weak self] _ in guard let self = self else { return .commandFailed }; self.wantsPlayback ? self.pause() : self.play(); return .success }
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
      MPNowPlayingInfoPropertyPlaybackRate: enginePlaying ? rate : 0,
      MPNowPlayingInfoPropertyDefaultPlaybackRate: rate]
  }

  private static func prefersMediaKit(_ url: URL) -> Bool {
    ["mkv", "flv", "avi", "webm", "ts", "m2ts", "mts", "mpeg", "mpg", "wmv", "vob",
     "ogg", "opus", "wma", "ape", "dts", "ac3", "eac3"].contains(url.pathExtension.lowercased())
  }
}

/// Removes only a shared leading absence of media, never encoded black frames.
/// Runs on assetPreparation; the source file is only referenced, never rewritten.
private enum PlaybackTimeline {
  static func prepare(url: URL) throws -> (asset: AVAsset, origin: Double) {
    let source = AVURLAsset(url: url, options: [AVURLAssetPreferPreciseDurationAndTimingKey: true])
    let tracks = source.tracks
    let relevant = tracks.filter {
      [.video, .audio, .subtitle, .text, .closedCaption].contains($0.mediaType)
    }
    guard !relevant.isEmpty, source.duration.seconds.isFinite else { return (source, 0) }
    var starts: [CMTime] = []
    for track in relevant {
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
      origin.seconds > 0.15, CMTimeCompare(origin, source.duration) < 0 else { return (source, 0) }
    let composition = AVMutableComposition()
    // Copy references with the original common clock first, then remove the shared gap.
    // This preserves delayed video/audio starts relative to one another.
    for track in tracks {
      guard let target = composition.addMutableTrack(withMediaType: track.mediaType,
        preferredTrackID: track.trackID) else {
        throw LibraryFailure.message("无法保留媒体轨道，未调整时间轴")
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
  var videoLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  let caption = UILabel()
  var onLayout: (() -> Void)?
  override func layoutSubviews() { super.layoutSubviews(); onLayout?() }
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
