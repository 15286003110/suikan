import AVFoundation
import AVKit
import UIKit

/// 随看 iOS / iPadOS 系统画中画（Picture in Picture）管理器。
///
/// 背景：随看的播放内核是 mpv（media_kit），画面渲染在自己的图层上，
/// 而苹果的系统画中画只认 AVPlayerLayer 或 AVSampleBufferDisplayLayer。
/// 因此这里走 AVSampleBufferDisplayLayer 路线：
///   mpv 解码帧（CVPixelBuffer，由 media_kit_video 的 TextureHW 提供）
///     → CMSampleBuffer
///     → AVSampleBufferDisplayLayer
///     → AVPictureInPictureController.ContentSource
///     → 系统小窗
///
/// 帧的投递用 NotificationCenter 与 media_kit_video 解耦（插件 pod 与 App
/// 互相不 import），只有 PiP 需要时才让插件开始送帧，避免平时白费开销。
class PipVideoView: UIView {
  override class var layerClass: AnyClass {
    AVSampleBufferDisplayLayer.self
  }

  var displayLayer: AVSampleBufferDisplayLayer {
    // swiftlint:disable:next force_cast
    layer as! AVSampleBufferDisplayLayer
  }
}

class SuikanPiPManager: NSObject {

  static let shared = SuikanPiPManager()

  /// PiP 窗口里的播放/暂停被点击 → 回传给 Dart 控制 mpv
  var onPlayPause: ((Bool) -> Void)?
  /// PiP 启动/停止状态变化 → 回传给 Dart 更新 UI
  var onPipStateChanged: ((Bool) -> Void)?

  private var pipController: AVPictureInPictureController?
  private var pipView: PipVideoView?
  private var timebase: CMTimebase?
  private var isPlaying = true
  private var lastEnqueueTime: CFTimeInterval = 0
  private var handlingPlayCommand = false

  private(set) var isPipActive = false

  private override init() {
    super.init()
  }

  var isSupported: Bool {
    AVPictureInPictureController.isPictureInPictureSupported()
  }

  // MARK: - 音频会话

  /// 必须配置成 playback / moviePlayback，否则 App 退后台时 PiP 窗口不会打开。
  private func configureAudioSession() {
    do {
      try AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
      try AVAudioSession.sharedInstance().setActive(true)
    } catch {
      NSLog("[SuikanPiP] audio session 配置失败: \(error)")
    }
  }

  // MARK: - 准备 / 启动 / 停止

  /// 创建 PiP 视图与控制器（幂等）。必须在真正播放起来之后调用。
  func prepare() {
    guard pipController == nil else { return }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      NSLog("[SuikanPiP] 设备不支持画中画")
      return
    }
    guard let rootView = Self.keyRootView() else {
      NSLog("[SuikanPiP] 取不到根视图")
      return
    }

    configureAudioSession()

    let view = PipVideoView()
    // 近乎透明：只是给系统提供内容源，不遮挡 App 自己的画面
    view.alpha = 0.01
    view.frame = CGRect(x: 0, y: 0, width: 640, height: 360)
    view.isUserInteractionEnabled = false

    var tb: CMTimebase?
    CMTimebaseCreateWithSourceClock(
      allocator: kCFAllocatorDefault,
      sourceClock: CMClockGetHostTimeClock(),
      timebaseOut: &tb
    )
    if let tb = tb {
      CMTimebaseSetTime(tb, time: CMTime.zero)
      CMTimebaseSetRate(tb, rate: 1.0)
      view.displayLayer.controlTimebase = tb
      timebase = tb
    }

    rootView.insertSubview(view, at: 0)
    pipView = view

    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: view.displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    // 直播：只要播放/暂停，不要快进快退
    controller.requiresLinearPlayback = true
    // 切后台时自动进入 PiP
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    pipController = controller

