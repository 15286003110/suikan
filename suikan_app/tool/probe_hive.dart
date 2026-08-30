// 诊断工具：直接把一个 .hive 文件交给 Hive 打开，看能否读出数据。
// 用于定位"重启后关注为空"：如果文件可打开且有数据，问题在 App 打开逻辑；
// 如果打开失败/条目为 0，问题在文件本身。
//
// 用法（在 suikan_app 目录编译，脱离 dart run 的 build hooks）：
//   dart compile exe tool/probe_hive.dart -o /tmp/probe_hive.exe
//   /tmp/probe_hive.exe <hive文件路径> [box名]
import 'dart:async';
import 'dart:io';

import 'package:hive/hive.dart';

Future<void> main(List<String> args) async {
  if (args.length < 2) {
    print('用法: probe_hive <hive文件路径> <box名>');
    exit(1);
  }
  final srcPath = args[0];
  final boxName = args[1];
  final src = File(srcPath);
  if (!await src.exists()) {
    print('!! 文件不存在: $srcPath');
    exit(1);
  }
  final size = await src.length();
  print('待检文件: $srcPath ($size 字节)');

  // 复制到临时目录，避免动原文件
  final tmp = Directory.systemTemp.createTempSync('hive_probe');
  final copy = File('${tmp.path}/$boxName.hive');
  await src.copy(copy.path);
  final copySize = await copy.length();
  print('副本: ${copy.path} ($copySize 字节)');
  Hive.init(tmp.path);

  try {
    final future = Hive.openBox<dynamic>(boxName);
    final box = await future.timeout(const Duration(seconds: 15));
    print('>>> 打开成功: 条目=${box.length}');
    final keys = box.keys.take(5).toList();
    for (final k in keys) {
      print('  key=$k');
    }
    await box.close();
  } on TimeoutException {
    print('>>> 打开【超时】—— 文件损坏（Hive 挂起不抛异常）');
  } catch (e) {
    print('>>> 打开抛异常: $e');
  }

  await Hive.close();
  print('诊断完成');
}
