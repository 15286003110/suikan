import AVFoundation
import AVKit
import media_kit_video
import QuartzCore
import UIKit

/// 随看 iOS / iPadOS 系统画中画（Picture in Picture）管理器。
///
/// 背景：随看的播放内核是 mpv（media_kit），画面渲染在自己的图层上，
/// 而苹果的系统画中画只认 AVPlayerLayer 或 AVSampleBufferDisplayLayer。
/// 因此这里走 AVSampleBufferDisplayLayer 路线：
///   mpv 解码帧（CVPixelBuffer，由 vendor media_kit_video 的 TextureHW 渲染出口
///   → TextureFrameBridge 提供）
///     → CMSampleBuffer
///     → AVSampleBufferDisplayLayer
///     → AVPictureInPictureController.ContentSource
///     → 系统小窗
///
/// 性能红线：CMSampleBuffer 的创建必须**只在 PiP 激活期间**进行，否则每帧在主线程
/// 做格式转换会把 UI 线程拖垮（iPad 实机已踩：点小窗没弹出来但帧桥还挂着 →
/// 聊天栏/UI 动画整体跳帧）。
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
  /// PiP 相关错误/原因 → 回传给 Dart 弹提示（不再静默失败）
  var onError: ((String) -> Void)?

  private var pipController: AVPictureInPictureController?
  private var pipView: PipVideoView?
  private var timebase: CMTimebase?
  private var formatDescription: CMVideoFormatDescription?
  private var isPlaying = true
  private var lastEnqueueTime: CFTimeInterval = 0
  /// 是否允许向渲染层投递帧（仅 PiP 启动中/激活中为 true）
  private var receiveFrames = false
  /// 启动 watchdog 是否已触发
  private var startWatchdogTriggered = false

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
      onError?("当前设备不支持画中画")
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

    // 能挂到根视图更好（PiP 转场/恢复有参考系）；挂不上也不影响 PiP 本体，
    // 系统画中画只认 layer 内容。别再因为 rootView 为 nil 而静默失败。
    if let rootView = Self.keyRootView() {
      rootView.insertSubview(view, at: 0)
    } else {
      NSLog("[SuikanPiP] 取不到根视图，PiP 内容层不入视图树（不影响功能）")
    }
    pipView = view

    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: view.displayLayer,
      playbackDelegate: self
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    // 直播：只要播放/暂停，不要快进快退
    controller.requiresLinearPlayback = true
    pipController = controller
  }

  func start() {
    prepare()
    guard let controller = pipController else {
      onError?("小窗未就绪")
      return
    }
    if controller.isPictureInPictureActive {
      return
    }
    // 注册帧桥并开始预热帧（PiP 启动动画需要 layer 里有内容）
    startWatchdogTriggered = false
    receiveFrames = true
    TextureFrameBridge.shared.onFrame = { [weak self] (pixelBuffer: CVPixelBuffer) in
      self?.handleFrame(pixelBuffer)
    }
    controller.startPictureInPicture()

    // watchdog：2.5 秒内没真正激活 → 判定失败，收掉帧桥并回报原因。
    // 否则帧桥会一直挂着，每帧在主线程转 CMSampleBuffer 拖垮 UI。
    DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { [weak self] in
      guard let self = self else { return }
      guard !self.startWatchdogTriggered else { return }
      self.startWatchdogTriggered = true
      if !self.isPipActive {
        self.dispose()
        self.onError?("小窗未能启动，请稍后重试")
      }
    }
  }

  func stop() {
    pipController?.stopPictureInPicture()
  }

  /// 释放 PiP 资源并让插件停止送帧。
  func dispose() {
    TextureFrameBridge.shared.onFrame = nil
    receiveFrames = false
    formatDescription = nil
    pipView?.removeFromSuperview()
    pipView = nil
    pipController = nil
    timebase = nil
    isPipActive = false
  }

  // MARK: - 帧处理

  private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
    // 性能红线：只有 PiP 启动中/激活中才收帧；否则直接在渲染线程丢弃。
    guard receiveFrames else { return }
    guard let layer = pipView?.displayLayer else { return }
    // 背压：渲染层还没消化就丢帧，避免无限堆积
    guard layer.isReadyForMoreMediaData else { return }
    // 限流到 ~32fps：小窗尺寸本就不大，省 CPU / 功耗
    let now = CACurrentMediaTime()
    if now - lastEnqueueTime < 1.0 / 32.0 {
      return
    }
    lastEnqueueTime = now
    guard let sampleBuffer = makeSampleBuffer(pixelBuffer: pixelBuffer) else { return }
    layer.enqueue(sampleBuffer)
  }

  private func makeSampleBuffer(pixelBuffer: CVPixelBuffer) -> CMSampleBuffer? {
    // format description 与 pixelBuffer 尺寸/格式绑定，尺寸没变就复用，
    // 避免每帧都创建（主线程开销大户）。
    if let fd = formatDescription,
       CMVideoFormatDescriptionGetDimensions(fd).width == CVPixelBufferGetWidth(pixelBuffer),
       CMVideoFormatDescriptionGetDimensions(fd).height == CVPixelBufferGetHeight(pixelBuffer) {
      // 复用已缓存的 format
    } else {
      var newFd: CMVideoFormatDescription?
      let st = CMVideoFormatDescriptionCreateForImageBuffer(
        allocator: kCFAllocatorDefault,
        imageBuffer: pixelBuffer,
        formatDescriptionOut: &newFd
      )
      guard st == noErr, let fd = newFd else { return nil }
      formatDescription = fd
    }
    guard let fd = formatDescription else { return nil }

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
      formatDescription: fd,
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

  func pictureInPictureControllerWillStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    // 保持 receiveFrames = true（start() 已开启预热）
  }

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    isPipActive = true
    startWatchdogTriggered = true
    receiveFrames = true
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
    startWatchdogTriggered = true
    let detail = (error as NSError).localizedDescription
    dispose()
    onError?("小窗启动失败：\(detail)")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
