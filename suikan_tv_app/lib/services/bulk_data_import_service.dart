import 'dart:async';

import 'package:simple_live_core/simple_live_core.dart';
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/models/db/follow_user.dart';
import 'package:simple_live_tv_app/models/db/history.dart';
import 'package:simple_live_tv_app/services/db_service.dart';

enum BulkDataScale {
  normal,
  medium,
  large,
  huge,
}

class BulkDataPolicy {
  final int count;
  final BulkDataScale scale;
  final int dbBatchSize;
  final int yieldEvery;

  const BulkDataPolicy({
    required this.count,
    required this.scale,
    required this.dbBatchSize,
    required this.yieldEvery,
  });

  bool get shouldYield => yieldEvery > 0;

  String get label {
    switch (scale) {
      case BulkDataScale.normal:
        return "normal";
      case BulkDataScale.medium:
        return "medium";
      case BulkDataScale.large:
        return "large";
      case BulkDataScale.huge:
        return "huge";
    }
  }
}

class BulkImportResult {
  final int total;
  final int imported;
  final int skipped;
  final BulkDataPolicy policy;

  /// 覆盖被"保护"拦截了：对端数据量明显少于本地，为防丢数据自动降级为合并。
  /// 调用方**必须**据此提示用户 —— 否则用户会以为覆盖成功了，
  /// 但打开一看本地数据还在，反而不知所措。
  final bool overwriteGuarded;

  const BulkImportResult({
    required this.total,
    required this.imported,
    required this.skipped,
    required this.policy,
    this.overwriteGuarded = false,
  });

  String get logSummary =>
      "total=$total imported=$imported skipped=$skipped scale=${policy.label}"
      "${overwriteGuarded ? ' [覆盖已拦截]' : ''}";
}

class BulkDataImportService {
  static const int mediumThreshold = 300;
  static const int largeThreshold = 1000;
  static const int hugeThreshold = 3000;

  static BulkDataPolicy policyForCount(int count) {
    if (count > hugeThreshold) {
      return BulkDataPolicy(
        count: count,
        scale: BulkDataScale.huge,
        dbBatchSize: 200,
        yieldEvery: 100,
      );
    }
    if (count > largeThreshold) {
      return BulkDataPolicy(
        count: count,
        scale: BulkDataScale.large,
        dbBatchSize: 400,
        yieldEvery: 200,
      );
    }
    if (count > mediumThreshold) {
      return BulkDataPolicy(
        count: count,
        scale: BulkDataScale.medium,
        dbBatchSize: 800,
        yieldEvery: 300,
      );
    }
    return BulkDataPolicy(
      count: count,
      scale: BulkDataScale.normal,
      dbBatchSize: 1200,
      yieldEvery: 0,
    );
  }

