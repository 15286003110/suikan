import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:get/get.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/controller/base_controller.dart';

import 'package:simple_live_tv_app/routes/route_path.dart';

class HomeController extends BaseController {
  var datetime = "00:00".obs;

  /// 退出确认框是否正在显示。
  /// main.dart 的返回键拦截用它判断: 确认框打开时按返回应只关闭对话框,
  /// 而不是重新触发 handleBack (Get.isDialogOpen 不识别 Flutter 标准 showDialog)。
  static bool exitDialogShowing = false;

  bool doubleClickExit = false;
  Timer? doubleClickTimer;

  @override
  void onInit() {
    initTimer();
    super.onInit();
  }

  @override
  void onClose() {
    doubleClickTimer?.cancel();
    super.onClose();
  }

  /// 主界面返回键处理: 第一次按提示, 2 秒内再按才弹退出确认框
  void handleBack() {
    if (doubleClickExit) {
      doubleClickTimer?.cancel();
      doubleClickExit = false;
      _showExitConfirm();
      return;
    }
    doubleClickExit = true;
    SmartDialog.showToast("再按一次返回键退出应用");
    doubleClickTimer = Timer(const Duration(seconds: 2), () {
      doubleClickExit = false;
      doubleClickTimer?.cancel();
    });
  }

  /// 弹出退出确认对话框, 确认后才退出程序
  /// 用 Flutter 标准 showDialog + AlertDialog (不用 Get.dialog, 后者在 TV 焦点下会立即关闭)
  Future<void> _showExitConfirm() async {
    doubleClickExit = false;
    doubleClickTimer?.cancel();
    exitDialogShowing = true;
    final context = Get.context;
    if (context == null) {
      exitDialogShowing = false;
      return;
    }
    try {
      final result = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: AppStyle.radius16,
          ),
          title: const Text("退出应用"),
          content: const Text("确定要退出随看吗？"),
          actions: [
            TextButton(
              autofocus: true,
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text("取消"),
            ),
            // 用 ElevatedButton + autofocus 确保 TV 焦点正确处理遥控 OK 键
            ElevatedButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text("确定退出"),
            ),
          ],
        ),
      );
      if (result == true) {
        // 退出前关闭 Hive，确保数据完整落盘（避免播放中退出导致写入不完整，
        // 二次打开读到未完成数据而白屏/卡死——2.1.21 用户实测"退出后再打开页面为空"）。
        try {
          await Hive.close();
        } catch (_) {}
        SystemNavigator.pop();
      }
    } finally {
      exitDialogShowing = false;
    }
  }

  void initTimer() {
    Timer.periodic(const Duration(seconds: 1), (timer) {
      var now = DateTime.now();
      datetime.value =
          "${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}";
    });
  }

  void toSync() {
    Get.toNamed(RoutePath.kSync);
  }

  void toFollow() {
    Get.toNamed(RoutePath.kFollow);
  }

  void toSettings() {
    Get.toNamed(RoutePath.kSettings);
  }

  void toHistory() {
    Get.toNamed(RoutePath.kHistory);
  }

  void toHotLive() {
    Get.toNamed(RoutePath.kHotLive);
  }

  void toSearchRoom(String keyword) {
    Get.toNamed(RoutePath.kSearchRoom, arguments: keyword);
  }

  void toSearchAnchor(String keyword) {
    Get.toNamed(RoutePath.kSearchAnchor, arguments: keyword);
  }

  void toCategory() {
    Get.toNamed(RoutePath.kCategory);
  }
}
