import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/models/db/follow_user.dart';
import 'package:simple_live_app/models/db/follow_user_tag.dart';
import 'package:simple_live_app/models/db/history.dart';
import 'package:uuid/uuid.dart';
import 'package:collection/collection.dart';

class DBService extends GetxService {
  static DBService get instance => Get.find<DBService>();
  late Box<History> historyBox;
  late Box<FollowUser> followBox;
  late Box<FollowUserTag> tagBox;
  late Box<String> customSourceBox;
  late Box<String> fnOsBox;
  final Uuid uuid = const Uuid();

  /// Hive 2.x 的 box.put/delete 并发写同一文件会产生交错 frame 导致文件损坏
  /// （无内部写锁）—— 典型场景：后台自动刷新直播源与用户手动添加/删除源、
  /// 或导入配置包同时发生时。所有箱写操作必须经此队列串行执行。
  static Future<void> _writeChain = Future.value();

  static Future<T> runExclusive<T>(Future<T> Function() action) {
    final result = _writeChain.then((_) => action());
    // 链上吞掉错误，避免单次失败阻断后续写。
    _writeChain = result.then((_) {}, onError: (_) {});
    return result;
  }

  Future init({String? hivePath}) async {
    // ⚠️ 关键：Android/iOS 端 main 传入的 hivePath 是 **null**（只有桌面端返回真实目录），
    // 而 Hive 实际把箱文件写在 getApplicationDocumentsDirectory()（hive_flutter 行为）。
    // 过去直接把 null 存进 _hiveDir，导致删除/快照/备份/兜底**全部空转**：
    // 打印"已删除重建"但一个字节都没动 → 重开仍读到坏数据；
    // 快照永远建不起来 → 覆盖安装必清空关注/历史（2026-08-30 事故真因）。
    _hiveDir = await _resolveHiveDir(hivePath);
    Log.logAlways('Hive 数据目录=$_hiveDir');
    // ⚠️ 五个箱互相独立（不同文件、不同锁），必须**并行**打开。
    // 串行 await 时最坏情况是 5 × 15s 超时 = 75s；并行后总耗时 = 最慢的那一个 ≤ 15s。
    // 正常路径下也能把 5 次"读文件 + 解析帧"压成一轮，启动肉眼可见变快。
    // 写法上先全部发起、再统一等待：Future 已完成时 await 立即返回，
    // 类型安全，不需要 as 强转。
    final fHistory = _openBoxResilient<History>("History");
    final fFollow = _openBoxResilient<FollowUser>("FollowUser");
    final fTag = _openBoxResilient<FollowUserTag>("FollowUserTag");
    final fCustom = _openBoxResilient<String>("CustomSource");
    final fFnOs = _openBoxResilient<String>("FnOsServer");
    await Future.wait([fHistory, fFollow, fTag, fCustom, fFnOs]);
    historyBox = await fHistory;
    followBox = await fFollow;
    tagBox = await fTag;
    customSourceBox = await fCustom;
    fnOsBox = await fFnOs;
    // 异步压缩各箱（删除操作留下的空洞会随使用膨胀，压缩可保持读写速度）；
    // 不阻塞启动，失败静默。
    unawaited(_compactAllBoxes());
  }

  Future<void> _compactAllBoxes() async {
    await Future<void>.delayed(const Duration(seconds: 5));
    for (final box in <Box>[historyBox, followBox, tagBox, customSourceBox, fnOsBox]) {
      try {
        await box.compact();
      } catch (_) {
        // 单个箱压缩失败不影响其余
      }
    }
  }

  /// 强制所有箱落盘（Hive 写队列 flush）。
  ///
  /// 必须在**批量导入 / 配置包导入 / 同步接收**完成后调用：
  /// Hive 的 putAll/deleteAll 返回时数据还在写队列里，并未 fsync。
  /// 用户"导入完看一眼 → 马上关 App / 覆盖安装 / 进程被杀"，写队列没来得及
  /// 落盘 → 文件留下**半写帧** → 下次启动 openBox 帧解析失败 → 判定损坏 →
  /// 重建空箱 → "导入后有关注、重启后空了"（2026-08-31 实测 39KB 损坏帧）。
  Future<void> flushAll() async {
    for (final box in <Box?>[
      historyBox,
      followBox,
      tagBox,
      customSourceBox,
      fnOsBox,
    ]) {
      try {
        await box?.flush();
      } catch (_) {
        // 单个箱 flush 失败不影响其余
      }
    }
  }

