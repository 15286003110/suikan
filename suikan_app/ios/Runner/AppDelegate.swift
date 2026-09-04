import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    // iOS 后台播放前提：音频会话必须是 playback 类别并激活，否则退后台即被
    // 系统挂起（手动纯音频/后台播放都会"返回桌面就停"）。这里只声明类别，
    // 不抢音频；真正激活在播放开始时由 SuikanAudioSession.activate() 完成。
    SuikanAudioSession.shared.configure()
    // 传统路径：window.rootViewController 可得时注册（部分场景仍会走这里）
    if let controller = window?.rootViewController as? FlutterViewController {
      registerNotificationChannel(on: controller.binaryMessenger)
      registerAudioChannel(on: controller.binaryMessenger)
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    // Flutter 3.47 隐式引擎路径：Scene 生命周期下 window?.rootViewController
    // 常常拿不到，导致上面传统路径的通道注册整个跳过（开播通知静默失效的
    // 元凶）。这里从 registrar 拿运行引擎的 messenger，最可靠。
    if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "SuikanChannels") {
      registerNotificationChannel(on: registrar.messenger())
      registerAudioChannel(on: registrar.messenger())
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

  // 音频会话通道：Dart 侧通知"开始/停止播放"以便激活/释放会话；
  // 原生侧把"来电等中断结束"回传给 Dart 恢复播放。
  private func registerAudioChannel(on messenger: FlutterBinaryMessenger) {
    let channel = FlutterMethodChannel(
      name: "suikan/audio",
      binaryMessenger: messenger
    )
    channel.setMethodCallHandler { call, result in
      switch call.method {
      case "activate":
        SuikanAudioSession.shared.activate()
        result(nil)
      case "deactivate":
        SuikanAudioSession.shared.deactivate()
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }
    SuikanAudioSession.shared.onInterruptionEndedShouldResume = { shouldResume in
      channel.invokeMethod("onInterruptionEnded", arguments: shouldResume)
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
