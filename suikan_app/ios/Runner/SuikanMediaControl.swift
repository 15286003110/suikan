import MediaPlayer
import UIKit

/// 随看 iOS 系统媒体中心（锁屏 / 控制中心 / 耳机线控）——2026-09-05。
///
/// media_kit 不内置系统媒体控制，需要 App 自己接：
/// - `MPNowPlayingInfoCenter` 负责**显示**（标题 / 主播 / 直播标记）
/// - `MPRemoteCommandCenter` 负责**控制**（播放 / 暂停 / 线控）
///
/// 前提：音频会话必须是 playback 类别并激活（见 SuikanAudioSession），
/// 否则系统不会把 App 显示在控制中心。
final class SuikanMediaControl: NSObject {

  static let shared = SuikanMediaControl()

  /// 系统媒体中心发来的命令，转发给 Dart 执行（play / pause / toggle）
  var onCommand: ((String) -> Void)?

  private var configured = false

  private override init() {
    super.init()
  }

  func configure() {
    guard !configured else { return }
    configured = true

    let center = MPRemoteCommandCenter.shared()
    // 只开放播放 / 暂停：直播不做进度拖动与切台，避免"点了没反应"。
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    center.changePlaybackPositionCommand.isEnabled = false
    center.nextTrackCommand.isEnabled = false
    center.previousTrackCommand.isEnabled = false
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
    center.seekForwardCommand.isEnabled = false
    center.seekBackwardCommand.isEnabled = false

    center.playCommand.addTarget { [weak self] _ in
      self?.onCommand?("play")
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.onCommand?("pause")
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.onCommand?("toggle")
      return .success
    }
  }

  /// 更新锁屏/控制中心显示的信息。
  func update(
    title: String,
    artist: String,
    isLive: Bool,
    playing: Bool
  ) {
    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: artist,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
      MPNowPlayingInfoPropertyIsLiveStream: isLive,
    ]
    if isLive {
      // 直播没有总时长：给一个 0 进度并标记直播，系统显示 LIVE 而不是进度条
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// 只更新播放/暂停状态（控制中心按钮与进度动画依赖它）。
  func setPlaying(_ playing: Bool) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// 离开直播间/关闭播放器：清掉锁屏信息。
  func clear() {
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }
}
