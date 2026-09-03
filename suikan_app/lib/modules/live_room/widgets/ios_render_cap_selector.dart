import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';

/// iPad 专属：在「线路选择」里手动选渲染纹理最长边上限。
///
/// 仅大屏 iPad（屏幕物理最短边 > 1366）显示；iPhone / 安卓 / Win / TV
/// 不显示——这些设备上该上限逻辑上无效果（详见 [kIosRenderCapLongEdge]）。
///
/// 选项值即「渲染纹理最长边像素」：0 = 关闭（原始画质，不限制）；
/// 1280/1600/1920 越大越清晰、降温越弱。改变后由 player_controller 的
/// [ever] 监听即时重设 mpv 纹理，无需重开流。
Widget buildIosRenderCapSelector() {
  if (!Platform.isIOS || Get.context == null) {
    return const SizedBox.shrink();
  }
  final shortest = MediaQuery.of(Get.context!).size.shortestSide;
  if (shortest <= 1366) {
    return const SizedBox.shrink();
  }

  const options = <int, String>{
    0: '关闭（原始画质）',
    1280: '1280 · 省电优先',
    1600: '1600 · 均衡',
    1920: '1920 · 画质优先',
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
              '渲染分辨率上限',
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