  /// Hive 数据目录。绝不能为 null（为 null 时所有备份/回滚/兜底逻辑都会空转）。
  String? _hiveDir;

  /// 真实数据目录（诊断包导出/日志排查用）。
  String? get hiveDir => _hiveDir;

  /// 解析 Hive 箱文件的真实目录。
  /// - [hint] 非空（桌面端）：直接用它；
  /// - [hint] 为空（Android/iOS）：Hive 实际写在 getApplicationDocumentsDirectory()
  ///   （见 hive_flutter 的 initFlutter 实现），必须自己算出来，不能用 null。
  /// - 最后做存在性校验：优先选"真的存在箱文件"的目录，避免算错路径后
  ///   去清理一个空目录、而坏文件还留在原地。
  Future<String> _resolveHiveDir(String? hint) async {
    final candidates = <String>[];
    if (hint != null && hint.isNotEmpty) {
      candidates.add(hint);
    }
    final dirs = <String>[];
    try {
      dirs.add((await getApplicationDocumentsDirectory()).path);
    } catch (_) {}
    try {
      dirs.add((await getApplicationSupportDirectory()).path);
    } catch (_) {}
    for (final d in dirs) {
      if (!candidates.contains(d)) candidates.add(d);
    }
    for (final c in candidates) {
      try {
        if (await File(p.join(c, 'FollowUser.hive')).exists() ||
            await File(p.join(c, 'History.hive')).exists() ||
            await File(p.join(c, 'CustomSource.hive')).exists()) {
          return c;
        }
      } catch (_) {}
    }
    // 都没有箱文件（全新安装）：用第一个可用候选，确保目录存在可写
    for (final c in candidates) {
      try {
        final d = Directory(c);
        if (await d.exists()) return c;
        await d.create(recursive: true);
        return c;
      } catch (_) {}
    }
    return Directory.systemTemp.path;
  }

  /// 备用箱目录：放在**数据目录**内（系统临时目录会被系统清理，放那里等于数据随时消失）。
  String _fallbackBoxDir() {
    final dir = _hiveDir;
    if (dir != null && dir.isNotEmpty) {
      return p.join(dir, 'suikan_box_fallback');
    }
    return p.join(Directory.systemTemp.path, 'suikan_box_fallback');
  }

