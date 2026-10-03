import Flutter
import UIKit
import UniformTypeIdentifiers
import AVKit

final class PlayerBridge: NSObject, FlutterPlugin, FlutterStreamHandler, UIDocumentPickerDelegate, AVPictureInPictureControllerDelegate {
  private let library: CourseLibrary
  private let playback: PlaybackService
  private let work = DispatchQueue(label: "雷player.library", qos: .userInitiated)
  private var sink: FlutterEventSink?
  private var importResult: FlutterResult?
  private var importParent = ""
  private var busy = false
  private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
  private var pipRestoreCompletion: ((Bool) -> Void)?
  private var pipRestoreToken: UUID?
  private var pendingMediaKitPiPSourceView: UIView?
  private var pendingMediaKitPiPToken: UUID?
  private let registrar: FlutterPluginRegistrar
  private let mediaKitChannel: FlutterMethodChannel

  private init(registrar: FlutterPluginRegistrar, library: CourseLibrary) {
    self.registrar = registrar; self.library = library; playback = PlaybackService(library: library)
    mediaKitChannel = FlutterMethodChannel(name: "lei.player/media_kit", binaryMessenger: registrar.messenger())
    super.init()
    playback.pipDelegate = self
    playback.mediaKitTransport = { [weak self] method, arguments, completion in
      guard let self = self else { completion(false); return }
      self.mediaKitChannel.invokeMethod(method, arguments: arguments) { value in
        completion((value as? Bool) == true)
      }
    }
    mediaKitChannel.setMethodCallHandler { [weak self] call, result in
      guard let self = self else { result(false); return }
      guard let arguments = call.arguments as? [String: Any] else {
        result(FlutterMethodNotImplemented); return
      }
      if call.method == "pipReady" {
        guard let requestID = arguments["requestId"] as? String,
          let pendingToken = self.pendingMediaKitPiPToken,
          requestID == pendingToken.uuidString else {
          result(false); return
        }
        guard let handle = (arguments["handle"] as? NSNumber)?.int64Value,
          let engineId = arguments["engineId"] as? String,
          engineId == self.playback.mediaKitEngineId,
          let sourceView = self.pendingMediaKitPiPSourceView,
          sourceView.window != nil else {
          self.pendingMediaKitPiPSourceView = nil
          self.pendingMediaKitPiPToken = nil
          result(false); return
        }
        self.pendingMediaKitPiPSourceView = nil
        self.pendingMediaKitPiPToken = nil
        self.playback.startMediaKitPiP(handle: handle, requestID: requestID,
                                       sourceView: sourceView, delegate: self) { success in
          result(success)
        }
        return
      }
      guard call.method == "state" else { result(FlutterMethodNotImplemented); return }
      self.playback.receiveMediaKitState(arguments)
      result(true)
    }
    playback.changed = { [weak self] state in self?.sink?(["type": "player", "state": state]) }
    playback.restoreRequested = { [weak self] in self?.sink?(["type": "openPlayer"]) }
    playback.notice = { [weak self] message in self?.sink?(["type": "notice", "message": message]) }
  }

