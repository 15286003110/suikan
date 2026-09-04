import Foundation

/// 视频帧桥（随看自定义扩展，非 media_kit 上游代码）。
///
/// iOS 的系统画中画只认 AVPlayerLayer / AVSampleBufferDisplayLayer，而 mpv 的画面
/// 渲染在自己的图层上，进不了系统小窗。解决办法是把每一帧的 CVPixelBuffer 交给
/// App 层的 PiP 管理器（SuikanPiPManager），由它转成 CMSampleBuffer 喂给
/// AVSampleBufferDisplayLayer。
///
/// 这里用 NotificationCenter 而不是直接依赖，是为了让插件 pod 与 App 工程解耦
/// （互相不 import）。App 侧发 start/stop 通知开关送帧，插件每帧（渲染完成后）
/// 把 CVPixelBuffer 通过 frameReady 通知带出去。
///
/// ⚠️ 只在画中画需要时才打开，避免平时每帧都发通知白白开销。
public class TextureFrameBridge: NSObject {

  @objc public static let shared = TextureFrameBridge()

  private static let frameReadyName = Notification.Name("com.suikan.pip.frameReady")
  private static let startName = Notification.Name("com.suikan.pip.frameBridgeStart")
  private static let stopName = Notification.Name("com.suikan.pip.frameBridgeStop")
  private static let pixelBufferKey = "pixelBuffer"

  private var _enabled = false
  private let lock = NSLock()

  /// 是否需要向 App 侧投递视频帧
  public var enabled: Bool {
    lock.lock()
    defer { lock.unlock() }
    return _enabled
  }

  private override init() {
    super.init()
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(enableBridging),
      name: TextureFrameBridge.startName,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(disableBridging),
      name: TextureFrameBridge.stopName,
      object: nil
    )
  }

  @objc private func enableBridging() {
    lock.lock()
    _enabled = true
    lock.unlock()
  }

  @objc private func disableBridging() {
    lock.lock()
    _enabled = false
    lock.unlock()
  }

  /// 渲染完成一帧后调用：把 CVPixelBuffer 交给 App 侧的 PiP 渲染层。
  /// 必须在主线程调用（渲染本身就跑在主线程）。
  public func deliver(pixelBuffer: CVPixelBuffer) {
    guard enabled else { return }
    NotificationCenter.default.post(
      name: TextureFrameBridge.frameReadyName,
      object: nil,
      userInfo: [TextureFrameBridge.pixelBufferKey: pixelBuffer]
    )
  }
}