  /// 打开 Hive 箱（带超时、自救与兜底），保证损坏/被占用的箱文件不会让 App 启动卡死。
  ///
  /// 核心原则：**超时 ≠ 损坏**。
  /// - 覆盖安装时旧进程可能还握着 `.lock`（Hive 的进程间锁用文件锁实现），
  ///   新进程的 openBox 会阻塞在 `lockRaf.lock()` 上。等锁释放后原文件是完好的。
  ///   此时若按"损坏"去备份移除 + 重建，表现就是**每次覆盖安装都清空关注列表**
  ///   （2026-08-31 三端事故的真正原因）。
  /// - 只有 openBox 真的抛异常（unknown typeId / checksum / adapter 不匹配）才算损坏。
  /// - 仅仅是超时 → **原文件一个字节都不动**，降级到备用箱；下次启动锁释放后
  ///   自动读回来。数据不会真的丢，最坏是这一次打开暂时看不到。
  ///
  /// 注意：不要在此处做「自行解析帧结构」的预检。Hive 2.x 的箱头/帧格式与手工假设
  /// 不同，自行预检会把**正常箱 100% 误判为损坏**并删除 → 用户数据全丢（2026-08-29
  /// 事故）。判断损坏的唯一可靠方式就是交给 Hive.openBox 自己读。
  Future<Box<T>> _openBoxResilient<T>(String name) async {
    // 上次是否降级过：降级过就用更短的超时快速试探主箱有没有修好，
    // 免得每次启动都干等 30 秒；一旦主箱能打开就立刻切回真实数据。
    final degradedBefore = await _wasDegraded(name);
    final probe = degradedBefore
        ? const Duration(seconds: 8)
        : const Duration(seconds: 15);
    final attempts = degradedBefore ? 1 : 2;
    var corrupted = false;

    for (var attempt = 0; attempt < attempts; attempt++) {
      final future = Hive.openBox<T>(name);
      // 超时后原始 future 仍可能在后台完成并抛错 → 消费其错误，避免 Unhandled Exception。
      unawaited(future.then((_) {}, onError: (Object _) {}));
      try {
        final box = await future.timeout(probe);
        Log.logAlways("[$name] 打开成功 条目=${box.length} 文件=${box.path}");
        // 空箱自救：旧版本走的是「备份移除 + 重建空箱」，数据其实还躺在
        // suikan_box_backup/ 里，但 App 已经改用新空箱了 —— 用户看到的就是
        // 「覆盖安装后关注列表空了」。这里在启动阶段把备份数据搬回来，
        // 让老用户装一次新版就能把数据找回来。主箱非空时完全不动作。
        if (box.isEmpty) {
          // ⚠️ 自救失败**绝不能**被当成"箱损坏"：外层 catch 一旦把它判成
          // corrupted，就会走"备份移除 + 重建"——每启动一次就往
          // suikan_box_backup/ 多丢一份备份，备份越积越多，下次自救要扫的
          // 目录也越多，启动越来越慢，最终卡成白屏（2026-08-31 事故：
          // 该目录下 7 份 FollowUser + 7 份 History，每份损坏各等 10s 超时）。
          // 主箱本身是好的，自救只是锦上添花，失败静默跳过即可。
          try {
            await _restoreIntoEmptyBox<T>(box, name);
          } catch (_) {
            // 自救失败不影响主箱可用性
          }
        }
        unawaited(_saveSnapshotLater(name));
        await _clearDegraded(name);
        return box;
      } on TimeoutException {
        Log.logAlways(
            "打开[$name]箱超时（第${attempt + 1}次）—— 超时≠损坏，不删箱");
      } catch (e) {
        corrupted = true;
        Log.logAlways("打开[$name]箱异常($e)—— 判定为真正损坏");
        break; // 真损坏，重试也没用
      }
      if (attempt < attempts - 1) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }

    // ① 仅当判定为真正损坏，才走三级自救：快照 → 历史备份 → 备份移除重建。
    if (corrupted) {
      if (await _restoreSnapshot(name)) {
        try {
          final future = Hive.openBox<T>(name);
          unawaited(future.then((_) {}, onError: (Object _) {}));
          final box = await future.timeout(const Duration(seconds: 15));
          Log.logAlways("[$name] 已从健康快照恢复");
          await _clearDegraded(name);
          return box;
        } catch (_) {
          Log.logAlways("[$name] 快照恢复后仍打不开");
        }
      }
      if (await _restoreFromBackup(name)) {
        try {
          final future = Hive.openBox<T>(name);
          unawaited(future.then((_) {}, onError: (Object _) {}));
          final box = await future.timeout(const Duration(seconds: 15));
          Log.logAlways("[$name] 已从 suikan_box_backup 恢复并打开");
          await _clearDegraded(name);
          return box;
        } catch (_) {
          Log.logAlways("[$name] 备份恢复后仍打不开");
        }
      }
      // 三级：备份移除原文件后重建（旧数据已留档在 suikan_box_backup/）
      var cleared = false;
      try {
        cleared = await _deleteBoxFilesDirect(name)
            .timeout(const Duration(seconds: 5));
      } catch (_) {
        cleared = false;
      }
      Log.logAlways(cleared
          ? "[$name] 箱文件损坏，已备份到 suikan_box_backup/ 并重建"
          : "[$name] 箱文件清理失败（被占用），改用备用箱");
      if (cleared) {
        try {
          final future = Hive.openBox<T>(name);
          unawaited(future.then((_) {}, onError: (Object _) {}));
          final box = await future.timeout(const Duration(seconds: 5));
          Log.logAlways("[$name] 重建成功（该箱数据已重置）");
          return box;
        } catch (_) {}
      }
    }

    // ② 走到这里 = 仅超时，或上面自救全失败。降级到备用箱，**原文件原封不动**
    //   留在磁盘上，下次启动（锁释放 / IO 恢复后）会自动读回。
    await _markDegraded(name);
    try {
      final fallbackDir = _fallbackBoxDir();
      final future = Hive.openBox<T>('${name}_fb', path: fallbackDir);
      unawaited(future.then((_) {}, onError: (Object _) {}));
      final box = await future.timeout(const Duration(seconds: 5));
      Log.logAlways(
          "[$name] 降级到备用箱 ${name}_fb（原文件保留，下次启动会自动重试主箱）");
      return box;
    } catch (_) {
      Log.logAlways("打开[$name]箱兜底也失败，数据将被丢弃");
      rethrow;
    }
  }

