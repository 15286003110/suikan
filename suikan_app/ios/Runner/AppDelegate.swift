import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  private var pipChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // 传统路径：window.rootViewController 可得时注册（部分场景仍会走这里）
    if let controller = window?.rootViewController as? FlutterViewController {
      registerNotificationChannel(on: controller.binaryMessenger)
      registerPip(on: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Flutter 3.47 隐式引擎路径：Scene 生命周期下 window?.rootViewController
    // 常常拿不到，导致上面传统路径的通道注册整个跳过（PiP/开播通知都静默
    // 失效的元凶）。这里从 registrar 拿运行引擎的 messenger，最可靠。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SuikanPipChannel") {
      registerNotificationChannel(on: registrar.messenger())
      registerPip(on: registrar.messenger())
    }
  }

  // MARK: - 通道注册

  private func registerNotificationChannel(on messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "simple_live/live_notifications",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      if call.method == "showLiveStart" {
        let args = call.arguments as? [String: Any]
        let title = args?["title"] as? String ?? "特别关注开播了"
        let body = args?["body"] as? String ?? "点击回到 随看"
        self.showLiveStartNotification(title: title, body: body)
        result(nil)
      } else {
        result(FlutterMethodNotImplemented)
      }
    }
  }

  private func registerPip(on messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "suikan/pip",
      binaryMessenger: messenger
    )
    pipChannel = channel
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "isSupported":
        result(SuikanPiPManager.shared.isSupported)
      case "prepare":
        SuikanPiPManager.shared.prepare()
        result(nil)
      case "start":
        SuikanPiPManager.shared.start()
        result(nil)
      case "stop":
        SuikanPiPManager.shared.stop()
        result(nil)
      case "dispose":
        SuikanPiPManager.shared.dispose()
        result(nil)
      case "isActive":
        result(SuikanPiPManager.shared.isPipActive)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    // PiP 窗口里的播放/暂停 → 通知 Dart 控制 mpv
    SuikanPiPManager.shared.onPlayPause = { playing in
      channel.invokeMethod("onPlayPause", arguments: playing)
    }
    SuikanPiPManager.shared.onPipStateChanged = { active in
      channel.invokeMethod("onPipState", arguments: active)
    }
    // PiP 启动失败/设备不支持等原因 → 弹提示（不再静默）
    SuikanPiPManager.shared.onError = { message in
      channel.invokeMethod("onError", arguments: message)
    }
  }

  // MARK: - 通知

  private func showLiveStartNotification(title: String, body: String) {
    let center = UNUserNotificationCenter.current()
    center.requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
      guard granted else { return }
      let content = UNMutableNotificationContent()
      content.title = title
      content.body = body
      content.sound = .default
      let request = UNNotificationRequest(
        identifier: "simple_live_live_start_\(UUID().uuidString)",
        content: content,
        trigger: nil
      )
      center.add(request, withCompletionHandler: nil)
    }
  }

  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    if #available(iOS 14.0, *) {
      completionHandler([.banner, .list, .sound])
    } else {
      completionHandler([.alert, .sound])
    }
  }

}
