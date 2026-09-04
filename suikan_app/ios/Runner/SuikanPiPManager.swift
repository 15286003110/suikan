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
  private var formatDescription: CMVideoFormatDescription?
  private var isPlaying = true
  private var lastEnqueueTime: CFTimeInterval = 0
  /// 是否允许向渲染层投递帧。prepare 起**常驻开启**（standby 保活：低频喂帧，
  /// 让 layer 始终有最近内容，系统「切后台自动画中画」才有画面可弹）；
  /// 只有 dispose（离开直播间）才关闭。
  private var receiveFrames = false
  /// 等待预热帧后真正触发 startPictureInPicture（仅手动点击入口使用）
  private var pendingStart = false
  /// 启动 watchdog 是否已触发
  private var startWatchdogTriggered = false

  private(set) var isPipActive = false

  /// 帧处理专用串行队列：CMSampleBuffer 的转换/入队开销不小，绝不能放在
  /// 主线程（实测：主线程转帧会让聊天栏/UI 跳帧）。串行保证帧序不乱。
  private let frameQueue = DispatchQueue(label: "com.suikan.pip.frameQueue", qos: .userInitiated)

  private override init() {
    super.init()
    // iOS 画中画期间 App 退后台的保活：系统是否挂起进程取决于音频会话是否
    // 处于 playback+active。PiP 启动后若会话被其它源改掉/失活，后台会断帧
    // → 小窗停播。每次退后台前重新确认一次会话。
    NotificationCenter.default.addObserver(
      forName: UIApplication.didEnterBackgroundNotification,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      // 仅 PiP 已激活/正在启动时才需要保活；未开 PiP 时不动会话
      // （避免与纯音频/普通后台逻辑抢会话）。
      guard let self = self else { return }
      guard self.pipController != nil else { return }
      self.configureAudioSession()
    }
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
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
    view.displayLayer.videoGravity = .resizeAspect

    // 业界标准做法（腾讯云 TRTC 画中画 / Secure ShellFish 等成功案例）：
    // 用 DisplayImmediately 标记逐帧直显，**不设 controlTimebase**——
    // 苹果文档明确提示二者同时使用不推荐，且无 timebase 时各帧按
    // 帧携带的 pts 或 DisplayImmediately 立即上屏。

    // 把内容层挂进根视图（腾讯云做法是把 layer 加进 VC.view），
    // 供系统识别转场/恢复的参考视图；挂不上也不阻塞功能。
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
    // 播放中把 App 切到后台/其它 App → **自动**弹出系统小窗继续播
    // （B站/优酷同款体验：不用先手动点小窗，切走即画中画）。
    // iOS 14+/sampleBuffer ContentSource 均支持；首次使用时系统会弹
    // 「允许后台播放画中画吗」类引导，之后记住用户偏好。
    if #available(iOS 14.2, *) {
      controller.canStartPictureInPictureAutomaticallyFromInline = true
    }
    pipController = controller

    // standby 保活：注册帧桥并低频喂帧（2fps）。系统自动画中画要求
    // 「启动那一刻渲染层有内容」，不常驻喂帧 layer 就是空的 → 自动小窗
    // 永远不会弹（2026-09-04 实测：canStartPictureInPictureAutomatically
    // =true 但从不喂帧，切后台毫无反应）。
    receiveFrames = true
    TextureFrameBridge.shared.onFrame = { [weak self] (pixelBuffer: CVPixelBuffer) in
      self?.handleFrame(pixelBuffer)
    }
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
    // standby 保活已在持续喂帧（layer 有内容），直接走启动。
    startWatchdogTriggered = false
    pendingStart = true
    maybeStartPip()

    // watchdog：4 秒内没真正激活 → 判定失败，回到 standby 并回报原因
    // （不 dispose：用户还在直播间，之后「切后台自动小窗」仍要 layer 有内容）。
    DispatchQueue.main.asyncAfter(deadline: .now() + 4.0) { [weak self] in
      guard let self = self else { return }
      guard !self.startWatchdogTriggered else { return }
      self.startWatchdogTriggered = true
      if !self.isPipActive {
        self.pendingStart = false
        self.onError?("小窗未能启动，请稍后重试")
      }
    }
  }

  /// 预热帧足够后（且 layer 已有内容）触发系统 PiP。
  private func maybeStartPip() {
    guard pendingStart else { return }
    pendingStart = false
    guard let controller = pipController else {
      return
    }
    // 让 layer 消化首帧再启动，避免 PiP 动画取不到画面
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) { [weak self] in
      guard let self = self else { return }
      guard let controller = self.pipController else { return }
      if controller.isPictureInPictureActive {
        return
      }
      // 触发前再确保一次音频会话（mpv 播放过程中可能改过 category，
      // PiP 要求 playback 且 active，否则 isPictureInPicturePossible 为 false）
      self.configureAudioSession()
      if !controller.isPictureInPicturePossible {
        self.startWatchdogTriggered = true
        self.onError?("系统暂不允许小窗（请确认正在播放且有声音）")
        return
      }
      controller.startPictureInPicture()
    }
  }

  func stop() {
    pipController?.stopPictureInPicture()
  }

  /// 彻底释放 PiP 资源并停止送帧（离开直播间时由 Dart 调用；幂等）。
  /// 注意：用户退出小窗（didStop）**不**走这里 —— 回到 standby 低频喂帧，
  /// 以便再次「切后台自动小窗」时 layer 仍有内容。
  func dispose() {
    TextureFrameBridge.shared.onFrame = nil
    receiveFrames = false
    pendingStart = false
    formatDescription = nil
    pipView?.removeFromSuperview()
    pipView = nil
    pipController = nil
    isPipActive = false
  }

  // MARK: - 帧处理

  /// 渲染线程每帧都会进来（60fps），这里只做轻量判断。
  /// standby（未启动/未激活）限 2fps 保活喂帧；启动中/激活后限 ~32fps。
  private func handleFrame(_ pixelBuffer: CVPixelBuffer) {
    guard receiveFrames else { return }
    let minInterval: CFTimeInterval =
      (pendingStart || isPipActive) ? (1.0 / 32.0) : 0.5
    let now = CACurrentMediaTime()
    if now - lastEnqueueTime < minInterval {
      return
    }
    // 粗背压：层还没消化就不投（丢帧，避免无限堆积）
    guard let layer = pipView?.displayLayer, layer.isReadyForMoreMediaData else {
      return
    }
    // 重活（CMSampleBuffer 转换 + enqueue）投到后台串行队列保序，
    // 渲染线程只做上面的时间/背压判断。
    frameQueue.async { [weak self] in
      guard let self = self else { return }
      self.enqueueFrame(pixelBuffer)
    }
  }

  private func enqueueFrame(_ pixelBuffer: CVPixelBuffer) {
    guard receiveFrames else { return }
    guard let layer = pipView?.displayLayer else { return }
    // 双保险（handleFrame 已限流/背压，这里再查一次防止队列堆积）
    guard layer.isReadyForMoreMediaData else { return }
    let now = CACurrentMediaTime()
    if now - lastEnqueueTime < 0.1 {
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
    timing.duration = CMTime.invalid
    timing.decodeTimeStamp = CMTime.invalid
    // 直播实时画面用 DisplayImmediately 逐帧直显，pts 仅供系统参考；
    // 给一个单调推进的 host clock 值即可。
    timing.presentationTimeStamp = CMClockGetTime(CMClockGetHostTimeClock())

    var sampleBuffer: CMSampleBuffer?
    let createStatus = CMSampleBufferCreateReadyWithImageBuffer(
      allocator: kCFAllocatorDefault,
      imageBuffer: pixelBuffer,
      formatDescription: fd,
      sampleTiming: &timing,
      sampleBufferOut: &sampleBuffer
    )
    guard createStatus == noErr, let sampleBuffer = sampleBuffer else { return nil }

    // 逐帧立即上屏——业界成功案例（腾讯云 TRTC / Secure ShellFish）的共同点：
    // 不标 DisplayImmediately，PiP 画面会不刷新/黑屏/一直 loading。
    if let attrs = CMSampleBufferGetSampleAttachmentsArray(
      sampleBuffer, createIfNecessary: true
    ), CFArrayGetCount(attrs) > 0 {
      let dict = unsafeBitCast(
        CFArrayGetValueAtIndex(attrs, 0),
        to: CFMutableDictionary.self
      )
      CFDictionarySetValue(
        dict,
        Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
        Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
      )
    }
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

  /// 直播流：可播放时间范围负无穷~正无穷（实时内容标准返回；范围不对
  /// 会让 PiP 一直转 loading）
  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    CMTimeRange(start: CMTime.negativeInfinity, duration: CMTime.positiveInfinity)
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
    // 用户退出小窗 → 回到 standby（不 dispose）：保留 controller 与
    // 2fps 保活喂帧，让之后「切后台自动小窗」/再次手动点小窗立即可用。
    isPipActive = false
    pendingStart = false
    onPipStateChanged?(false)
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[SuikanPiP] 启动画中画失败: \(error)")
    startWatchdogTriggered = true
    let detail = (error as NSError).localizedDescription
    pendingStart = false
    onError?("小窗启动失败：\(detail)")
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
  ) {
    completionHandler(true)
  }
}
