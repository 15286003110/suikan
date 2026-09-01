import 'dart:async';
import 'dart:io';

import 'package:canvas_danmaku/canvas_danmaku.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/services/mpv_options_service.dart';
import 'package:simple_live_core/simple_live_core.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

mixin PlayerMixin {
  GlobalKey<VideoState> globalPlayerKey = GlobalKey<VideoState>();
  GlobalKey globalDanmuKey = GlobalKey();

  /// 播放器实例
  late final player = Player(
    configuration: const PlayerConfiguration(
      title: "随看",
      // bufferSize:
      //     // media-kit #549
      //     AppSettingsController.instance.playerBufferSize.value * 1024 * 1024,
    ),
  );

  /// 视频控制器
  late final videoController = VideoController(
    player,
    configuration: MpvOptionsService.videoControllerConfiguration(),
  );

  Future<void> initializePlayer({bool isVod = false}) async {
    await MpvOptionsService.applyToPlayer(player, isVod: isVod);
  }
}
mixin PlayerStateMixin on PlayerMixin {
  /// 是否显示弹幕
  RxBool showDanmakuState = false.obs;

  /// 是否显示控制器
  RxBool showControlsState = false.obs;

  /// 是否显示设置窗口
  RxBool showSettingState = false.obs;

  /// 是否显示弹幕设置窗口
  RxBool showDanmakuSettingState = false.obs;

  /// 是否处于锁定控制器状态
  RxBool lockControlsState = false.obs;

  /// 是否处于全屏状态
  RxBool fullScreenState = false.obs;

  /// 显示手势Tip
  RxBool showGestureTip = false.obs;

  /// 手势Tip文本
  RxString gestureTipText = "".obs;

  /// 显示提示底部Tip
  RxBool showBottomTip = false.obs;

  /// 提示底部Tip文本
  RxString bottomTipText = "".obs;

  /// 自动隐藏控制器计时器
  Timer? hideControlsTimer;

  /// 自动隐藏提示计时器
  Timer? hideSeekTipTimer;

  Widget? danmakuView;

  var showQualites = false.obs;
  var showLines = false.obs;

  /// 隐藏控制器
  void hideControls() {
    showControlsState.value = false;
    hideControlsTimer?.cancel();
  }

  void setLockState() {
    lockControlsState.value = !lockControlsState.value;
    if (lockControlsState.value) {
      showControlsState.value = false;
    } else {
      showControlsState.value = true;
    }
  }

  /// 显示控制器
  void showControls() {
    showControlsState.value = true;
    resetHideControlsTimer();
  }

  /// 开始隐藏控制器计时
  /// - 当点击控制器上时功能时需要重新计时
  void resetHideControlsTimer() {
    hideControlsTimer?.cancel();

    hideControlsTimer = Timer(
      const Duration(
        seconds: 5,
      ),
      hideControls,
    );
  }

  void updateScaleMode() {
    var boxFit = BoxFit.contain;
    double? aspectRatio;
    if (player.state.width != null && player.state.height != null) {
      aspectRatio = player.state.width! / player.state.height!;
    }

    if (AppSettingsController.instance.scaleMode.value == 0) {
      boxFit = BoxFit.contain;
    } else if (AppSettingsController.instance.scaleMode.value == 1) {
      boxFit = BoxFit.fill;
    } else if (AppSettingsController.instance.scaleMode.value == 2) {
      boxFit = BoxFit.cover;
    } else if (AppSettingsController.instance.scaleMode.value == 3) {
      boxFit = BoxFit.contain;
      aspectRatio = 16 / 9;
    } else if (AppSettingsController.instance.scaleMode.value == 4) {
      boxFit = BoxFit.contain;
      aspectRatio = 4 / 3;
    }
    globalPlayerKey.currentState?.update(
      aspectRatio: aspectRatio,
      fit: boxFit,
    );
  }
}
mixin PlayerDanmakuMixin on PlayerStateMixin {
  /// 弹幕控制器
  DanmakuController? danmakuController;

  void initDanmakuController(DanmakuController e) {
    danmakuController = e;
    // danmakuController?.updateOption(
    //   DanmakuOption(
    //     fontSize: AppSettingsController.instance.danmuSize.value.w,
    //     area: AppSettingsController.instance.danmuArea.value,
    //     duration: AppSettingsController.instance.danmuSpeed.value,
    //     opacity: AppSettingsController.instance.danmuOpacity.value,
    //     strokeWidth: AppSettingsController.instance.danmuStrokeWidth.value.w,
    //   ),
    // );
  }

  void updateDanmuOption(DanmakuOption? option) {
    if (danmakuController == null || option == null) return;
    danmakuController!.updateOption(option);
  }

  void disposeDanmakuController() {
    danmakuController?.clear();
  }

  void addDanmaku(List<DanmakuContentItem> items) {
    if (!showDanmakuState.value) {
      return;
    }
    for (var item in items) {
      danmakuController?.addDanmaku(item);
    }
  }

  /// 开关弹幕。
  ///
  /// 不要直接改 `showDanmakuState.value` —— 那只是个 UI 状态，DanmakuScreen
  /// 收不到任何通知：Offstage 只跳过 paint，`_animationController.repeat()`
  /// 和 100ms 的清理循环照常在跑，已存在的弹幕继续走完整套计算。
  void setDanmakuVisible(bool visible) {
    if (showDanmakuState.value == visible) {
      return;
    }
    showDanmakuState.value = visible;
    if (visible) {
      danmakuController?.resume();
    } else {
      // 先 clear 再 pause：残留的 DanmakuItem 每条都持有 Paragraph /
      // strokeParagraph（Skia native 内存，Dart GC 管不到），热门房一屏能堆
      // 上百条。pause() 只停动画和定时器，不释放这些缓存。
      danmakuController?.clear();
      danmakuController?.pause();
    }
  }
}
mixin PlayerSystemMixin on PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin {
  final DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();

  /// 初始化一些系统状态
  void initSystem() async {
    // 屏幕常亮
    WakelockPlus.enable();

    // 开始隐藏计时
    resetHideControlsTimer();
  }

  /// 释放一些系统状态
  Future resetSystem() async {
    await WakelockPlus.disable();
  }

  /// 是否是IOS16以下
  Future<bool> beforeIOS16() async {
    if (Platform.isIOS) {
      var info = await deviceInfo.iosInfo;
      var version = info.systemVersion;
      var versionInt = int.tryParse(version.split('.').first) ?? 0;
      return versionInt < 16;
    } else {
      return false;
    }
  }
}