  static Future<void> yieldIfNeeded(
    BulkDataPolicy policy,
    int processed,
  ) async {
    if (!policy.shouldYield || processed <= 0) {
      return;
    }
    if (processed % policy.yieldEvery == 0) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  static Future<BulkImportResult> importFollowUsers(
    dynamic rawUsers, {
    bool overwrite = false,
    SyncProgressCallback? onProgress,
  }) async {
    if (rawUsers is! List) {
      final policy = policyForCount(0);
      return BulkImportResult(
        total: 0,
        imported: 0,
        skipped: 0,
        policy: policy,
      );
    }
    final policy = policyForCount(rawUsers.length);
    onProgress?.call(SyncProgress(
      stage: "导入关注",
      current: 0,
      total: rawUsers.length,
      message: "正在解析关注 0/${rawUsers.length}",
    ));
    final users = <FollowUser>[];
    var skipped = 0;
    var processed = 0;
    for (final item in rawUsers) {
      processed++;
      if (item is! Map) {
        skipped++;
        await yieldIfNeeded(policy, processed);
        continue;
      }
      try {
        final user = FollowUser.fromJson(Map<String, dynamic>.from(item));
        if (user.id.isEmpty || user.roomId.isEmpty || user.siteId.isEmpty) {
          skipped++;
        } else {
          users.add(user);
        }
      } catch (e) {
        skipped++;
        Log.d("跳过异常关注项: $e");
      }
      await yieldIfNeeded(policy, processed);
      _notifyProgress(
        onProgress,
        stage: "导入关注",
        current: processed,
        total: rawUsers.length,
        verb: "解析",
      );
    }
    // 覆盖模式改成「先写后删」，顺序绝不能反：
    // clear() 是 truncate(0)，一瞬间把箱清空；而后面几百条关注是**分批** putAll，
    // 每批之间还要 await 让出事件循环，整个写入要跑几百毫秒～几秒。这中间被杀
    // 进程 / 覆盖安装，箱就是空的 —— 三端互导配置包时极易撞上，正是
    // "覆盖安装后关注列表清空"的直接原因。先写后删即使被打断，旧数据也还在。
    // 包里是空数组时不删（对端数据已丢/未勾选该类），避免"清了没有回填"。
    await _putFollows(users, policy, onProgress: onProgress);
    // 🔴 覆盖保护（2026-08-31）：用"明显更少"的数据覆盖本地，等同丢数据。
    // 典型事故：某端因为覆盖安装丢了关注（变空或只剩几条），用户又拿这一端
    // 去覆盖别的端 —— 空数据就在各端之间来回传染，最后所有端都空了。
    //
    // 判据：对端有效条数的 3 倍还不到本地现有条数 → 宁可不覆盖。
    // 此时上面的写入**已经完成**，所以拦截 prune 的效果就是"合并"：
    // 对端的数据照样进来，本地原有的一条不少。代价只是留下冗余项。
    var guarded = false;
    if (overwrite && users.isNotEmpty) {
      final localCount = DBService.instance.followBox.length;
      if (localCount > 0 && users.length * 3 < localCount) {
        guarded = true;
        Log.logAlways("关注导入：对端 ${users.length} 条 < 本地 $localCount 条的 1/3，"
            "拦截覆盖、保留本地数据（等价于合并）");
      } else {
        await _pruneFollowsExcept(users);
      }
    }
    final result = BulkImportResult(
      total: rawUsers.length,
      imported: users.length,
      skipped: skipped,
      policy: policy,
      overwriteGuarded: guarded,
    );
    Log.i("批量导入关注完成：${result.logSummary}");
    // 🔴 强制落盘：Hive 写队列不 fsync，"导入完立刻关 App/被杀" → 半写帧损坏
    // → 下次启动判定损坏重建空箱 = "导入后有关注、重启后空"（2026-08-31）
    await DBService.instance.flushAll();
    return result;
  }

  static Future<BulkImportResult> importHistories(
    dynamic rawHistories, {
    bool overwrite = false,
    SyncProgressCallback? onProgress,
  }) async {
    if (rawHistories is! List) {
      final policy = policyForCount(0);
      return BulkImportResult(
        total: 0,
        imported: 0,
        skipped: 0,
        policy: policy,
      );
    }
    final policy = policyForCount(rawHistories.length);
    onProgress?.call(SyncProgress(
      stage: "导入历史",
      current: 0,
      total: rawHistories.length,
      message: "正在整理历史 0/${rawHistories.length}",
    ));
    // 覆盖模式的"清空"移到写入之后执行（理由同关注导入：先清后写一旦中途被
    // 杀就是空箱）。包里是空数组时也不删，避免"清了没有回填"。
    final existing = overwrite
        ? <String, History>{}
        : {
            for (final entry in DBService.instance.historyBox.toMap().entries)
              entry.key.toString(): entry.value,
          };
    final pending = <String, History>{};
    var skipped = 0;
    var imported = 0;
    var processed = 0;
    for (final item in rawHistories) {
      processed++;
      if (item is! Map) {
        skipped++;
        await yieldIfNeeded(policy, processed);
        continue;
      }
      try {
        final history = History.fromJson(Map<String, dynamic>.from(item));
        if (history.id.isEmpty ||
            history.roomId.isEmpty ||
            history.siteId.isEmpty) {
          skipped++;
          await yieldIfNeeded(policy, processed);
          continue;
        }
        final old = existing[history.id];
        if (!overwrite &&
            old != null &&
            old.updateTime.isAfter(history.updateTime)) {
          await yieldIfNeeded(policy, processed);
          continue;
        }
        existing[history.id] = history;
        pending[history.id] = history;
        imported++;
      } catch (e) {
        skipped++;
        Log.d("跳过异常历史项: $e");
      }
      await yieldIfNeeded(policy, processed);
      _notifyProgress(
        onProgress,
        stage: "导入历史",
        current: processed,
        total: rawHistories.length,
        verb: "整理",
      );
    }
    await _putHistories(pending.values, policy, onProgress: onProgress);
    if (overwrite && pending.isNotEmpty) {
      await _pruneHistoriesExcept(pending.keys.toSet());
    }
    final result = BulkImportResult(
      total: rawHistories.length,
      imported: imported,
      skipped: skipped,
      policy: policy,
    );
    Log.i("批量导入历史完成：${result.logSummary}");
    await DBService.instance.flushAll();
    return result;
  }

  static Future<BulkImportResult> importShieldValues(
    dynamic rawValues, {
    bool overwrite = false,
    SyncProgressCallback? onProgress,
  }) async {
    if (rawValues is! List) {
      final policy = policyForCount(0);
      return BulkImportResult(
        total: 0,
        imported: 0,
        skipped: 0,
        policy: policy,
      );
    }
    final policy = policyForCount(rawValues.length);
    onProgress?.call(SyncProgress(
      stage: "导入屏蔽词",
      current: 0,
      total: rawValues.length,
      message: "正在整理屏蔽词 0/${rawValues.length}",
    ));
    if (overwrite) {
      await AppSettingsController.instance.clearShieldList();
    }
    final values = <String>{};
    var skipped = 0;
    var processed = 0;
    for (final item in rawValues) {
      processed++;
      final value = item.toString().trim();
      if (value.isEmpty) {
        skipped++;
      } else {
        values.add(value);
      }
      await yieldIfNeeded(policy, processed);
      _notifyProgress(
        onProgress,
        stage: "导入屏蔽词",
        current: processed,
        total: rawValues.length,
        verb: "整理",
      );
    }
    for (final value in values) {
      AppSettingsController.instance.importShieldValue(value);
    }
    _notifyProgress(
      onProgress,
      stage: "写入屏蔽词",
      current: values.length,
      total: values.length,
      verb: "写入",
      force: true,
    );
    final result = BulkImportResult(
      total: rawValues.length,
      imported: values.length,
      skipped: skipped,
      policy: policy,
    );
    Log.i("批量导入屏蔽词完成：${result.logSummary}");
    await DBService.instance.flushAll();
    return result;
  }

  /// 删除"本次导入包里没有"的旧关注项，完成覆盖语义。
  /// **必须在 putAll 之后调用**：反过来的 clear→write 一旦在写入中途被杀就是空箱。
  static Future<void> _pruneFollowsExcept(Iterable<FollowUser> users) async {
    final keep = <String>{for (final u in users) DBService.safeBoxKey(u.id)};
    await DBService.runExclusive(() async {
      final stale = DBService.instance.followBox.keys
          .where((k) => !keep.contains(k.toString()))
          .toList();
      if (stale.isNotEmpty) {
        await DBService.instance.followBox.deleteAll(stale);
      }
    });
  }

  static Future<void> _putFollows(
    Iterable<FollowUser> users,
    BulkDataPolicy policy, {
    SyncProgressCallback? onProgress,
  }) async {
    final buffer = <String, FollowUser>{};
    final total = users.length;
    var written = 0;
    for (final user in users) {
      buffer[DBService.safeBoxKey(user.id)] = user;
      if (buffer.length >= policy.dbBatchSize) {
        await DBService.runExclusive(() => DBService.instance.followBox.putAll(buffer));
        written += buffer.length;
        buffer.clear();
        _notifyProgress(
          onProgress,
          stage: "写入关注",
          current: written,
          total: total,
          verb: "写入",
          force: true,
        );
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (buffer.isNotEmpty) {
      await DBService.runExclusive(() => DBService.instance.followBox.putAll(buffer));
      written += buffer.length;
      _notifyProgress(
        onProgress,
        stage: "写入关注",
        current: written,
        total: total,
        verb: "写入",
        force: true,
      );
    }
  }

  /// 删除"本次导入包里没有"的旧历史，完成覆盖语义（必须在写入之后调用）。
  static Future<void> _pruneHistoriesExcept(Set<String> keep) async {
    final safeKeep = <String>{for (final k in keep) DBService.safeBoxKey(k)};
    await DBService.runExclusive(() async {
      final stale = DBService.instance.historyBox.keys
          .where((k) => !safeKeep.contains(k.toString()))
          .toList();
      if (stale.isNotEmpty) {
        await DBService.instance.historyBox.deleteAll(stale);
      }
    });
  }

  static Future<void> _putHistories(
    Iterable<History> histories,
    BulkDataPolicy policy, {
    SyncProgressCallback? onProgress,
  }) async {
    final buffer = <String, History>{};
    final total = histories.length;
    var written = 0;
    for (final history in histories) {
      buffer[DBService.safeBoxKey(history.id)] = history;
      if (buffer.length >= policy.dbBatchSize) {
        await DBService.runExclusive(() => DBService.instance.historyBox.putAll(buffer));
        written += buffer.length;
        buffer.clear();
        _notifyProgress(
          onProgress,
          stage: "写入历史",
          current: written,
          total: total,
          verb: "写入",
          force: true,
        );
        await Future<void>.delayed(Duration.zero);
      }
    }
    if (buffer.isNotEmpty) {
      await DBService.runExclusive(() => DBService.instance.historyBox.putAll(buffer));
      written += buffer.length;
      _notifyProgress(
        onProgress,
        stage: "写入历史",
        current: written,
        total: total,
        verb: "写入",
        force: true,
      );
    }
    // 备份导入/P2P 同步可能一次灌入上万条历史，导入完统一裁剪到上限，
    // 免得别端的海量历史把本端箱撑爆（拖慢启动 + 快照体积暴涨）。
    await DBService.runExclusive(
      () => DBService.instance.trimHistoryOverflow(),
    );
  }

  static void _notifyProgress(
    SyncProgressCallback? onProgress, {
    required String stage,
    required int current,
    required int total,
    required String verb,
    bool force = false,
  }) {
    if (onProgress == null || total <= 0) {
      return;
    }
    if (!force && current < total && current % 100 != 0) {
      return;
    }
    onProgress(SyncProgress(
      stage: stage,
      current: current,
      total: total,
      message: "$verb $current/$total",
    ));
  }
}