    // 让 media_kit_video 开始投递视频帧
    NotificationCenter.default.post(name: Self.frameBridgeStart, object: nil)
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handleFrame(_:)),
      name: Self.frameReady,
      object: nil
    )
  }

  func start() {
    prepare()
    guard let controller = pipController else { return }
    if controller.isPictureInPictureActive {
      return
    }
    controller.startPictureInPicture()
  }

  func stop() {
    pipController?.stopPictureInPicture()
  }

  /// 释放 PiP 资源并让插件停止送帧。
  func dispose() {
    NotificationCenter.default.post(name: Self.frameBridgeStop, object: nil)
    NotificationCenter.default.removeObserver(self, name: Self.frameReady, object: nil)
    pipView?.removeFromSuperview()
    pipView = nil
    pipController = nil
    timebase = nil
    isPipActive = false
  }

  // MARK: - 帧桥

  @objc private func handleFrame(_ note: Notification) {
    guard isPipActive || pipController != nil else { return }
    guard let pixelBuffer = note.userInfo?[Self.frameKey] as? CVPixelBuffer else { return }
    guard let layer = pipView?.displayLayer else { return }
    // 背压：渲染层还没消化就丢帧，避免无限堆积
    guard layer.isReadyForMoreMediaData else { return }
    // 限流到 ~30fps：小窗尺寸本就不大，省 CPU / 功耗
    let now = CACurrentMediaTime()
    if now - lastEnqueueTime < 1.0 / 32.0 {
      return
    }
    lastEnqueueTime = now
    guard let sampleBuffer = makeSampleBuffer(pixelBuffer: pixelBuffer) else { return }
    layer.enqueue(sampleBuffer)
  }

  private func makeSampleBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    var formatDesc: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateForImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescriptionOut: &formatDesc
    )
    guard status == noErr, let format = formatDesc else { return nil }

    var timing = CMSampleTimingInfo()
    timing.duration = CMTimeMake(value: 1, timescale: 600)
    timing.decodeTimeStamp = CMTime.invalid
    if let tb = timebase {
      timing.presentationTimeStamp = CMTimebaseGetTime(tb)
    } else {
      timing.presentationTimeStamp = CMTime.zero
    }

    var sampleBuffer: CMSampleBuffer?
    let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: format,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard createStatus == noErr else { return nil }
    return sampleBuffer
  }

  // MARK: - 工具

  private static func keyRootView() -> UIView? {
    if let scene = UIApplication.shared.connectedScenes
      .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
      let window = scene.windows.first(where: { $0.isKeyWindow }) {
      return window.rootViewController?.view
    }
    return UIApplication.shared.windows.first(where: { $0.isKeyWindow })?.rootViewController?.view
  }

  // MARK: - 通知名（与 vendor/media_kit_video 约定）

  static let frameReady = Notification.Name("com.suikan.pip.frameReady")
  static let frameBridgeStart = Notification.Name("com.suikan.pip.frameBridgeStart")
  static let frameBridgeStop = Notification.Name("com.suikan.pip.frameBridgeStop")
  static let frameKey = "pixelBuffer"
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

extension SuikanPiPManager: AVPictureInPictureSampleBufferPlaybackDelegate {

  /// 直播流：可播放时间范围无限（系统据此显示为直播，不画进度条）
  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: CMTime.zero, duration: CMTime.positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    !isPlaying
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    isPlaying = playing
    handlingPlayCommand = true
    onPlayPause?(playing)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // 小窗尺寸变化：当前不做变码率，忽略即可
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime
  ) async {
    // requiresLinearPlayback = true，直播不支持跳转
  }
}

// MARK: - AVPictureInPictureControllerDelegate

extension SuikanPiPManager: AVPictureInPictureControllerDelegate {

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isPipActive = true
    onPipStateChanged?(true)
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isPipActive = false
    onPipStateChanged?(false)
    dispose()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[SuikanPiP] 启动画中画失败: \(error)")
    dispose()
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
