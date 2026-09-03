import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';

/// iPad 专属：在「线路选择」里手动选渲染纹理最长边上限。
///
/// 仅大屏 iPad（屏幕物理最短边 > 1366）显示；iPhone / 安卓 / Win / TV
/// 不显示——这些设备上该上限逻辑上无效果（详见 [kIosRenderCapLongEdge]）。
///
/// 选项值即「渲染纹理最长边像素」：0 = 原画·屏幕原生（默认，渲染不超屏幕物理
/// 像素，视觉无损）；1280/1600/1920 为主动降温档，压得越低越省但画面越糊
/// （1920 只对超过 1920 的源如 4K 生效）。切换后即时重设纹理生效。
Widget buildIosRenderCapSelector() {
  if (!Platform.isIOS || Get.context == null) {
    return const SizedBox.shrink();
  }
  // ⚠️ 必须用「物理像素」判定，与 player_controller 的生效门槛一致。
  // 之前误用 MediaQuery.size（逻辑点，iPad 普遍 768~1194），导致所有 iPad
  // 上选择器都 <1366 不显示，但渲染上限实际已按 physicalSize 生效——
  // 用户看不到开关、也没法关（2026-09-03 hotfix 修正）。
  final views = WidgetsBinding.instance.platformDispatcher.views;
  if (views.isEmpty) {
    return const SizedBox.shrink();
  }
  final shortest = views.first.physicalSize.shortestSide;
  if (shortest <= 1366) {
    return const SizedBox.shrink();
  }

  const options = <int, String>{
    0: '原画 · 屏幕原生（默认）',
    1280: '1280 · 强降温（较糊）',
    1600: '1600 · 中降温（微糊）',
    1920: '1920 · 弱降温（仅 4K 源）',
  };
  final settings = AppSettingsController.instance;

  return Obx(
    () {
      final current = settings.iosRenderCapLongEdge.value;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: Text(
              '画面渲染档位（默认原画 · 不超屏幕）',
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
            ),
          ),
          ...options.entries.map(
            (e) => RadioListTile<int>(
              dense: true,
              title: Text(e.value, style: const TextStyle(fontSize: 14)),
              value: e.key,
              groupValue: current,
              onChanged: (v) {
                if (v == null) return;
                settings.setIosRenderCapLongEdge(v);
              },
            ),
          ),
        ],
      );
    },
  );
}
