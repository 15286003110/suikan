import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_tv_app/app/log.dart';

/// 诊断包导出：把 Hive 箱文件、历史备份、健康快照复制到**外部缓存目录**，
/// 便于用 `adb pull /sdcard/Android/data/com.suikan.tvbox/cache/...` 取出分析。
///
/// 为什么用 getExternalCacheDirectories()：
/// - 它是 App 专属外部目录（/sdcard/Android/data/<pkg>/cache），**不需要任何存储权限**
///   （Android 4.4+），TV 上不会出现无法用遥控器操作的权限弹窗；
/// - adb shell 属于 sdcard_rw 组，可以直接 pull 这些文件；
/// - 而 getExternalStorageDirectory() 指向 /sdcard 顶层时，Android 6 需要 WRITE_EXTERNAL_STORAGE
///   动态授权，盒子上弹窗往往没法操作，导出会静默失败。
class DiagnoseExportService {
  /// 导出诊断包，返回目标目录路径；失败返回 null。
  static Future<String?> export({required String? hiveDir}) async {
    if (hiveDir == null || hiveDir.isEmpty) return null;
    try {
      final cacheDirs = await getExternalCacheDirectories();
      if (cacheDirs == null || cacheDirs.isEmpty) return null;
      final stamp = DateTime.now()
          .toIso8601String()
          .replaceAll(RegExp(r'[^0-9]'), '')
          .substring(0, 14);
      final target = Directory(
        p.join(cacheDirs.first.path, 'suikan_diagnose_$stamp'),
      );
      await target.create(recursive: true);

      // 1) 当前正在使用的箱文件
      final srcDir = Directory(hiveDir);
      if (await srcDir.exists()) {
        await for (final entity in srcDir.list(followLinks: false)) {
          if (entity is File) {
            final name = p.basename(entity.path);
            if (name.endsWith('.hive') || name.endsWith('.lock')) {
              await _copyTo(entity, target, name);
            }
          }
        }
      }
      // 2) 被判定损坏后移走的备份（数据抢救的唯一来源）
      await _copyDir(
        Directory(p.join(hiveDir, 'suikan_box_backup')),
        Directory(p.join(target.path, 'suikan_box_backup')),
      );
      // 3) 健康快照
      await _copyDir(
        Directory(p.join(hiveDir, 'suikan_box_snapshot')),
        Directory(p.join(target.path, 'suikan_box_snapshot')),
      );
      Log.logAlways('诊断包已导出: ${target.path}');
      return target.path;
    } catch (e) {
      Log.logAlways('诊断包导出失败: $e');
      return null;
    }
  }

  static Future<void> _copyTo(File src, Directory target, String name) async {
    try {
      await src.copy(p.join(target.path, name));
    } catch (_) {}
  }

  static Future<void> _copyDir(Directory src, Directory dst) async {
    try {
      if (!await src.exists()) return;
      await dst.create(recursive: true);
      await for (final entity in src.list(recursive: true, followLinks: false)) {
        if (entity is File) {
          final rel = p.relative(entity.path, from: src.path);
          final out = File(p.join(dst.path, rel));
          await out.parent.create(recursive: true);
          try {
            await entity.copy(out.path);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }
}
