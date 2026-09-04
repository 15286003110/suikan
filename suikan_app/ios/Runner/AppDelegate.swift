import UIKit
import Flutter
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    UNUserNotificationCenter.current().delegate = self
    if let controller = window?.rootViewController as? FlutterViewController {
      let channel = FlutterMethodChannel(
        name: "simple_live/live_notifications",
        binaryMessenger: controller.binaryMessenger
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

      // 系统画中画（iOS / iPadOS）。
      // 播放内核是 mpv，进不了只认 AVPlayer 的系统 PiP，因此由
      // SuikanPiPManager 把视频帧转成 CMSampleBuffer 喂给
      // AVSampleBufferDisplayLayer，再交给 AVPictureInPictureController。
      let pipChannel = FlutterMethodChannel(
        name: "suikan/pip",
        binaryMessenger: controller.binaryMessenger
      )
      pipChannel.setMethodCallHandler { call, result in
        switch call.method {
        case "isSupported":
          result(SuikanPiPManager.shared.isSupported)
        case "start":
          SuikanPiPManager.shared.start()
          result(nil)
        case "stop":
          SuikanPiPManager.shared.stop()
          result(nil)
        case "isActive":
          result(SuikanPiPManager.shared.isPipActive)
        default:
          result(FlutterMethodNotImplemented)
        }
      }
      // PiP 窗口里的播放/暂停 → 通知 Dart 控制 mpv
      SuikanPiPManager.shared.onPlayPause = { playing in
        pipChannel.invokeMethod("onPlayPause", arguments: playing)
      }
      SuikanPiPManager.shared.onPipStateChanged = { active in
        pipChannel.invokeMethod("onPipState", arguments: active)
      }
      // PiP 启动失败/设备不支持等原因 → 弹提示（不再静默）
      SuikanPiPManager.shared.onError = { message in
        pipChannel.invokeMethod("onError", arguments: message)
      }
    }
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }

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
