import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// iOS / iPadOS 的**系统画中画**（小窗播放）。
///
/// 背景：随看的播放内核是 mpv，而苹果的系统画中画只认 AVPlayerLayer 或
/// AVSampleBufferDisplayLayer。原生侧（SuikanPiPManager）负责把 mpv 的每一帧
/// （CVPixelBuffer）转成 CMSampleBuffer 喂给 AVSampleBufferDisplayLayer，
/// 再由 AVPictureInPictureController 呈现系统小窗。
///
/// 这个类只负责 Dart ↔ 原生的方法通道：
/// - Dart 调原生：isSupported / start / stop / isActive
/// - 原生调 Dart：onPipState（小窗开关状态）、onPlayPause（小窗里的播放/暂停）
class IosPipService {
  IosPipService._();

  static const MethodChannel _channel = MethodChannel('suikan/pip');

  /// 小窗是否处于激活状态（原生推送）
  static final ValueNotifier<bool> active = ValueNotifier<bool>(false);

  /// 小窗里的播放/暂停按钮被点击时触发（参数为是否要播放）
  static void Function(bool playing)? onPlayPause;

  /// 原生侧 PiP 出错/失败原因（用于弹提示，避免"点了没反应"）
  static void Function(String message)? onError;

  static bool _initialized = false;

  /// 注册原生回调。在播放器初始化时调用一次即可。
  static void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onPlayPause':
          onPlayPause?.call(call.arguments as bool? ?? true);
          break;
        case 'onPipState':
          active.value = call.arguments as bool? ?? false;
          break;
        case 'onError':
          onError?.call(call.arguments as String? ?? '小窗播放失败');
          break;
      }
      return null;
    });
  }

  /// 设备/系统是否支持系统画中画
  static Future<bool> isSupported() async {
    try {
      return await _channel.invokeMethod<bool>('isSupported') ?? false;
    } on PlatformException {
      return false;
    }
  }

  /// 进入小窗（必须由用户点击触发，苹果不允许程序自动开启）
  static Future<void> start() => _channel.invokeMethod('start');

  /// 退出小窗
  static Future<void> stop() => _channel.invokeMethod('stop');

  static Future<bool> isActive() async {
    try {
      return await _channel.invokeMethod<bool>('isActive') ?? false;
    } on PlatformException {
      return false;
    }
  }
}
