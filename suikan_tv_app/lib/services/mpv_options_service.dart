import 'dart:io';

import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';

class MpvOptionsService {
  static const Map<String, String> profileLabels = {
    "performance": "兼容",
    "balanced": "均衡",
    "quality": "高画质",
  };

  static const Map<String, Map<String, String>> profiles = {
    "performance": {
      "profile": "fast",
      "hwdec": "auto-safe",
      "vo": "gpu",
      "scale": "bilinear",
      "cscale": "bilinear",
      "dscale": "bilinear",
      "correct-downscaling": "no",
      "sigmoid-upscaling": "no",
      "deband": "no",
    },
    "balanced": {
      "profile": "gpu-hq",
      "hwdec": "auto-safe",
      "vo": "gpu",
      "scale": "spline36",
      "cscale": "spline36",
      "dscale": "mitchell",
      "deband": "no",
    },
    "quality": {
      "profile": "gpu-hq",
      "hwdec": "auto-safe",
      "vo": "gpu",
      "scale": "spline36",
      "cscale": "spline36",
      "dscale": "mitchell",
      "correct-downscaling": "yes",
      "sigmoid-upscaling": "yes",
      "deband": "yes",
    },
  };

  static Map<String, String> effectiveOptions() {
    final settings = AppSettingsController.instance;
    final profile = settings.mpvProfile.value;
    return <String, String>{
      ...profiles[profile] ?? profiles["balanced"]!,
    };
  }

  static VideoControllerConfiguration videoControllerConfiguration() {
    final settings = AppSettingsController.instance;
    if (settings.playerCompatMode.value && Platform.isAndroid) {
      return const VideoControllerConfiguration(
        vo: 'mediacodec_embed',
        hwdec: 'mediacodec',
      );
    }
    final options = effectiveOptions();
    // 硬件解码开关: 关 → 强制软解 (老盒子 S905L GPU 硬解渲染黑屏)
    final effectiveHwdec = settings.hardwareDecode.value
        ? options["hwdec"]
        : "no";
    if (!Platform.isAndroid) {
      return VideoControllerConfiguration(
        hwdec: effectiveHwdec,
        enableHardwareAcceleration: settings.hardwareDecode.value,
      );
    }
    return VideoControllerConfiguration(
      vo: options["vo"],
      hwdec: effectiveHwdec,
      enableHardwareAcceleration: settings.hardwareDecode.value,
      // Fix TV多开灰屏/Android全屏卡死: 延迟attach避免surface race condition
      androidAttachSurfaceAfterVideoParameters: true,
    );
  }

  static Future<void> applyToPlayer(
    Player player, {
    bool isVod = false,
  }) async {
    if (player.platform is! NativePlayer) {
      return;
    }
    final options = Map<String, String>.from(effectiveOptions())
      ..remove("vo")
      ..remove("hwdec");
    // 缓冲策略：直播小缓冲（低延迟）、点播大缓冲（不卡）。
    // 属性为 mpv 网络/解复用缓冲上限与预读时长，setProperty 失败静默忽略。
    options["demuxer-max-bytes"] = isVod ? "134217728" : "16777216";
    options["demuxer-readahead-secs"] = isVod ? "30" : "5";
    options["cache-secs"] = isVod ? "30" : "5";
    for (final entry in options.entries) {
      try {
        await (player.platform as dynamic).setProperty(entry.key, entry.value);
      } catch (e) {
        Log.d("mpv option skipped: ${entry.key}=${entry.value} $e");
      }
    }
  }
}
