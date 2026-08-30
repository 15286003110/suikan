// 验证空箱自救的「时间预算」是否真能防止启动被拖死。
//
// 事故背景（2026-08-31 启动白屏）：
// 主箱为空时会遍历 suikan_box_backup 下**全部**备份，每份都要 Hive.openBox；
// 而损坏的箱 openBox 是**挂起不抛异常**的，只能靠超时兜底。
// 修复前每份固定 10s、无份数上限 —— 7 份就是 70s，两个箱 140s，界面一片空白。
//
// 这里用 Future.delayed(10 分钟) 模拟"openBox 挂起"，测修复前后的实际耗时。
//
// 运行：
//   D:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe run tool/verify_rescue_budget.dart

import 'dart:async';

/// 修复后的逻辑（与 db_service._restoreIntoEmptyBox 一致）：
/// 所有备份共享一个时间池，单次超时取**剩余预算**，另有份数上限。
Future<int> rescueWithBudget({
  required int backupCount,
  required Duration budget,
  required int maxTries,
}) async {
  final deadline = DateTime.now().add(budget);
  var tried = 0;
  for (var i = 0; i < backupCount; i++) {
    if (tried >= maxTries) break; // 份数闸门
    if (DateTime.now().isAfter(deadline)) break; // 时间闸门
    tried++;
    var remain = deadline.difference(DateTime.now());
    if (remain <= Duration.zero) break;
    try {
      // 模拟 Hive.openBox 撞上损坏帧后永久挂起
      await Future.delayed(const Duration(minutes: 10)).timeout(remain);
    } catch (_) {
      // 超时，丢弃这份，继续下一份（直到预算耗尽）
    }
  }
  return tried;
}

/// 修复前的逻辑：每份独立 10s，既无总预算也无份数上限。
Future<int> rescueLegacy(int backupCount) async {
  var tried = 0;
  for (var i = 0; i < backupCount; i++) {
    tried++;
    try {
      await Future.delayed(const Duration(minutes: 10))
          .timeout(const Duration(seconds: 10));
    } catch (_) {}
  }
  return tried;
}

Future<void> main() async {
  const backupCount = 7;
  print('场景：主箱为空，suikan_box_backup 下有 $backupCount 份**全部损坏**的备份');
  print('每份 openBox 都会挂起（模拟 Hive 撞上损坏帧死等，不抛异常）\n');

  print('--- 修复后：8s 共享预算 + 最多 3 份 ---');
  final sw1 = Stopwatch()..start();
  final tried1 = await rescueWithBudget(
    backupCount: backupCount,
    budget: const Duration(seconds: 8),
    maxTries: 3,
  );
  sw1.stop();
  print('实际尝试: $tried1 份（上限 3，剩余 ${backupCount - tried1} 份直接跳过）');
  print('耗时: ${sw1.elapsedMilliseconds} ms');

  print('\n--- 修复前：每份独立 10s，无上限 ---');
  final sw2 = Stopwatch()..start();
  await rescueLegacy(1); // 只跑 1 份即可外推，否则要等 70 秒
  sw2.stop();
  print('单份耗时: ${sw2.elapsedMilliseconds} ms');
  print('→ $backupCount 份 = ${(sw2.elapsedMilliseconds * backupCount / 1000).toStringAsFixed(0)} 秒');
  print('→ 若 FollowUser + History 两个箱都为空 = '
      '${(sw2.elapsedMilliseconds * backupCount * 2 / 1000).toStringAsFixed(0)} 秒白屏');

  print('\n=== 结论 ===');
  final ok = sw1.elapsedMilliseconds < 10000;
  print(ok
      ? '[通过] 修复后 ${sw1.elapsedMilliseconds}ms < 10s，启动不会被自救拖死'
      : '[失败] 修复后仍是 ${sw1.elapsedMilliseconds}ms，需要继续收紧');
  print('[对照] 修复前同样场景要 ~${(sw2.elapsedMilliseconds * backupCount * 2 / 1000).toStringAsFixed(0)} 秒');
}
