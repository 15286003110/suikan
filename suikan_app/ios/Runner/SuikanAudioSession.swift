import AVFoundation
import UIKit

/// 随看 iOS 音频会话管理（2026-09-05）。
///
/// 背景：iOS 上 App 想在退后台后继续出声，光在 Info.plist 声明
/// `UIBackgroundModes=audio` **不够**——必须真正把 AVAudioSession 配成
/// `.playback`（moviePlayback）并激活，系统才会把它当"可在后台播音频"的 App，
/// 否则一退后台就被挂起 → 声音停（表现：手动纯音频/后台播放返回桌面即停止）。
///
/// 之前只在画中画路径里临时配过会话，PiP 移除后这段也一起没了，
/// iOS 的后台播放其实一直在裸奔，这里补成常驻能力。
///
/// 另外处理两类常见中断：
/// - 来电 / 闹钟 / Siri：会话被系统中断，中断结束后重新激活并通知 Dart 恢复
/// - 音频路由变化（拔耳机 / 切蓝牙）：保证会话仍处于激活状态
/// - 媒体服务重置：重新配置一遍
final class SuikanAudioSession: NSObject {

  static let shared = SuikanAudioSession()

  /// 中断结束后需要 Dart 侧恢复播放（原生激活会话，mpv 由 Dart 控制 play）
  var onInterruptionEndedShouldResume: ((Bool) -> Void)?

  private var isConfigured = false

  private override init() {
    super.init()
    registerNotifications()
  }

  // MARK: - 对外

  /// App 启动时调用一次：只声明类别，不抢音频（不打断用户正在听的其它 App）。
  func configure() {
    guard !isConfigured else { return }
    isConfigured = true
    applyCategory()
  }

  /// 真正开始播放时调用：激活会话（此时打断其它音频是预期行为）。
  func activate() {
    configure()
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("[SuikanAudio] setActive 失败: \(error)")
    }
  }

  /// App 退后台前再确认一次：确保会话是 playback 且激活，否则后台会被挂起。
  func ensureActiveForBackground() {
    applyCategory()
    do {
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("[SuikanAudio] 退后台前激活失败: \(error)")
    }
  }

  /// 播放彻底停止/离开直播间：释放会话，把音频还给其它 App。
  func deactivate() {
    do {
      try AVAudioSession.sharedInstance().setActive(
        false, options: .notifyOthersOnDeactivation)
    } catch {
      NSLog("[SuikanAudio] 释放会话失败: \(error)")
    }
  }

  private func applyCategory() {
    do {
      try AVAudioSession.sharedInstance().setCategory(
        .playback, mode: .moviePlayback, options: [])
    } catch {
      NSLog("[SuikanAudio] setCategory 失败: \(error)")
    }
  }

  // MARK: - 通知

  private func registerNotifications() {
    let center = NotificationCenter.default
    center.addObserver(
      self,
      selector: #selector(handleInterruption(_:)),
      name: AVAudioSession.interruptionNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleRouteChange(_:)),
      name: AVAudioSession.routeChangeNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleMediaServicesReset),
      name: AVAudioSession.mediaServicesWereResetNotification,
      object: nil
    )
    center.addObserver(
      self,
      selector: #selector(handleEnterBackground),
      name: UIApplication.didEnterBackgroundNotification,
      object: nil
    )
  }

  @objc private func handleInterruption(_ note: Notification) {
    guard
      let raw = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
      let type = AVAudioSession.InterruptionType(rawValue: raw)
    else { return }

    switch type {
    case .began:
      // 系统已帮我们停掉音频，等结束通知再恢复
      NSLog("[SuikanAudio] 音频被中断（来电/闹钟等）")
    case .ended:
      guard
        let optRaw = note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
      else { return }
      let options = AVAudioSession.InterruptionOptions(rawValue: optRaw)
      let shouldResume = options.contains(.shouldResume)
      applyCategory()
      do {
        try AVAudioSession.sharedInstance().setActive(true)
      } catch {
        NSLog("[SuikanAudio] 中断后恢复会话失败: \(error)")
      }
      NSLog("[SuikanAudio] 中断结束，恢复播放=\(shouldResume)")
      onInterruptionEndedShouldResume?(shouldResume)
    @unknown default:
      break
    }
  }

  @objc private func handleRouteChange(_ note: Notification) {
    // 拔耳机 / 切蓝牙后确保会话仍激活（是否暂停由产品策略决定，这里只保会话）
    if AVAudioSession.sharedInstance().isOtherAudioPlaying {
      return
    }
    if !AVAudioSession.sharedInstance().isActive {
      applyCategory()
      try? AVAudioSession.sharedInstance().setActive(true)
    }
  }

  @objc private func handleMediaServicesReset() {
    isConfigured = false
    configure()
  }

  @objc private func handleEnterBackground() {
    // 退后台前兜底：类别 + 激活，保证后台继续出声
    ensureActiveForBackground()
  }
}
