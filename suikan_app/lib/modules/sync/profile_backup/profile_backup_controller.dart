import 'dart:convert';
import 'dart:io';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_smart_dialog/flutter_smart_dialog.dart';
import 'package:simple_live_app/app/controller/base_controller.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/utils.dart';
import 'package:simple_live_app/services/profile_backup_service.dart';
import 'package:simple_live_app/widgets/sync_progress_dialog.dart';
import 'package:simple_live_core/simple_live_core.dart';

class ProfileBackupController extends BaseController {
  Future<void> exportProfile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("没有存储权限");
        return;
      }
      final content = ProfileBackupService.instance.exportProfileJson();
      final fileName =
          "Suikan_Profile_${DateTime.now().millisecondsSinceEpoch ~/ 1000}.json";
      final inlineSave = Platform.isAndroid || Platform.isIOS || kIsWeb;
      final path = await FilePicker.platform.saveFile(
        allowedExtensions: ["json"],
        type: FileType.custom,
        fileName: fileName,
        bytes: inlineSave ? utf8.encode(content) : null,
      );
      if (path == null && !kIsWeb) {
        return;
      }
      if (!inlineSave && path != null) {
        await File(path).writeAsString(content);
      }
      SmartDialog.showToast("已导出配置包");
    } catch (e) {
      Log.logPrint(e);
      SmartDialog.showToast("导出失败：$e");
    }
  }

  Future<void> importProfile() async {
    try {
      var status = await Utils.checkStorgePermission();
      if (!status) {
        SmartDialog.showToast("没有存储权限");
        return;
      }
      // ⚠️ 顺序很关键：**先选文件**，才能把配置包里的条数摆给用户看。
      // 原先在这里就弹"是否覆盖"，那时还不知道包里有多少条，用户等于蒙着眼睛
      // 做决定 —— 拿一份 51 条的旧备份覆盖掉本机两百来条较新的关注就是这样
      // 发生的（2026-08-31）。改成：选文件 → 预览条数 → 再问覆盖。
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ["json"],
      );
      if (picked == null || picked.files.single.path == null) {
        return;
      }
      final content = await File(picked.files.single.path!).readAsString();
      final overwrite = await Utils.showAlertDialog(
        ProfileBackupService.instance.buildImportPrompt(
          ProfileBackupService.instance.previewProfile(content),
        ),
        title: "导入配置包",
        confirm: "覆盖",
        cancel: "不覆盖",
      );
      SyncProgressDialog.show(const SyncProgress(stage: "正在导入配置包"));
      final summary = await ProfileBackupService.instance.importProfileJson(
        content,
        overwrite: overwrite,
        onProgress: SyncProgressDialog.update,
      );
      SyncProgressDialog.dismiss();
      SmartDialog.showToast("导入完成：${summary.message}");
    } catch (e) {
      SyncProgressDialog.dismiss();
      Log.logPrint(e);
      SmartDialog.showToast("导入失败：$e");
    }
  }
}