  /// 降级标记文件：记录"这个箱上次启动没能打开，走了备用箱"。
  /// 有了它，下次启动就能用更短的超时快速试探主箱是否恢复，而不必每次干等 30 秒。
  Future<bool> _wasDegraded(String name) async {
    try {
      return await File(p.join(_fallbackBoxDir(), '$name.degraded')).exists();
    } catch (_) {
      return false;
    }
  }

  Future<void> _markDegraded(String name) async {
    try {
      final dir = Directory(_fallbackBoxDir());
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await File(p.join(dir.path, '$name.degraded'))
          .writeAsString(DateTime.now().toIso8601String());
    } catch (_) {}
  }

  Future<void> _clearDegraded(String name) async {
    try {
      final f = File(p.join(_fallbackBoxDir(), '$name.degraded'));
      if (await f.exists()) await f.delete();
    } catch (_) {}
  }

  /// 箱文件健康快照：主箱写坏（覆盖安装/强杀）时用它回滚，避免数据全空。
  /// 只在箱**成功打开**后延迟执行。
  ///
  /// 延迟从 20 秒压到 3 秒：用户常常是"打开 App 看一眼就覆盖安装"，
  /// 20 秒内快照还没落地就出事，等于没有快照。
  Future<void> _saveSnapshotLater(String name) async {
    await Future<void>.delayed(const Duration(seconds: 3));
    final dir = _hiveDir;
    if (dir == null || dir.isEmpty) return;
    try {
      final src = File(p.join(dir, '$name.hive'));
      if (!await src.exists()) return;
      final dstDir = Directory(p.join(dir, 'suikan_box_snapshot'));
      await dstDir.create(recursive: true);
      final tmp = File(p.join(dstDir.path, '$name.hive.tmp'));
      await src.copy(tmp.path);
      await tmp.rename(p.join(dstDir.path, '$name.hive'));
    } catch (_) {
      // 快照失败不影响使用
    }
  }

