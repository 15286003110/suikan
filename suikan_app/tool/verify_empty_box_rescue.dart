// 验证「空箱自救」机制在真实 Hive 环境下能否捞回数据。
//
// 背景：旧版本走的是「备份移除 + 重建空箱」，数据其实还在
// suikan_box_backup/<name>_<时间戳>/ 里，但 App 已经改用新空箱了，
// 用户看到的就是「覆盖安装后关注列表空了」。
// db_service.dart 的 _restoreIntoEmptyBox 就是为这批老用户准备的补救通道。
//
// 本脚本复刻该逻辑，在真实 Hive 上跑一遍，并额外验证一个已发现的陷阱：
// **Hive 的箱缓存按 name 索引，isBoxOpen(name) 为真时会直接返回主箱自己**，
// 所以"直接从备份目录打开同名箱"是无效的，必须先复制成临时名。
//
// 运行：
//   D:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/verify_empty_box_rescue.dart

import 'dart:io';

import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;

/// 正确实现（与 db_service._restoreIntoEmptyBox 一致）：
/// 复制成临时文件名再打开，避开同名箱陷阱。
Future<int> restoreIntoEmptyBox<T>(Box<T> box, String name, String dir) async {
  final root = Directory(p.join(dir, 'suikan_box_backup'));
  if (!await root.exists()) return 0;
  final dirs = await root.list().toList();
  final mine = dirs
      .whereType<Directory>()
      .where((d) => p.basename(d.path).startsWith('${name}_'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));

  final tmpRoot = Directory(p.join(dir, 'suikan_box_snapshot', '_restore_tmp'));
  await tmpRoot.create(recursive: true);
  final tmpName = '${name}_restore_tmp';

  for (final d in mine) {
    final srcFile = File(p.join(d.path, '$name.hive'));
    if (!await srcFile.exists()) continue;

    final tmpFile = File(p.join(tmpRoot.path, '$tmpName.hive'));
    if (await tmpFile.exists()) await tmpFile.delete();
    await srcFile.copy(tmpFile.path);
    final tmpLock = File(p.join(tmpRoot.path, '$tmpName.lock'));
    if (await tmpLock.exists()) await tmpLock.delete();

    Box<T>? src;
    Map<dynamic, T> data = <dynamic, T>{};
    try {
      src = await Hive.openBox<T>(tmpName, path: tmpRoot.path);
      data = src.toMap();
    } catch (e) {
      print('   备份打不开: $e');
    }
    if (src != null) await src.close();
    if (await tmpFile.exists()) await tmpFile.delete();

    if (data.isEmpty) continue;
    await box.putAll(data);
    print('   已从备份 ${p.basename(d.path)} 捞回 ${data.length} 条');
    return data.length;
  }
  return 0;
}

/// 对照组（错误做法）：直接用备份箱的原 name 从备份目录打开。
/// 预期：拿到的其实是**主箱自己**，读出来是空的 —— 证明这个陷阱真实存在。
Future<int> wrongRestoreSameName<T>(
    Box<T> box, String name, String dir) async {
  final root = Directory(p.join(dir, 'suikan_box_backup'));
  if (!await root.exists()) return 0;
  final dirs = await root.list().toList();
  final mine = dirs
      .whereType<Directory>()
      .where((d) => p.basename(d.path).startsWith('${name}_'))
      .toList()
    ..sort((a, b) => b.path.compareTo(a.path));

  for (final d in mine) {
    final srcFile = File(p.join(d.path, '$name.hive'));
    if (!await srcFile.exists()) continue;
    final src = await Hive.openBox<T>(name, path: d.path);
    final isSelf = identical(src, box);
    print('   打开"备份箱"：条目=${src.length}，返回的是主箱自己=$isSelf');
    final n = src.length;
    // ⚠️ 千万别关：它很可能就是主箱自己。一旦关掉，App 后续所有读写全崩
    // （本次测试就是这么炸出 HiveError: Box has already been closed 的，
    //  这恰好证明同名录回是**破坏性**的，不只是无效）。
    if (!isSelf) await src.close();
    return n;
  }
  return 0;
}

Future<void> main() async {
  final tmp = Directory.systemTemp.createTempSync('suikan_rescue_test');
  final hiveDir = Directory(p.join(tmp.path, 'hive'));
  await hiveDir.create(recursive: true);
  Hive.init(hiveDir.path);
  print('测试目录: ${hiveDir.path}\n');

  const boxName = 'FollowUser';

  // ① 主箱写入数据
  var box = await Hive.openBox<String>(boxName);
  await box.putAll({'u1': '主播A', 'u2': '主播B', 'u3': '主播C'});
  print('① 主箱写入 ${box.length} 条 -> ${box.toMap()}');
  await box.close();

  // ② 模拟旧版本的「备份移除 + 重建空箱」
  final backupDir =
      Directory(p.join(hiveDir.path, 'suikan_box_backup', '${boxName}_20260831000000'));
  await backupDir.create(recursive: true);
  final mainFile = File(p.join(hiveDir.path, '$boxName.hive'));
  await mainFile.copy(p.join(backupDir.path, '$boxName.hive'));
  await mainFile.delete();
  final lockFile = File(p.join(hiveDir.path, '$boxName.lock'));
  if (await lockFile.exists()) await lockFile.delete();
  print('② 模拟旧版行为：数据已挪进 ${p.basename(backupDir.path)}，主箱被删重建\n');

  // ③ 打开主箱（空）
  box = await Hive.openBox<String>(boxName);
  print('③ 重新打开主箱 -> 条目=${box.length}（预期 0，这就是用户看到"关注列表空了"的时刻）');
  if (box.length != 0) {
    print('   !! 前提不成立，测试无效');
    await Hive.close();
    tmp.deleteSync(recursive: true);
    return;
  }

  // ④ 先用错误做法对照，证明陷阱存在
  print('\n④ 对照组：直接用备份箱同名打开（错误做法）');
  final wrongGot = await wrongRestoreSameName<String>(box, boxName, hiveDir.path);
  print('   结果：拿到 $wrongGot 条 -> ${wrongGot == 0 ? "如预期的 0 条，陷阱成立" : "意外"}');

  // ⑤ 正确实现
  print('\n⑤ 正确实现：复制成临时名再打开');
  final got = await restoreIntoEmptyBox<String>(box, boxName, hiveDir.path);
  final data = box.toMap();
  print('   结果：主箱现有 ${box.length} 条 -> $data');

  // ⑥ 断言
  final ok = box.length == 3 && data['u1'] == '主播A' && data['u3'] == '主播C';
  print('\n${ok ? ">>> [通过]" : ">>> [失败]"} 空箱自救${ok ? "成功捞回全部数据" : "未能捞回数据"}');

  // ⑦ 额外验证：备份文件在自救后仍然保留（约束 3）
  final stillThere = await File(p.join(backupDir.path, '$boxName.hive')).exists();
  print('${stillThere ? ">>> [通过]" : ">>> [失败]"} 备份原件${stillThere ? "仍在磁盘（可二次抢救）" : "被误删了"}');

  await Hive.close();
  tmp.deleteSync(recursive: true);
  print('\n（测试目录已清理）');
}
