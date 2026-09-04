import 'package:flutter/services.dart';

/// 系统媒体中心控制（iOS 锁屏/控制中心/耳机线控 + Android 通知栏/MediaSession）。
///
/// media_kit 不内置系统媒体能力，需 App 自己接：
/// - **显示**：标题 / 主播 / 封面 / 直播标记 / 影视进度
/// - **控制**：播放 / 暂停 / 下一首（切线路或下一集）/ 上一首 / 进度拖动（影视）
///
/// 两端通过 MethodChannel `suikan/media` 通信，只在移动端生效，
/// 桌面端所有调用都是空操作（PlatformException 已吞掉）。
class MediaControlService {
  MediaControlService._();

  static const MethodChannel _channel = MethodChannel('suikan/media');

  /// 系统媒体中心发来的命令：play / pause / toggle / next / prev / seek。
  static void Function(MediaCommand command)? onCommand;

  static bool _initialized = false;

  static void init() {
    if (_initialized) {
      return;
    }
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onCommand') {
        final args = call.arguments;
        if (args is Map) {
          onCommand
              ?.call(MediaCommand.fromMap(Map<String, dynamic>.from(args)));
        } else if (args is String) {
          // 兼容旧协议（原生直接传命令字符串）
          onCommand?.call(MediaCommand(command: args));
        }
      }
      return null;
    });
  }

  /// 更新锁屏/控制中心/通知栏显示的信息（进直播间或切台后调用）。
  ///
  /// [duration]/[position] 单位为秒，仅影视传入；直播传 null。
  /// [coverUrl] 封面地址，原生侧异步下载并缓存。
  static Future<void> update({
    required String title,
    required String artist,
    required bool isLive,
    required bool playing,
    String? coverUrl,
    double? duration,
    double? position,
    bool canNext = false,
    bool canPrev = false,
  }) async {
    try {
      await _channel.invokeMethod('update', {
        'title': title,
        'artist': artist,
        'isLive': isLive,
        'playing': playing,
        'coverUrl': coverUrl,
        'duration': duration,
        'position': position,
        'canNext': canNext,
        'canPrev': canPrev,
      });
    } on PlatformException catch (_) {
      // 桌面端无原生实现，忽略
    } on MissingPluginException catch (_) {
      // 同上
    }
  }

  /// 只更新播放/暂停状态（控制中心按钮与通知栏按钮依赖它）。
  /// [position] 为当前播放进度（秒），影视可传。
  static Future<void> setPlaying(bool playing, {double? position}) async {
    try {
      await _channel.invokeMethod(
        'setPlaying',
        {'playing': playing, 'position': position},
      );
    } on PlatformException catch (_) {
      // 忽略
    } on MissingPluginException catch (_) {
      // 忽略
    }
  }

  /// 更新播放进度（秒）。仅影视需要，直播忽略。
  static Future<void> setPosition(double position) async {
    try {
      await _channel.invokeMethod('setPosition', {'position': position});
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

/// 系统媒体中心发来的一条命令。
class MediaCommand {
  const MediaCommand({required this.command, this.position});

  /// 命令名：play / pause / toggle / next / prev / seek
  final String command;

  /// seek 命令的目标位置（秒）。
  final double? position;

  factory MediaCommand.fromMap(Map<String, dynamic> m) => MediaCommand(
        command: m['command'] as String? ?? 'toggle',
        position: (m['position'] as num?)?.toDouble(),
      );
}