  /// 用健康快照回滚主箱文件；无快照、或快照比主箱还旧时返回 false。
  ///
  /// ⚠️ 两条前置判断，缺一都会把新数据倒退回旧数据（表现为"关注列表清空"）：
  /// 1. **主箱比快照新 → 不回滚**。主箱只是打不开（IO 慢/被占用），内容多半
  ///    比上次快照更新，用旧快照覆盖等于主动丢数据。
  /// 2. **回滚前先把主箱挪进 backup**，就算快照也是坏的，原始文件仍在磁盘上。
  Future<bool> _restoreSnapshot(String name) async {
    final dir = _hiveDir;
    if (dir == null || dir.isEmpty) return false;
    try {
      final snap = File(p.join(dir, 'suikan_box_snapshot', '$name.hive'));
      final main = File(p.join(dir, '$name.hive'));
      if (!await snap.exists()) return false;
      if (await main.exists()) {
        final mainMod = await main.lastModified();
        final snapMod = await snap.lastModified();
        if (mainMod.isAfter(snapMod)) {
          Log.logAlways("[$name] 主箱比快照新，放弃快照回滚");
          return false;
        }
        // 旧主箱留档后再覆盖
        final stamp =
            DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');
        final keep =
            Directory(p.join(dir, 'suikan_box_backup', '${name}_pre_$stamp'));
        try {
          await keep.create(recursive: true);
          await main.copy(p.join(keep.path, '$name.hive'));
        } catch (_) {}
      }
      await snap.copy(main.path);
      final lock = File(p.join(dir, '$name.lock'));
      if (await lock.exists()) {
        await lock.delete();
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  /// 兜底空箱前的最后一道自救：从 `suikan_box_backup/` 里最新的同名箱恢复。
  ///
  /// 覆盖安装/强杀导致的"箱打不开 → 备份移除 → 重建空箱"这条链，数据其实一直
  /// 躺在 backup 目录里，但 App 已经改用新空箱了，用户就看到关注列表空了。
  /// 这里在真正建空箱之前先把它捞回来。
  Future<bool> _restoreFromBackup(String name) async {
    final dir = _hiveDir;
    if (dir == null || dir.isEmpty) return false;
    try {
      final root = Directory(p.join(dir, 'suikan_box_backup'));
      if (!await root.exists()) return false;
      final List<FileSystemEntity> dirs;
      try {
        dirs = await root.list().toList();
      } catch (_) {
        return false;
      }
      final mine = dirs
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('${name}_'))
          .toList()
        // 目录名带时间戳，字典序倒序即时间倒序（最新在前）
        ..sort((a, b) => b.path.compareTo(a.path));
      for (final d in mine) {
        final src = File(p.join(d.path, '$name.hive'));
        if (!await src.exists()) continue;
        final dst = File(p.join(dir, '$name.hive'));
        if (await dst.exists()) {
          // 🔴 走到这里 = 主箱文件还在但**已判定损坏**（帧错位/解析失败）。
          // 绝不能因为"文件存在"就放弃恢复 —— 那正是"每次启动都重建空箱、
          // 关注列表永远为空"的直接原因（2026-08-31 实测：39KB 文件帧损坏，
          // 恢复逻辑被 `dst.exists()` 拦住，backup 里的好数据干瞪眼）。
          // 把损坏文件改名留档（不删除，可事后人工检查），再让备份接管。
          try {
            final corrupt =
                '$name.corrupt_${DateTime.now().millisecondsSinceEpoch}.hive';
            await dst.rename(p.join(dir, corrupt));
            Log.logAlways("[$name] 损坏主箱已留档为 $corrupt，用备份恢复");
          } catch (_) {
            // 改名失败（文件被占用等）就放弃这轮恢复，等下一份备份
            return false;
          }
        }
        await src.copy(dst.path);
        Log.logAlways("[$name] 已从 suikan_box_backup 恢复历史数据");
        return true;
      }
    } catch (_) {}
    return false;
  }

  /// 空箱自救：主箱能正常打开但**条目为 0**，而 `suikan_box_backup/` 里躺着历史
  /// 数据 → 把那份数据搬回主箱。
  ///
  /// 这是给「已经被旧版本清掉数据的老用户」准备的补救通道。旧版本的
  /// 「备份移除 + 重建空箱」流程会把原文件挪进
  /// `suikan_box_backup/<name>_<时间戳>/` 再建新空箱 —— **数据一直都在磁盘上**，
  /// 只是 App 不再看它。装一次新版，这里就把数据搬回来，
  /// 表现为「覆盖安装后关注列表自己回来了」。
  ///
  /// 四条硬约束，缺一条都可能变成新的数据事故：
  /// 1. **只在主箱条目为 0 时动作**。有数据的箱一个字节都不碰，绝不覆盖。
  /// 2. **不能直接用备份箱名 openBox**。Hive 的箱缓存按 name 索引，
  ///    `isBoxOpen(name)` 为真时会直接返回**主箱自己**（此时它还是空的），
  ///    于是"捞回"读到的永远是自己 → 永远 count==0，看着正常其实什么也没干。
  ///    必须复制成临时文件名再打开。
  ///    ⚠️ 这不只是"无效"，是**破坏性**的：拿到手的是主箱自己，后续一旦
  ///    调用 `close()` 就把主箱关了，App 之后对该箱的所有读写直接抛
  ///    `HiveError: Box has already been closed`（2026-08-31 用
  ///    `tool/verify_empty_box_rescue.dart` 实测复现，对照组 identical(src, box)=true）。
  ///    别为了"少一次文件拷贝"把它改回同名写法。
  /// 3. **搬完不删备份**，失败还有原件可查。
  /// 4. 用 Hive API 读出来再 putAll，不做文件覆盖 —— 避开与主箱锁的竞争。
  /// 🔴 空箱自救的**时间预算**：自救只是锦上添花，绝不能拖慢启动。
  /// 每份备份都可能损坏，而 Hive.openBox 遇到损坏帧是**挂起不抛异常**的，
  /// 只能靠超时兜底 —— 没有预算的话，备份越多启动越慢。
  /// 实测：7 份 FollowUser + 7 份 History，每份损坏各等 10s → 140s 白屏
  /// （2026-08-31 事故）。
  static const Duration _restoreBudget = Duration(seconds: 8);
  /// 一次启动最多尝试几份备份（最新的优先）。够用了，不值得为更旧的备份
  /// 继续拖慢启动。
  static const int _restoreMaxTries = 3;

  Future<void> _restoreIntoEmptyBox<T>(Box<T> box, String name) async {
    final dir = _hiveDir;
    if (dir == null || dir.isEmpty) return;
    // 所有备份共享这一个时间池，先到先得
    final deadline = DateTime.now().add(_restoreBudget);
    try {
      final root = Directory(p.join(dir, 'suikan_box_backup'));
      if (!await root.exists()) return;
      final List<FileSystemEntity> dirs;
      try {
        dirs = await root.list().toList();
      } catch (_) {
        return;
      }
      final mine = dirs
          .whereType<Directory>()
          .where((d) => p.basename(d.path).startsWith('${name}_'))
          .toList()
        // 目录名带时间戳，字典序倒序即时间倒序（最新在前）
        ..sort((a, b) => b.path.compareTo(a.path));

      final tmpRoot =
          Directory(p.join(dir, 'suikan_box_snapshot', '_restore_tmp'));
      await tmpRoot.create(recursive: true);
      final tmpName = '${name}_restore_tmp';

      var tried = 0;
      for (final d in mine) {
        // 双重闸门：试够份数就停，时间花完也停
        if (tried >= _restoreMaxTries) break;
        if (DateTime.now().isAfter(deadline)) {
          Log.logAlways(
              "[$name] 自救已用满 ${_restoreBudget.inSeconds}s，停止扫描剩余备份");
          break;
        }
        final srcFile = File(p.join(d.path, '$name.hive'));
        if (!await srcFile.exists()) continue;
        // 空壳文件（只写了箱头的空箱，通常 <128B）直接跳过，省一次 openBox
        final size = await srcFile.length().catchError((_) => 0);
        if (size < 128) continue;

        tried++;

        // 复制成临时箱再打开（见约束 2）
        final tmpFile = File(p.join(tmpRoot.path, '$tmpName.hive'));
        if (await tmpFile.exists()) {
          await tmpFile.delete();
        }
        await srcFile.copy(tmpFile.path);
        final tmpLock = File(p.join(tmpRoot.path, '$tmpName.lock'));
        if (await tmpLock.exists()) {
          await tmpLock.delete();
        }

        Box<T>? src;
        Map<dynamic, T> data = <dynamic, T>{};
        try {
          final future = Hive.openBox<T>(tmpName, path: tmpRoot.path);
          unawaited(future.then((_) {}, onError: (Object _) {}));
          // 用**剩余预算**当超时，而不是固定值：多份备份共享同一个时间池，
          // 第一份耗掉的时间要从后面几份的额度里扣
          var remain = deadline.difference(DateTime.now());
          if (remain <= Duration.zero) {
            remain = const Duration(milliseconds: 200);
          }
          src = await future.timeout(remain);
          data = src.toMap();
        } catch (e) {
          Log.logAlways("[$name] 备份 ${p.basename(d.path)} 打不开，跳过: $e");
        }
        if (src != null) {
          try {
            // close 也要限时：它内部会 flush 写队列，磁盘异常时同样可能挂住
            await src.close().timeout(const Duration(seconds: 3));
          } catch (_) {}
        }
        try {
          if (await tmpFile.exists()) await tmpFile.delete();
        } catch (_) {}

        if (data.isEmpty) continue;
        final count = data.length;
        await runExclusive(() => box.putAll(data));
        Log.logAlways(
            "[$name] 主箱为空，已从备份 ${p.basename(d.path)} 捞回 $count 条");
        return;
      }
    } catch (e) {
      Log.logAlways("[$name] 空箱自救失败: $e");
    }
  }

  // 注：曾经的「箱文件帧结构预检」（_hiveFileFrameSafe / _boxFilePath）已删除。
  // 它按错误的格式假设解析 Hive 2.x 帧，会把**正常箱 100% 判为损坏**并删除，
  // 是 2026-08-29 用户数据全量丢失事故的直接原因。判断损坏只交给 Hive.openBox。

  /// 直接用文件 API 处理箱文件（.hive/.lock），带重试。
  /// 不用 Hive.deleteBoxFromDisk：它可能触发 openBox 在损坏文件上挂起。
  /// 判定箱不可用时的处置：**先备份再移除**，绝不直接删除。
  ///
  /// 覆盖安装（或强杀后重启）后的首次启动 IO 很慢，`Hive.openBox` 可能超时——
  /// **超时不等于损坏**。旧逻辑直接 delete 箱文件，于是每次覆盖安装都会把
  /// 关注/历史/直播源清空。现在改为把箱文件移动到
  /// `suikan_box_backup/<name>_<时间戳>/`，数据仍在磁盘上、可事后导出恢复。
  /// 返回 true 表示"箱文件已不存在"（原本就没有 / 已成功备份移除），
  /// false 表示文件仍在（清理失败）→ 调用方必须据此判断，不能再假报成功。
  Future<bool> _deleteBoxFilesDirect(String name) async {
    final dir = _hiveDir;
    if (dir == null || dir.isEmpty) return false;
    final stamp =
        DateTime.now().toIso8601String().replaceAll(RegExp(r'[^0-9]'), '');
    final backupDir =
        Directory(p.join(dir, 'suikan_box_backup', '${name}_$stamp'));
    // ⚠️ 必须连 .hivec 一起清掉：.hivec 是 compact() 的产物，compact 过程中被
    // 强杀/覆盖安装会留下写坏的 .hivec。而 Hive 打开箱时的 findHiveFileAndCleanUp
    // 逻辑是：「.hive 不存在但 .hivec 存在 → 直接把 .hivec 改名成 .hive」。
    // 于是刚清掉的坏数据原地复活，表现为「已备份移除，重开仍是 unknown typeId」，
    // 每次启动都走一遍清空流程，数据永远留不住。
    for (final ext in const ['.hive', '.hivec', '.lock']) {
      final f = File(p.join(dir, '$name$ext'));
      for (var i = 0; i < 3; i++) {
        try {
          if (await f.exists()) {
            try {
              await backupDir.create(recursive: true);
              final moved =
                  await f.rename(p.join(backupDir.path, '$name$ext'));
              if (moved.path.isNotEmpty) break;
            } catch (_) {
              // 移动失败（跨分区/被占用）→ 先复制一份再删除
              try {
                await backupDir.create(recursive: true);
                await f.copy(p.join(backupDir.path, '$name$ext'));
              } catch (_) {}
              await f.delete();
              break;
            }
          } else {
            break;
          }
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      // 三次尝试后文件仍在 → 明确告知调用方"没清理掉"
      try {
        if (await f.exists()) return false;
      } catch (_) {
        return false;
      }
    }
    return true;
  }

  // follow_user_tag 相关逻辑
  bool getFollowTagExist(String id) {
    return tagBox.containsKey(id);
  }

  // 删除标签
  Future deleteFollowTag(String id) async {
    await runExclusive(() => tagBox.delete(id));
  }

  FollowUserTag? getFollowTag(String tag) {
    return tagBox.values.firstWhereOrNull((item) => item.tag == tag);
  }

  // 判断标签名称是否重复
  bool getFollowTagExistByTag(String tag) {
    return tagBox.values.any((item) => item.tag == tag);
  }

  // 获取标签列表
  List<FollowUserTag> getFollowTagList() {
    return tagBox.values.toList();
  }

  // 修改标签
  Future updateFollowTag(FollowUserTag followTag) async {
    await runExclusive(() => tagBox.put(followTag.id, followTag));
  }

  // 添加标签
  Future<FollowUserTag> addFollowTag(String tag) async {
    // 限制标签唯一且长度不超过8个字符
    if (getFollowTagExistByTag(tag) && tag.length > 8) {
      return getFollowTag(tag)!;
    }
    final String uniqueId = uuid.v4();
    final followUserTag = FollowUserTag(id: uniqueId, tag: tag, userId: []);
    await runExclusive(() => tagBox.put(uniqueId, followUserTag));
    return followUserTag;
  }

  // 调整标签顺序
  //
  // 原来是 clear() 再 putAll()：clear 是 truncate(0) 瞬间清空，这两步之间被杀
  // 进程 / 覆盖安装就是"标签全丢"。改成**先写入再删除多余项**——顺序反过来的
  // 话，一次拖动排序就可能赔上全部标签。
  Future updateFollowTagOrder(List<FollowUserTag> userTagList) async {
    final Map<dynamic, FollowUserTag> updatedMap = {
      for (int i = 0; i < userTagList.length; i++) i: userTagList[i]
    };
    await runExclusive(() async {
      await tagBox.putAll(updatedMap);
      final stale =
          tagBox.keys.where((k) => !updatedMap.containsKey(k)).toList();
      if (stale.isNotEmpty) {
        await tagBox.deleteAll(stale);
      }
    });
  }

  /// Hive 2.x 的 writeKey 用 1 字节存 key 长度（上限 255）——关注自定义源时
  /// FollowUser.id = "${siteId}_$roomId" 可能是完整 m3u8 URL（数百字节），
  /// 超长 key 写入会长度溢出（501 & 0xFF = 245）→ 帧错位 → 整个箱判损坏 → 数据全丢。
  /// 超长 key 统一转成"长度_摘要"（幂等、可逆：完整 id 存在 value 里），正常 key 原样。
  static String safeBoxKey(String raw) {
    if (raw.length <= 180) return raw;
    return 'k${raw.length}_${sha1.convert(utf8.encode(raw)).toString().substring(0, 20)}';
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(safeBoxKey(id));
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future addFollow(FollowUser follow) async {
    await runExclusive(() => followBox.put(safeBoxKey(follow.id), follow));
  }

  Future addFollows(Iterable<FollowUser> follows) async {
    await runExclusive(() => followBox.putAll({
          for (final follow in follows) safeBoxKey(follow.id): follow,
        }));
  }

  Future deleteFollow(String id) async {
    await runExclusive(() => followBox.delete(safeBoxKey(id)));
  }

  History? getHistory(String id) {
    final key = safeBoxKey(id);
    if (historyBox.containsKey(key)) {
      return historyBox.get(key);
    }
    return null;
  }

  /// 观看历史条数上限：超出后自动淘汰最旧的记录。
  /// 历史只增不减（每次进直播间都新增或更新一条），不限量会让 Hive 箱无限
  /// 增长：启动要全量读出排序、备份快照体积随之变大（历史备份损坏时每份
  /// 都要等 openBox 超时，2026-08-31 白屏事故就是被多份历史备份拖成 140s）。
  /// 50 条够日常回看（2026-09-05 用户反馈 100 太多）。
  static const int kHistoryMaxCount = 50;

  Future addOrUpdateHistory(History history) async {
    await runExclusive(() async {
      await historyBox.put(safeBoxKey(history.id), history);
      await trimHistoryOverflow();
    });
  }

  /// 超出 [kHistoryMaxCount] 时按 updateTime 淘汰最旧的记录，保留最新的。
  /// 只有超限时才排序（进房写历史的频率很低，代价可忽略）。
  /// ⚠️ 本方法内部**不得**再调 runExclusive（_writeChain 串行链会自我等待死锁），
  /// 由调用方负责包裹。
  Future<void> trimHistoryOverflow() async {
    final overflow = historyBox.length - kHistoryMaxCount;
    if (overflow <= 0) {
      return;
    }
    final all = historyBox.values.toList()
      ..sort((a, b) => a.updateTime.compareTo(b.updateTime));
    await historyBox
        .deleteAll(all.take(overflow).map((e) => safeBoxKey(e.id)).toList());
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
