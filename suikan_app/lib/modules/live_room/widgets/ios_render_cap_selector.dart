import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';

/// iPad 专属：在「线路选择」里手动选渲染纹理最长边上限。
///
/// 仅大屏 iPad（屏幕物理最短边 > 1366）显示；iPhone / 安卓 / Win / TV
/// 不显示——这些设备上该上限逻辑上无效果（详见 [kIosRenderCapLongEdge]）。
///
/// 选项值即「渲染纹理最长边像素」：0 = 不限制（原始画质）；
/// 1280/1600/1920 越大越清晰、降温越弱。生效时机为下一次开播/切流。
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
    0: '原画 · 不限制',
    1280: '省电档 · 1280',
    1600: '均衡档 · 1600',
    1920: '高清档 · 1920',
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
              '画面清晰度上限（降温用）',
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
