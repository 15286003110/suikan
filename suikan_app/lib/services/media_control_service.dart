import 'package:flutter/services.dart';

/// 系统媒体中心控制（iOS 锁屏/控制中心 + Android 通知栏）。
///
/// media_kit 不内置系统媒体能力，需 App 自己接：
/// - **显示**：iOS 走 MPNowPlayingInfoCenter；Android 由已有的前台服务通知承担
/// - **控制**：iOS 走 MPRemoteCommandCenter（含耳机线控）；
///   Android 走前台服务通知上的播放/暂停按钮
///
/// 两端通过 MethodChannel `suikan/media` 通信，只在移动端生效，
/// 桌面端所有调用都是空操作（PlatformException 已吞掉）。
class MediaControlService {
  MediaControlService._();

  static const MethodChannel _channel = MethodChannel('suikan/media');

  /// 系统媒体中心发来的命令：play / pause / toggle
  static void Function(String command)? onCommand;

  static bool _initialized = false;

  static void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCommand') {
        onCommand?.call(call.arguments as String? ?? 'toggle');
      }
      return null;
    });
  }

  /// 更新锁屏/通知栏显示的信息（进直播间或切台后调用）。
  static Future<void> update({
    required String title,
    required String artist,
    required bool isLive,
    required bool playing,
  }) async {
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'artist': artist,
        'isLive': isLive,
        'playing': playing,
      });
    } on PlatformException catch (_) {
      // 桌面端无原生实现，忽略
    } on MissingPluginException catch (_) {
      // 同上
    }
  }

  /// 只更新播放/暂停状态（控制中心按钮与 Android 通知按钮依赖它）。
  static Future<void> setPlaying(bool playing) async {
    try {
      await _channel.invokeMethod('setPlaying', {'playing': playing});
    } on PlatformException catch (_) {
      // 忽略
    } on MissingPluginException catch (_) {
      // 忽略
    }
  }

  /// 离开直播间/关闭播放器：清掉锁屏信息。
  static Future<void> clear() async {
    try {
      await _channel.invokeMethod('clear');
    } on PlatformException catch (_) {
      // 忽略
    } on MissingPluginException catch (_) {
      // 忽略
    }
  }
}
