import CoreVideo
import Foundation

/// 视频帧桥（随看自定义扩展，非 media_kit 上游代码）。
///
/// iOS 的系统画中画只认 AVPlayerLayer / AVSampleBufferDisplayLayer，而 mpv 的画面
/// 渲染在自己的图层上，进不了系统小窗。解决办法是把每一帧的 CVPixelBuffer 交给
/// App 层的 PiP 管理器（SuikanPiPManager），由它转成 CMSampleBuffer 喂给
/// AVSampleBufferDisplayLayer。
///
/// 用**闭包直调**而不是通知：CVPixelBuffer 是 CoreFoundation 类型，塞进通知的
/// userInfo（NSDictionary 桥接）既不安全也不该干；闭包在同一进程内直接传对象
/// 引用，零拷贝、无桥接问题。App 侧在准备 PiP 时把 onFrame 注册进来，
/// PiP 结束(dispose)时置 nil，平时 deliver 只是读一次空判断，开销可忽略。
public class TextureFrameBridge: NSObject {

  /// App 侧（SuikanPiPManager）注册的帧接收回调。
  /// 回调线程 = 渲染线程（media_kit_video 的 iOS 渲染跑在主线程队列上）。
  public var onFrame: ((CVPixelBuffer) -> Void)?

  public static let shared = TextureFrameBridge()

  private override init() {
    super.init()
  }

  /// 渲染完成一帧后调用（TextureHW.render 末尾）。只有 PiP 需要时才真正回调。
  public func deliver(pixelBuffer: CVPixelBuffer) {
    guard let onFrame = onFrame else { return }
    onFrame(pixelBuffer)
  }
}