class PlayerController extends BaseController
    with PlayerMixin, PlayerStateMixin, PlayerDanmakuMixin, PlayerSystemMixin {
  @override
  void onInit() {
    initSystem();
    initStream();
    super.onInit();
  }

  var width = 0.obs;
  var height = 0.obs;

  StreamSubscription<String>? _errorSubscription;
  StreamSubscription? _completedSubscription;
  StreamSubscription? _widthSubscription;
  StreamSubscription? _heightSubscription;
  StreamSubscription? _logSubscription;
  StreamSubscription? _positionSubscription;
  StreamSubscription? _durationSubscription;
  DateTime? _lastAudioDiagnosticTime;

  /// 点播当前进度（秒）
  var vodPosition = 0.obs;

  /// 点播总时长（秒，直播为 0）
  var vodDuration = 0.obs;

  void initStream() {
    _errorSubscription = player.stream.error.listen((event) {
      if (PlayerErrorClassifier.isRecoverableAudioDiagnostic(event)) {
        final now = DateTime.now();
        if (_lastAudioDiagnosticTime == null ||
            now.difference(_lastAudioDiagnosticTime!) >=
                const Duration(seconds: 15)) {
          _lastAudioDiagnosticTime = now;
          Log.d("播放器音频诊断（已忽略）：$event");
        }
        return;
      }
      Log.d("播放器错误：$event");
      //SmartDialog.showToast(event);
      mediaError(event);
    });

    _completedSubscription = player.stream.completed.listen((event) {
      if (event) {
        mediaEnd();
      }
    });
    // 点播进度：影视库/投屏影视需要进度条与快进快退，直播用不到但订阅无害。
    _positionSubscription = player.stream.position.listen((event) {
      vodPosition.value = event.inSeconds;
    });
    _durationSubscription = player.stream.duration.listen((event) {
      vodDuration.value = event.inSeconds;
      // 第三方投屏端（飞牛影视、虎牙等）不会带 SuikanCastType 标记，isVod 一律
      // 是 false → 没有进度条、左右键也不快进，只弹"按键说明"（用户反馈的原话）。
      // 这里按**总时长**自动补判点播：直播流 mpv 报的 duration 恒为 0，
      // 有明确总时长的一定是点播文件。阈值取 10 秒是躲开开播瞬间的诡异小值。
      if (event.inSeconds >= 10) {
        onDurationDetected(event.inSeconds);
      }
    });
    _logSubscription = player.stream.log.listen((event) {
      Log.d("播放器日志：$event");
    });
    _widthSubscription = player.stream.width.listen((event) {
      Log.w(
          'width:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      width.value = event ?? 0;
      // isVertical.value =
      //     (player.state.height ?? 9) > (player.state.width ?? 16);
    });
    _heightSubscription = player.stream.height.listen((event) {
      Log.w(
          'height:$event  W:${(player.state.width)}  H:${(player.state.height)}');
      height.value = event ?? 0;
      // isVertical.value =
      //     (player.state.height ?? 9) > (player.state.width ?? 16);
    });
  }

  void disposeStream() {
    _seekThrottleTimer?.cancel();
    _seekThrottleTimer = null;
    _errorSubscription?.cancel();
    _completedSubscription?.cancel();
    _widthSubscription?.cancel();
    _heightSubscription?.cancel();
    _logSubscription?.cancel();
    _positionSubscription?.cancel();
    _durationSubscription?.cancel();
  }

  /// 快进/快退（秒，负数后退）。点播（影视库/投屏影视）可用。
  ///
  /// 遥控长按方向键时系统按重复率连发 keydown，所以按**按住时长分级加速**：
  /// 刚按下是 10 秒/次，按得越久单次跨度越大（10 → 30 → 60 → 120 秒），
  /// 同时把触发间隔同步拉长（150 → 250 → 300 → 350ms）——只放大步进而不拉长
  /// 间隔，会在几百毫秒内灌进几十条 seek，解复用器跟不上、画面长时间黑屏。
  ///
  /// 单击立即执行、无延迟感；松手后（700ms 内没有新的 keydown）自动复位，
  /// 下次按下重新从 10 秒起步。**不依赖 KeyUpEvent**：直播页把 KeyUpEvent
  /// 直接 ignored 了，这里拿不到按键抬起事件，只能按空闲时长判断。
  static const Duration _seekIdleReset = Duration(milliseconds: 700);

  int _pendingSeekDelta = 0;
  Timer? _seekThrottleTimer;
  DateTime? _seekPressStart;
  DateTime? _lastSeekEvent;
  DateTime? _lastSeekApply;
  int _lastSeekTier = 0;

  void seekRelative(int seconds) {
    final now = DateTime.now();
    // 距上次按键超过空闲阈值 → 当作新的一次按压，档位从头开始。
    // 阈值取 700ms 是为了跨过遥控的「长按首次重复延迟」（约 400~500ms），
    // 否则按下后第一个重复事件会被误判成新按压，档位永远升不上去。
    if (_lastSeekEvent == null ||
        now.difference(_lastSeekEvent!) > _seekIdleReset) {
      _seekPressStart = now;
      _lastSeekTier = 0;
    }
    _lastSeekEvent = now;

    final tier = _seekTier(now.difference(_seekPressStart!));
    _pendingSeekDelta += seconds * _seekStepScale(tier);

    // 换档提示：让用户知道"按久了已经变快了"，避免以为按键失灵。
    // 只在档位升高时提示，单击（0 档）不提示，连按也不会刷屏。
    if (tier > _lastSeekTier) {
      _lastSeekTier = tier;
      try {
        SmartDialog.showToast(
            '${seconds < 0 ? '快退' : '快进'} ${10 * _seekStepScale(tier)} 秒/次');
      } catch (_) {}
    }

    final sinceLast =
        _lastSeekApply == null ? null : now.difference(_lastSeekApply!);
    final interval = _seekInterval(tier);
    _seekThrottleTimer?.cancel();
    if (sinceLast == null || sinceLast.inMilliseconds >= interval) {
      _applySeekDelta();
    } else {
      _seekThrottleTimer = Timer(
          Duration(milliseconds: interval - sinceLast.inMilliseconds),
          _applySeekDelta);
    }
  }

  /// 按住时长 → 档位（0 起步，越久越高）。
  int _seekTier(Duration held) {
    final ms = held.inMilliseconds;
    if (ms >= 4500) return 3;
    if (ms >= 2500) return 2;
    if (ms >= 1000) return 1;
    return 0;
  }

  /// 档位 → 步进倍率（调用方传入的基准是 10 秒）。
  int _seekStepScale(int tier) {
    switch (tier) {
      case 1:
        return 3; // 30 秒
      case 2:
        return 6; // 60 秒
      case 3:
        return 12; // 120 秒
      default:
        return 1; // 10 秒
    }
  }

  /// 档位 → 两次实际 seek 之间的最小间隔（档位越高越慢，防止灌爆解复用器）。
  int _seekInterval(int tier) {
    switch (tier) {
      case 1:
        return 250;
      case 2:
        return 300;
      case 3:
        return 350;
      default:
        return 150;
    }
  }

  void _applySeekDelta() {
    _seekThrottleTimer = null;
    _lastSeekApply = DateTime.now();
    final delta = _pendingSeekDelta;
    _pendingSeekDelta = 0;
    if (delta == 0) return;
    final total = vodDuration.value;
    var target = vodPosition.value + delta;
    if (target < 0) target = 0;
    if (total > 0 && target > total) target = total;
    try {
      player.seek(Duration(seconds: target));
      vodPosition.value = target;
    } catch (_) {}
  }

  static String formatVodTime(int seconds) {
    final d = Duration(seconds: seconds < 0 ? 0 : seconds);
    final h = d.inHours;
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return h > 0 ? '$h:$m:$s' : '$m:$s';
  }

  /// 探测到明确的**总时长**（点播特征）时回调。
  ///
  /// 基类空实现，直播间控制器按需覆写，用于把"直播态"升级成"点播态"。
  /// 只在第三方投屏没有类型标记时才需要，自有投屏与影视库都会显式带 isVod。
  void onDurationDetected(int seconds) {}

  /// 播放/暂停切换。
  ///
  /// 点播（影视库/投屏影视）的确认键走这里——主流 TV 播放器（云视听、极光、
  /// 当贝播放器）全是"确认 = 播放/暂停"。直播不接这个键：直播暂停后画面
  /// 停在旧帧、恢复还要重新追帧，误触代价太大。
  Future<void> togglePlayPause() async {
    try {
      if (player.state.playing) {
        await player.pause();
      } else {
        await player.play();
      }
    } catch (_) {}
  }

  /// 音量步进（点播场景的上下键）。返回调整后的音量（0~100），便于提示。
  ///
  /// 点播没有"上一个/下一个频道"的概念（影视库选集在详情页完成），
  /// 上下键空着不如按主流播放器做成音量。直播保持切频道不变。
  Future<int> adjustVolume(int delta) async {
    final next = (player.state.volume + delta).clamp(0.0, 100.0);
    try {
      await player.setVolume(next);
    } catch (_) {}
    return next.round();
  }

  void mediaEnd() {}

  /// 播放器错误：记录日志 + 弹提示（投屏/播放失败时用户能直接看到原因，
  /// 如 403/超时/格式不支持——此前静默只有黑屏，无法定位）。
  void mediaError(String error) {
    Log.e("播放器错误：$error", StackTrace.current);
    // 播放失败时用 SmartDialog 提示（错误文本即 mpv 原因，便于反馈定位）
    try {
      SmartDialog.showToast("播放失败：$error");
    } catch (_) {}
  }

  @override
  void onClose() async {
    Log.w("播放器关闭");
    disposeStream();
    disposeDanmakuController();
    await resetSystem();
    await player.dispose();
    super.onClose();
  }
}
