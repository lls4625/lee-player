import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var developerTipPurchase: DeveloperTipPurchase?
  private var appChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    let appChannel = FlutterMethodChannel(
      name: "lei.player/app",
      binaryMessenger: engineBridge.applicationRegistrar.messenger()
    )
    appChannel.setMethodCallHandler { call, result in
      guard call.method == "openUrl" else {
        result(FlutterMethodNotImplemented)
        return
      }
      guard
        let arguments = call.arguments as? [String: Any],
        let value = arguments["url"] as? String,
        let url = URL(string: value),
        url.scheme?.lowercased() == "https",
        url.host?.isEmpty == false
      else {
        result(false)
        return
      }
      UIApplication.shared.open(url, options: [:]) { opened in
        result(opened)
      }
    }
    self.appChannel = appChannel
    developerTipPurchase = DeveloperTipPurchase(
      messenger: engineBridge.applicationRegistrar.messenger()
    )
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "LeiPlayer") {
      PlayerBridge.register(with: registrar)
    }
  }
}
