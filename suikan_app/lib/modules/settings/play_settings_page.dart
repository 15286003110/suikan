import 'dart:io';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_app/widgets/settings/settings_card.dart';
import 'package:simple_live_app/widgets/settings/settings_menu.dart';
import 'package:simple_live_app/widgets/settings/settings_number.dart';
import 'package:simple_live_app/widgets/settings/settings_switch.dart';

class PlaySettingsPage extends GetView<AppSettingsController> {
  const PlaySettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("直播间设置"),
      ),
      body: ListView(
        padding: AppStyle.pagePadding(),
        children: [
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 0),
            child: Text(
              "播放器",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: Platform.isIOS ? "硬件加速" : "硬件解码",
                    value: controller.hardwareDecode.value,
                    onChanged: (e) {
                      controller.setHardwareDecode(e);
                    },
                  ),
                ),
                if (Platform.isIOS) AppStyle.divider,
                if (Platform.isIOS)
                  Obx(
                    () => SettingsSwitch(
                      title: "省电模式(降低清晰度)",
                      value: controller.iosOriginalQualityPowerSaving.value,
                      onChanged: controller.setIosOriginalQualityPowerSaving,
                    ),
                  ),
                if (Platform.isAndroid) AppStyle.divider,
                Obx(
                  () => Visibility(
                    visible: Platform.isAndroid,
                    child: SettingsSwitch(
                      title: "卡顿兼容模式",
                      value: controller.playerCompatMode.value,
                      onChanged: (e) {
                        controller.setPlayerCompatMode(e);
                      },
                    ),
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "强制 HTTPS 播放",
                    value: controller.playerForceHttps.value,
                    onChanged: (e) {
                      controller.setPlayerForceHttps(e);
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "手势与全屏",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: "滑动调节音量/亮度",
                    value: controller.playerGestureControlEnable.value,
                    onChanged: (e) {
                      controller.setPlayerGestureControlEnable(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "进入直播间自动全屏",
                    value: controller.autoFullScreen.value,
                    onChanged: (e) {
                      controller.setAutoFullScreen(e);
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "直播间",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: "关播后自动换下一个直播间",
                    value: controller.autoSwitchNextOnLiveEnd.value,
                    onChanged: (e) {
                      controller.setAutoSwitchNextOnLiveEnd(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "播放失败后自动换下一个直播间",
                    value: controller.autoSwitchNextOnPlaybackFailure.value,
                    onChanged: (e) {
                      controller.setAutoSwitchNextOnPlaybackFailure(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "播放器中显示SC",
                    value: controller.playershowSuperChat.value,
                    onChanged: (e) {
                      controller.setPlayerShowSuperChat(e);
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "后台与小窗",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsSwitch(
                    title: "后台播放",
                    value: controller.allowBackgroundPlayback.value,
                    onChanged: (e) {
                      controller.setAllowBackgroundPlayback(e);
                    },
                  ),
                ),
                if (Platform.isAndroid) AppStyle.divider,
                if (Platform.isAndroid)
                  Obx(
                    () => SettingsSwitch(
                      title: "退后台自动小窗",
                      value: controller.autoPipOnExit.value,
                      onChanged: (e) {
                        controller.setAutoPipOnExit(e);
                      },
                    ),
                  ),
                if (Platform.isAndroid) AppStyle.divider,
                if (Platform.isAndroid)
                  Obx(
                    () => SettingsSwitch(
                      title: "进入小窗隐藏弹幕",
                      value: controller.pipHideDanmu.value,
                      onChanged: (e) {
                        controller.setPIPHideDanmu(e);
                      },
                    ),
                  ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "清晰度与画面",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsMenu<int>(
                    title: "默认清晰度",
                    value: controller.qualityLevel.value,
                    valueMap: const {
                      0: "最低",
                      1: "中等",
                      2: "最高",
                    },
                    onChanged: (e) {
                      controller.setQualityLevel(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsMenu<int>(
                    title: "数据网络清晰度",
                    value: controller.qualityLevelCellular.value,
                    valueMap: const {
                      0: "最低",
                      1: "中等",
                      2: "最高",
                    },
                    onChanged: (e) {
                      controller.setQualityLevelCellular(e);
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsMenu<int>(
                    title: "画面尺寸",
                    value: controller.scaleMode.value,
                    valueMap: const {
                      0: "适应",
                      1: "拉伸",
                      2: "铺满",
                      3: "16:9",
                      4: "4:3",
                    },
                    onChanged: (e) {
                      controller.setScaleMode(e);
                    },
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: AppStyle.edgeInsetsA12.copyWith(top: 24),
            child: Text(
              "聊天区",
              style: Get.textTheme.titleSmall,
            ),
          ),
          SettingsCard(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Obx(
                  () => SettingsNumber(
                    title: "文字大小",
                    value: controller.chatTextSize.value.toInt(),
                    min: 8,
                    max: 36,
                    onChanged: (e) {
                      controller.setChatTextSize(e.toDouble());
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsNumber(
                    title: "上下间隔",
                    value: controller.chatTextGap.value.toInt(),
                    min: 0,
                    max: 12,
                    onChanged: (e) {
                      controller.setChatTextGap(e.toDouble());
                    },
                  ),
                ),
                AppStyle.divider,
                Obx(
                  () => SettingsSwitch(
                    title: "气泡样式",
                    value: controller.chatBubbleStyle.value,
                    onChanged: (e) {
                      controller.setChatBubbleStyle(e);
                    },
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