  static func register(with registrar: FlutterPluginRegistrar) {
    do {
      let instance = PlayerBridge(registrar: registrar, library: try CourseLibrary())
      let channel = FlutterMethodChannel(name: "lei.player/methods", binaryMessenger: registrar.messenger())
      registrar.addMethodCallDelegate(instance, channel: channel)
      FlutterEventChannel(name: "lei.player/events", binaryMessenger: registrar.messenger()).setStreamHandler(instance)
      registrar.register(VideoFactory(service: instance.playback), withId: "lei.player/video")
    } catch {
      let channel = FlutterMethodChannel(name: "lei.player/methods", binaryMessenger: registrar.messenger())
      channel.setMethodCallHandler { _, result in result(FlutterError(code: "storage", message: "课程库初始化失败：\(error.localizedDescription)", details: nil)) }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; playback.publish(); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

  private func failure(_ error: Error) -> FlutterError {
    FlutterError(code: "player", message: error.localizedDescription, details: nil)
  }

  private func perform(_ result: @escaping FlutterResult, operation: @escaping () throws -> Any?, completion: ((Any?) -> Void)? = nil) {
    guard !busy else { result(failure(LibraryFailure.message("文件操作进行中，请稍后重试"))); return }
    busy = true
    work.async {
      do {
        let value = try operation()
        DispatchQueue.main.async { self.busy = false; completion?(value); result(value) }
      } catch { DispatchQueue.main.async { self.busy = false; result(self.failure(error)) } }
    }
  }

  func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    let args = call.arguments as? [String: Any] ?? [:]
    do {
      switch call.method {
      case "appearance":
        result(UserDefaults.standard.string(forKey: "appearance.mode") ?? "system"); return
      case "language":
        result(UserDefaults.standard.string(forKey: "language.mode") ?? "system"); return
      case "setLanguage":
        guard let value = args["value"] as? String,
          ["system", "zh-Hans", "zh-Hant", "ja", "en"].contains(value) else {
          throw LibraryFailure.message("Invalid language option")
        }
        UserDefaults.standard.set(value, forKey: "language.mode")
        result(value); return
      case "setAppearance":
        guard let value = args["value"] as? String, ["system", "light", "dark"].contains(value) else {
          throw LibraryFailure.message("无效的外观选项")
        }
        UserDefaults.standard.set(value, forKey: "appearance.mode")
        result(value); return
      case "libraryPreferences":
        let defaults = UserDefaults.standard
        result([
          "layout": defaults.string(forKey: "library.layout") ?? "list",
          "sort": defaults.string(forKey: "library.sort") ?? "name",
          "ascending": defaults.object(forKey: "library.sortAscending") as? Bool ?? true,
        ]); return
      case "setLibraryPreferences":
        let defaults = UserDefaults.standard
        let layout = args["layout"] as? String ?? defaults.string(forKey: "library.layout") ?? "list"
        let sort = args["sort"] as? String ?? defaults.string(forKey: "library.sort") ?? "name"
        let ascending = args["ascending"] as? Bool
          ?? (defaults.object(forKey: "library.sortAscending") as? Bool) ?? true
        guard ["list", "grid"].contains(layout), ["name", "type", "size", "date"].contains(sort) else {
          throw LibraryFailure.message("无效的课程库显示或排序选项")
        }
        defaults.set(layout, forKey: "library.layout")
        defaults.set(sort, forKey: "library.sort")
        defaults.set(ascending, forKey: "library.sortAscending")
        result(["layout": layout, "sort": sort, "ascending": ascending]); return
      case "scan":
        perform(result, operation: { try self.library.scan() }); return
      case "records": result(library.records); return
      case "state": result(playback.snapshot()); return
      case "playbackInfo": result(playback.playbackInfo()); return
      case "import":
        guard !busy && importResult == nil else { throw LibraryFailure.message("已有文件操作正在进行") }
        guard let controller = topController() else { throw LibraryFailure.message("无法打开系统文件选择器") }
        importParent = args["parent"] as? String ?? ""
        _ = try library.url(importParent, allowRoot: true)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: args["folder"] as? Bool == true ? [.folder] : [.item], asCopy: false)
        picker.allowsMultipleSelection = args["folder"] as? Bool != true
        let appearance = UserDefaults.standard.string(forKey: "appearance.mode") ?? "system"
        picker.overrideUserInterfaceStyle = appearance == "dark" ? .dark : appearance == "light" ? .light : .unspecified
        picker.delegate = self
        importResult = result
        controller.present(picker, animated: true); return
      case "cancelImport": library.cancelImport()
      case "createFolder":
        let parent = args["parent"] as? String ?? "", name = args["name"] as? String ?? ""
        perform(result, operation: { try self.library.createFolder(parent: parent, name: name); return nil }); return
      case "move":
        guard !busy && importResult == nil else { throw LibraryFailure.message("请等待当前文件操作完成") }
        let path = args["path"] as? String ?? "", parent = args["parent"] as? String ?? "", name = args["name"] as? String ?? ""
        playback.stopForMutation(path)
        perform(result, operation: { try self.library.move(path: path, parent: parent, name: name) }, completion: { value in
          if let new = value as? String { self.library.remapRecords(from: path, to: new) }
        }); return
      case "trash":
        guard !busy && importResult == nil else { throw LibraryFailure.message("请等待当前文件操作完成") }
        let path = args["path"] as? String ?? ""
        playback.stopForMutation(path)
        perform(result, operation: { try self.library.trash(path: path) }); return
      case "trashList": perform(result, operation: { try self.library.trashList() }); return
      case "restore":
        let token = args["token"] as? String ?? ""
        perform(result, operation: { try self.library.restore(token: token); return nil }); return
      case "emptyTrash": perform(result, operation: { try self.library.emptyTrash(); return nil }); return
      case "favorite":
        let path = args["path"] as? String ?? ""
        _ = try library.url(path)
        var record = library.records[path] ?? [:]
        record["favorite"] = args["value"] as? Bool ?? false
        library.records[path] = record; library.save()
      case "clearHistory":
        for path in Array(library.records.keys) {
          library.records[path]?.removeValue(forKey: "lastPlayed")
          library.records[path]?.removeValue(forKey: "position")
          library.records[path]?.removeValue(forKey: "completed")
        }
        library.save()
      case "open":
        try playback.open(paths: args["paths"] as? [String] ?? [], selected: args["index"] as? Int ?? 0, resume: args["resume"] as? Bool ?? true)
      case "play": playback.play()
      case "pause": playback.pause()
      case "seek":
        playback.seek(args["seconds"] as? Double ?? 0) { finished in result(finished) }; return
      case "previewSeek": playback.previewSeek(args["seconds"] as? Double ?? 0)
      case "cancelScrub": playback.cancelScrub()
      case "next": playback.skip(1)
      case "previous": playback.skip(-1)
      case "configure": try playback.configure(args)
      case "track":
        guard let session = args["generation"] as? Int, let kind = args["kind"] as? String,
          let index = args["index"] as? Int else { throw LibraryFailure.message("请重新打开轨道列表后选择") }
        try playback.requestTrack(kind: kind, index: index, id: args["id"] as? String, session: session) { message in
          if let message = message { result(FlutterError(code: "track", message: message, details: nil)) }
          else { result(true) }
        }
        return
      case "subtitle": try playback.loadSubtitle(path: args["path"] as? String ?? "")
      case "restoreBrightness": playback.restoreBrightness()
      case "pipRestored":
        pipRestoreCompletion?(true)
        pipRestoreCompletion = nil
        pipRestoreToken = nil
      case "pip":
        let pipToken = UUID()
        pendingMediaKitPiPToken = playback.usesMediaKit ? pipToken : nil
        pendingMediaKitPiPSourceView = playback.usesMediaKit ? topController()?.view : nil
        if playback.usesMediaKit {
          guard pendingMediaKitPiPSourceView?.window != nil else {
            pendingMediaKitPiPToken = nil
            pendingMediaKitPiPSourceView = nil
            throw LibraryFailure.message("当前播放页面尚未就绪，请稍后重试")
          }
          DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard self?.pendingMediaKitPiPToken == pipToken else { return }
            self?.pendingMediaKitPiPToken = nil
            self?.pendingMediaKitPiPSourceView = nil
          }
        }
        do {
          try playback.startPiP(delegate: self,
                                requestID: playback.usesMediaKit ? pipToken.uuidString : nil)
        } catch {
          pendingMediaKitPiPSourceView = nil
          pendingMediaKitPiPToken = nil
          throw error
        }
      default: result(FlutterMethodNotImplemented); return
      }
      result(nil)
    } catch { result(failure(error)) }
  }

  func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
    let callback = importResult; importResult = nil; callback?(0)
  }

  func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
    guard let callback = importResult else { return }
    importResult = nil
    guard !urls.isEmpty else { callback(0); return }
    let parent = importParent
    library.beginImport()
    sink?(["type": "import", "name": "正在统计文件与检查空间", "done": 0, "total": 0])
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "课程导入") { [weak self] in
      guard let self = self else { return }
      self.library.cancelImport()
      if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
    }
    perform({ value in
      self.sink?(["type": "importDone"])
      if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
      callback(value)
    }, operation: {
      let paths = try self.library.importFiles(urls, parent: parent) { name, done, total in
        DispatchQueue.main.async { self.sink?(["type": "import", "name": name, "done": done, "total": total]) }
      }
      return ["count": paths.count, "paths": paths] as [String: Any]
    })
  }

  private func topController() -> UIViewController? {
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first { $0.activationState == .foregroundActive }
    var controller = scene?.windows.first(where: { $0.isKeyWindow })?.rootViewController
    while let presented = controller?.presentedViewController { controller = presented }
    return controller
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
    guard sink != nil else {
      pipRestoreCompletion?(false)
      pipRestoreCompletion = nil
      pipRestoreToken = nil
      completionHandler(false)
      return
    }
    pipRestoreCompletion?(false)
    let token = UUID()
    pipRestoreToken = token
    pipRestoreCompletion = completionHandler
    sink?(["type": "openPlayer"])
    DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
      guard self?.pipRestoreToken == token else { return }
      self?.pipRestoreCompletion?(false)
      self?.pipRestoreCompletion = nil
      self?.pipRestoreToken = nil
    }
  }

  func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    if playback.finishRetiringPiP(pictureInPictureController) { return }
    if playback.pip === pictureInPictureController {
      playback.finishAVPlayerPiP(pictureInPictureController)
    } else if playback.ownsMediaKitPiP(pictureInPictureController) {
      playback.finishMediaKitPiP(pictureInPictureController)
    }
  }

  func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    if playback.rejectRetiringPiPStart(pictureInPictureController) { return }
    _ = playback.rejectUnauthorizedAVPlayerPiPStart(pictureInPictureController)
  }

  func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
    if playback.rejectRetiringPiPStart(pictureInPictureController) { return }
    if playback.pip === pictureInPictureController {
      playback.didStartAVPlayerPiP(pictureInPictureController)
    }
  }

  func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController, failedToStartPictureInPictureWithError error: Error) {
    if playback.finishRetiringPiP(pictureInPictureController) { return }
    guard playback.pip === pictureInPictureController || playback.ownsMediaKitPiP(pictureInPictureController) else { return }
    sink?(["type": "notice", "message": "画中画启动失败：\(error.localizedDescription)"])
    if playback.pip === pictureInPictureController {
      playback.finishAVPlayerPiP(pictureInPictureController)
    } else if playback.ownsMediaKitPiP(pictureInPictureController) {
      playback.finishMediaKitPiP(pictureInPictureController)
    }
  }
}

final class VideoFactory: NSObject, FlutterPlatformViewFactory {
  let service: PlaybackService
  init(service: PlaybackService) { self.service = service }
  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64, arguments args: Any?) -> FlutterPlatformView {
    VideoPlatformView(frame: frame, service: service)
  }
}

final class VideoPlatformView: NSObject, FlutterPlatformView {
  private let container: UIView
  private let service: PlaybackService
  init(frame: CGRect, service: PlaybackService) {
    self.service = service
    container = UIView(frame: frame)
    super.init()
    let surface = service.surface ?? PlayerSurface(frame: container.bounds)
    surface.removeFromSuperview()
    surface.frame = container.bounds
    surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
    container.addSubview(surface)
    service.attachSurface(surface)
  }
  func view() -> UIView { container }
}
