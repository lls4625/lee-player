import Flutter
import UIKit
import UniformTypeIdentifiers
import AVKit

final class PlayerBridge: NSObject, FlutterPlugin, FlutterStreamHandler, UIDocumentPickerDelegate, AVPictureInPictureControllerDelegate {
  private let library: CourseLibrary
  private let playback: PlaybackService
  private let work = DispatchQueue(label: "雷player.library", qos: .userInitiated)
  private var importWork = DispatchQueue(label: "雷player.import", qos: .userInitiated)
  private var sink: FlutterEventSink?
  private var importResult: FlutterResult?
  private var importParent = ""
  private var busy = false
  private var importBusy = false
  private var importToken: UUID?
  private var importCancellation: ImportCancellation?
  private var importWatchdog: DispatchWorkItem?
  private var activeImportResult: FlutterResult?
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
      var completed = false
      let timeoutSeconds: TimeInterval
      switch method {
      case "open": timeoutSeconds = 16
      case "pip": timeoutSeconds = 20
      case "pipRestore": timeoutSeconds = 24
      case "seek": timeoutSeconds = 9
      case "release", "stop": timeoutSeconds = 5
      default: timeoutSeconds = 7
      }
      let timeout = DispatchWorkItem {
        guard !completed else { return }
        completed = true
        completion(false)
      }
      DispatchQueue.main.asyncAfter(deadline: .now() + timeoutSeconds, execute: timeout)
      self.mediaKitChannel.invokeMethod(method, arguments: arguments) { value in
        guard !completed else { return }
        completed = true
        timeout.cancel()
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
    playback.notice = { [weak self] code in self?.sink?(["type": "notice", "code": code]) }
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
      channel.setMethodCallHandler { _, result in
        result(FlutterError(
          code: "library_initialization_failed",
          message: nil,
          details: ["technicalDetail": error.localizedDescription]))
      }
    }
  }

  func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    sink = events; playback.publish(); return nil
  }
  func onCancel(withArguments arguments: Any?) -> FlutterError? { sink = nil; return nil }

  private func failure(_ error: Error) -> FlutterError {
    if let failure = error as? LibraryFailure {
      var details: [String: Any] = ["args": failure.args]
      if let technicalDetail = failure.technicalDetail { details["technicalDetail"] = technicalDetail }
      return FlutterError(code: failure.code, message: nil, details: details)
    }
    return FlutterError(
      code: "operation_failed",
      message: nil,
      details: ["technicalDetail": error.localizedDescription])
  }

  private func perform(_ result: @escaping FlutterResult, allowDuringImport: Bool = false,
                       operation: @escaping () throws -> Any?, completion: ((Any?) -> Void)? = nil) {
    guard !busy, allowDuringImport || !importBusy else {
      result(failure(LibraryFailure.app("file_operation_busy"))); return
    }
    busy = true
    work.async {
      do {
        let value = try operation()
        DispatchQueue.main.async { self.busy = false; completion?(value); result(value) }
      } catch { DispatchQueue.main.async { self.busy = false; result(self.failure(error)) } }
    }
  }

  private func armImportWatchdog(_ token: UUID) {
    importWatchdog?.cancel()
    let watchdog = DispatchWorkItem { [weak self] in
      guard let self = self, self.importToken == token, self.importBusy else { return }
      if let cancellation = self.importCancellation { self.library.cancelImport(cancellation) }
      self.importToken = nil
      self.importCancellation = nil
      self.importBusy = false
      self.importWork = DispatchQueue(label: "雷player.import.\(UUID().uuidString)", qos: .userInitiated)
      let callback = self.activeImportResult
      self.activeImportResult = nil
      self.importWatchdog = nil
      self.finishImportPresentation()
      callback?(self.failure(LibraryFailure.app("import_timeout")))
    }
    importWatchdog = watchdog
    DispatchQueue.main.asyncAfter(deadline: .now() + 120, execute: watchdog)
  }

  private func touchImportWatchdog(_ token: UUID) {
    guard importToken == token, importBusy else { return }
    armImportWatchdog(token)
  }

  private func finishImportPresentation() {
    sink?(["type": "importDone"])
    if backgroundTask != .invalid {
      UIApplication.shared.endBackgroundTask(backgroundTask)
      backgroundTask = .invalid
    }
  }

  private func performImport(_ result: @escaping FlutterResult, token: UUID,
                             operation: @escaping () throws -> Any?) {
    guard !busy, !importBusy else {
      importCancellation = nil
      finishImportPresentation()
      result(failure(LibraryFailure.app("file_operation_busy"))); return
    }
    importBusy = true
    importToken = token
    activeImportResult = result
    armImportWatchdog(token)
    let queue = importWork
    queue.async {
      do {
        let value = try operation()
        DispatchQueue.main.async {
          guard self.importToken == token else { return }
          self.importWatchdog?.cancel(); self.importWatchdog = nil
          self.importToken = nil; self.importCancellation = nil; self.importBusy = false
          let callback = self.activeImportResult; self.activeImportResult = nil
          self.finishImportPresentation()
          callback?(value)
        }
      } catch {
        DispatchQueue.main.async {
          guard self.importToken == token else { return }
          self.importWatchdog?.cancel(); self.importWatchdog = nil
          self.importToken = nil; self.importCancellation = nil; self.importBusy = false
          let callback = self.activeImportResult; self.activeImportResult = nil
          self.finishImportPresentation()
          callback?(self.failure(error))
        }
      }
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
          throw LibraryFailure.app("invalid_language_option")
        }
        UserDefaults.standard.set(value, forKey: "language.mode")
        result(value); return
      case "setAppearance":
        guard let value = args["value"] as? String, ["system", "light", "dark"].contains(value) else {
          throw LibraryFailure.app("invalid_appearance_option")
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
          throw LibraryFailure.app("invalid_library_preferences")
        }
        defaults.set(layout, forKey: "library.layout")
        defaults.set(sort, forKey: "library.sort")
        defaults.set(ascending, forKey: "library.sortAscending")
        result(["layout": layout, "sort": sort, "ascending": ascending]); return
      case "scan":
        perform(result, allowDuringImport: true, operation: { try self.library.scan() }); return
      case "records": result(library.records); return
      case "state": result(playback.snapshot()); return
      case "playbackInfo": result(playback.playbackInfo()); return
      case "import":
        guard !busy && !importBusy && importResult == nil else { throw LibraryFailure.app("file_operation_busy") }
        guard let controller = topController() else { throw LibraryFailure.app("file_picker_unavailable") }
        importParent = args["parent"] as? String ?? ""
        _ = try library.url(importParent, allowRoot: true)
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: args["folder"] as? Bool == true ? [.folder] : [.item], asCopy: false)
        picker.allowsMultipleSelection = args["folder"] as? Bool != true
        let appearance = UserDefaults.standard.string(forKey: "appearance.mode") ?? "system"
        picker.overrideUserInterfaceStyle = appearance == "dark" ? .dark : appearance == "light" ? .light : .unspecified
        picker.delegate = self
        importResult = result
        controller.present(picker, animated: true); return
      case "cancelImport":
        if let cancellation = importCancellation { library.cancelImport(cancellation) }
      case "createFolder":
        let parent = args["parent"] as? String ?? "", name = args["name"] as? String ?? ""
        perform(result, operation: { try self.library.createFolder(parent: parent, name: name); return nil }); return
      case "move":
        guard !busy && importResult == nil else { throw LibraryFailure.app("file_operation_busy") }
        let path = args["path"] as? String ?? "", parent = args["parent"] as? String ?? "", name = args["name"] as? String ?? ""
        perform(result, operation: { try self.library.move(path: path, parent: parent, name: name) }, completion: { value in
          if let new = value as? String {
            self.library.remapRecords(from: path, to: new)
            self.playback.remapQueuePath(from: path, to: new)
          }
        }); return
      case "trash":
        guard !busy && importResult == nil else { throw LibraryFailure.app("file_operation_busy") }
        let path = args["path"] as? String ?? ""
        perform(result, operation: { try self.library.trash(path: path) }, completion: { _ in
          self.playback.stopForMutation(path)
        }); return
      case "trashList": perform(result, allowDuringImport: true, operation: { try self.library.trashList() }); return
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
          let index = args["index"] as? Int else { throw LibraryFailure.app("track_selection_stale") }
        try playback.requestTrack(kind: kind, index: index, id: args["id"] as? String, session: session) { message in
          if let message = message { result(FlutterError(code: message, message: nil, details: nil)) }
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
            throw LibraryFailure.app("player_page_unavailable")
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
    let cancellation = library.beginImport()
    let token = UUID()
    importCancellation = cancellation
    sink?(["type": "import", "nameCode": "import_preparing", "done": 0, "total": 0])
    backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "课程导入") { [weak self] in
      guard let self = self else { return }
      self.library.cancelImport(cancellation)
      if self.backgroundTask != .invalid { UIApplication.shared.endBackgroundTask(self.backgroundTask); self.backgroundTask = .invalid }
    }
    performImport(callback, token: token, operation: {
      let paths = try self.library.importFiles(urls, parent: parent, cancellation: cancellation) { name, done, total in
        DispatchQueue.main.async {
          guard self.importToken == token else { return }
          self.touchImportWatchdog(token)
          self.sink?(["type": "import", "name": name, "done": done, "total": total])
        }
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
    sink?([
      "type": "notice",
      "code": "pip_start_failed",
      "technicalDetail": error.localizedDescription,
    ])
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
