import MediaPlayer
import UIKit

/// 随看 iOS 系统媒体中心（锁屏 / 控制中心 / 耳机线控）——2026-09-05。
///
/// media_kit 不内置系统媒体控制，需要 App 自己接：
/// - `MPNowPlayingInfoCenter` 负责**显示**（标题 / 主播 / 封面 / 直播标记 / 影视进度）
/// - `MPRemoteCommandCenter` 负责**控制**（播放 / 暂停 / 切台 / 进度拖动 / 线控）
///
/// 前提：音频会话必须是 playback 类别并激活（见 SuikanAudioSession），
/// 否则系统不会把 App 显示在控制中心。
final class SuikanMediaControl: NSObject {

  static let shared = SuikanMediaControl()

  /// 系统媒体中心发来的命令，转发给 Dart 执行。
  /// command 取值：play / pause / toggle / next / prev / seek（seek 带 "position" 秒）。
  var onCommand: (([String: Any]) -> Void)?

  private var configured = false

  /// 当前正在显示的标题（封面异步下载完成后据此判断是否仍应显示，防切台串图）。
  private var currentTitle = ""

  /// 封面内存缓存（同一房间反复进出/切台不重复下载）。
  private var coverCache: [String: UIImage] = [:]

  private override init() {
    super.init()
  }

  func configure() {
    guard !configured else { return }
    configured = true

    let center = MPRemoteCommandCenter.shared()
    // 播放/暂停/切台/进度拖动都接上；切台与进度按「当前是直播还是影视、
    // 有无多线路」在 update 时动态开关（isEnabled）。
    center.playCommand.isEnabled = true
    center.pauseCommand.isEnabled = true
    center.togglePlayPauseCommand.isEnabled = true
    center.nextTrackCommand.isEnabled = true
    center.previousTrackCommand.isEnabled = true
    center.changePlaybackPositionCommand.isEnabled = true
    // 直播没有时长，跳播/快进快退始终关闭
    center.skipForwardCommand.isEnabled = false
    center.skipBackwardCommand.isEnabled = false
    center.seekForwardCommand.isEnabled = false
    center.seekBackwardCommand.isEnabled = false

    center.playCommand.addTarget { [weak self] _ in
      self?.onCommand?(["command": "play"])
      return .success
    }
    center.pauseCommand.addTarget { [weak self] _ in
      self?.onCommand?(["command": "pause"])
      return .success
    }
    center.togglePlayPauseCommand.addTarget { [weak self] _ in
      self?.onCommand?(["command": "toggle"])
      return .success
    }
    center.nextTrackCommand.addTarget { [weak self] _ in
      self?.onCommand?(["command": "next"])
      return .success
    }
    center.previousTrackCommand.addTarget { [weak self] _ in
      self?.onCommand?(["command": "prev"])
      return .success
    }
    center.changePlaybackPositionCommand.addTarget { [weak self] event in
      guard let e = event as? MPChangePlaybackPositionCommandEvent else {
        return .commandFailed
      }
      self?.onCommand?(["command": "seek", "position": e.positionTime])
      return .success
    }
  }

  /// 更新锁屏/控制中心显示的信息。
  /// - duration / position：秒，仅影视传入（nil = 直播）
  /// - canNext / canPrev：是否显示并启用切台命令（直播多线路 / 影视有前后集）
  func update(
    title: String,
    artist: String,
    isLive: Bool,
    playing: Bool,
    coverUrl: String?,
    duration: Double?,
    position: Double?,
    canNext: Bool,
    canPrev: Bool
  ) {
    currentTitle = title

    // 动态开关切台/进度命令
    let center = MPRemoteCommandCenter.shared()
    center.nextTrackCommand.isEnabled = canNext
    center.previousTrackCommand.isEnabled = canPrev
    center.changePlaybackPositionCommand.isEnabled = !isLive && (duration ?? 0) > 0

    var info: [String: Any] = [
      MPMediaItemPropertyTitle: title,
      MPMediaItemPropertyArtist: artist,
      MPNowPlayingInfoPropertyPlaybackRate: playing ? 1.0 : 0.0,
    ]
    if isLive {
      // 直播没有总时长：标记直播 + 0 进度，系统显示 LIVE 而不是进度条
      info[MPNowPlayingInfoPropertyIsLiveStream] = true
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = 0
    } else {
      info[MPNowPlayingInfoPropertyIsLiveStream] = false
      if let d = duration {
        info[MPMediaItemPropertyPlaybackDuration] = d
      }
      if let p = position {
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p
      }
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info

    // 封面：命中缓存直接贴，否则异步下载（下载完成回主线程，确认仍是当前条目再贴）
    if let url = coverUrl, !url.isEmpty {
      if let cached = coverCache[url] {
        applyArtwork(cached)
      } else {
        loadArtwork(url: url, title: title)
      }
    }
  }

  /// 只更新播放/暂停状态（控制中心按钮与进度动画依赖它）。
  func setPlaying(_ playing: Bool, position: Double? = nil) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyPlaybackRate] = playing ? 1.0 : 0.0
    if let p = position {
      info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = p
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// 更新播放进度（秒），仅影视（直播忽略）。
  func setPosition(_ position: Double) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = position
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }

  /// 离开直播间/关闭播放器：清掉锁屏信息。
  func clear() {
    currentTitle = ""
    MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
  }

  // MARK: - 封面

  private func loadArtwork(url: String, title: String) {
    guard let u = URL(string: url) else { return }
    let task = URLSession.shared.dataTask(with: u) { [weak self] data, _, _ in
      guard let data = data, let img = UIImage(data: data) else { return }
      self?.coverCache[url] = img
      DispatchQueue.main.async {
        guard let self = self, self.currentTitle == title else { return }
        self.applyArtwork(img)
      }
    }
    task.resume()
  }

  private func applyArtwork(_ img: UIImage) {
    var info = MPNowPlayingInfoCenter.default().nowPlayingInfo ?? [:]
    info[MPMediaItemPropertyArtwork] = MPMediaItemArtwork(boundsSize: img.size) { _ in
      img
    }
    MPNowPlayingInfoCenter.default().nowPlayingInfo = info
  }
}
