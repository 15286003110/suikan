// 复刻 player_controller.dart 的跨链路重连节流逻辑，验证数值序列。
// 之所以是复刻而不是 import：PlayerController 依赖 Flutter，无法在纯 Dart 下跑。
// 这里验证的是「状态机设计是否正确」；接线是否正确靠 diff 人工核对。
void main() {
  const cooldown = Duration(seconds: 3);
  const resetAfter = Duration(seconds: 60);
  const ceilingStep = 3;

  DateTime? lastHeavyReconnectAt;
  int streak = 0;
  var now = DateTime(2026, 1, 1, 0, 0, 0);

  bool isCoolingDown(DateTime t) {
    final last = lastHeavyReconnectAt;
    return last != null && t.difference(last) < cooldown;
  }

  void note(DateTime t) {
    lastHeavyReconnectAt = t;
    streak += 1;
  }

  Duration backoff() {
    final step = streak.clamp(0, ceilingStep);
    return Duration(seconds: 1 << step);
  }

  void maybeReset(DateTime t) {
    if (streak == 0) return;
    final last = lastHeavyReconnectAt;
    if (last == null || t.difference(last) >= resetAfter) {
      streak = 0;
      lastHeavyReconnectAt = null;
    }
  }

  void resetAll() {
    lastHeavyReconnectAt = null;
    streak = 0;
  }

  final failures = <String>[];
  void check(bool ok, String msg) {
    if (!ok) failures.add(msg);
  }

  // ---------- 场景 1：A 链路连续流错误，看退避序列 ----------
  print('=== 场景 1：连续流错误的退避序列（A 链路）===');
  resetAll();
  now = DateTime(2026, 1, 1);
  final waits = <int>[];
  // A 链路上限 3 次，之后转 mediaError
  for (var i = 1; i <= 3; i++) {
    final w = backoff();
    note(now);
    waits.add(w.inSeconds);
    now = now.add(w);
    // 重连后立刻又失败
  }
  print('三次重试等待：${waits.map((s) => '${s}s').join(' → ')}');
  check(waits.length == 3, '场景1: 应重试 3 次');
  check(waits[0] == 1, '场景1: 第 1 次必须是 1 秒（瞬时抖动不能变慢），实际 ${waits[0]}s');
  check(waits[1] == 2, '场景1: 第 2 次应为 2 秒，实际 ${waits[1]}s');
  check(waits[2] == 4, '场景1: 第 3 次应为 4 秒，实际 ${waits[2]}s');
  final totalA = waits.reduce((a, b) => a + b);
  print('三次累计等待 ${totalA}s（改动前固定 1s×3 = 3s，且网络没有恢复窗口）');

  // ---------- 场景 2：退避封顶，不会无限增长 ----------
  print('\n=== 场景 2：连续失败超过 4 次时的封顶 ===');
  resetAll();
  now = DateTime(2026, 1, 1);
  final longRun = <int>[];
  for (var i = 1; i <= 8; i++) {
    final w = backoff();
    note(now);
    longRun.add(w.inSeconds);
    now = now.add(w);
  }
  print('连续 8 次：${longRun.map((s) => '${s}s').join(' ')}');
  check(longRun.last == 8, '场景2: 应封顶在 8 秒，实际 ${longRun.last}s');
  check(longRun.every((s) => s <= 8), '场景2: 任何一次都不得超过 8 秒');

  // ---------- 场景 3：稳定播放 60s 后归零 ----------
  print('\n=== 场景 3：稳定播放后连续计数归零 ===');
  resetAll();
  now = DateTime(2026, 1, 1);
  note(now); // 一次重连
  note(now.add(const Duration(seconds: 1))); // 又一次
  check(streak == 2, '场景3: 连续两次后 streak 应为 2，实际 $streak');
  // 播放有进展，且距上次重连不到 60s -> 不复位
  maybeReset(now.add(const Duration(seconds: 30)));
  check(streak == 2, '场景3: 30s 时不应复位，实际 streak=$streak');
  // 距上次重连 >= 60s -> 复位
  maybeReset(now.add(const Duration(seconds: 61)));
  check(streak == 0, '场景3: 61s 后应复位为 0，实际 streak=$streak');
  final afterReset = backoff();
  check(afterReset.inSeconds == 1,
      '场景3: 复位后第一次重试应回到 1 秒，实际 ${afterReset.inSeconds}s');

  // ---------- 场景 4：B/C 链路冷却，且不消耗重试次数 ----------
  print('\n=== 场景 4：跨链路冷却（B/C 链路跳过不消耗次数）===');
  resetAll();
  now = DateTime(2026, 1, 1);
  // 模拟：A 链路在 t=0 重连
  final awaited = backoff();
  note(now);
  now = now.add(awaited); // A 重连完成时刻
  print('A 链路在 t=${now.difference(DateTime(2026, 1, 1)).inSeconds}s 完成重连');

  // B 链路（3 秒轮询）在 A 重连后 1 秒被触发 -> 应被冷却挡住
  var bAttempts = 0;
  const bMax = 3;
  var t = now.add(const Duration(seconds: 1));
  var blocked = 0;
  for (var i = 0; i < 6; i++) {
    if (isCoolingDown(t)) {
      blocked++;
    } else if (bAttempts < bMax) {
      bAttempts++;
      note(t);
    }
    t = t.add(const Duration(seconds: 3)); // 下一个采样周期
  }
  print('B 链路：被冷却挡住 $blocked 次，实际执行 $bAttempts 次（上限 $bMax）');
  check(blocked > 0, '场景4: 冷却应该至少挡住一次，否则没生效');
  check(bAttempts == bMax,
      '场景4: 冷却只应推迟、不应吃掉重试次数，最终仍应执行满 $bMax 次，实际 $bAttempts');

  // ---------- 场景 5：冷却窗口边界 ----------
  print('\n=== 场景 5：冷却窗口边界（3 秒）===');
  resetAll();
  final base = DateTime(2026, 1, 1);
  note(base);
  check(isCoolingDown(base.add(const Duration(milliseconds: 2999))) == true,
      '场景5: 2.999s 时应在冷却中');
  check(isCoolingDown(base.add(const Duration(seconds: 3))) == false,
      '场景5: 恰好 3s 时冷却应结束');

  // ---------- 汇总 ----------
  print('\n========================================');
  if (failures.isEmpty) {
    print('全部通过');
  } else {
    print('失败 ${failures.length} 项：');
    for (final f in failures) {
      print('  - $f');
    }
  }
}
