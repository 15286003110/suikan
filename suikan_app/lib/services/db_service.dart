import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:get/get.dart';
import 'package:hive/hive.dart';
import 'package:path/path.dart' as p;
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
    _hiveDir = hivePath;
    historyBox = await _openBoxResilient<History>("History");
    followBox = await _openBoxResilient<FollowUser>("FollowUser");
    tagBox = await _openBoxResilient<FollowUserTag>("FollowUserTag");
    customSourceBox = await _openBoxResilient<String>("CustomSource");
    fnOsBox = await _openBoxResilient<String>("FnOsServer");
  }

  /// Hive 数据目录（由 main 传入，primary 与 secondary 实例路径不同）。
  String? _hiveDir;

  /// 打开 Hive 箱（带超时、自动清理与兜底），保证损坏/被占用的箱文件不会让 App 启动卡死。
  /// - 只有在 openBox **确实失败**（超时 / unknown typeId / adapter 不匹配）时才删除重建；
  /// - 删除/重建同样可能被锁挂起 → 用文件直删+重试，再失败改用临时目录空箱兜底，App 照常启动。
  /// - 注意：不要在此处做「自行解析帧结构」的预检。Hive 2.x 的箱头/帧格式与手工假设不同，
  ///   自行预检会把**正常箱 100% 误判为损坏**并删除 → 直接造成用户数据全丢（2026-08-29 事故）。
  ///   判断损坏的唯一可靠方式就是交给 Hive.openBox 自己读。
  Future<Box<T>> _openBoxResilient<T>(String name) async {
    // 第一步：正常打开。任何异常（含 unknown typeId / adapter 不匹配）都进入重建流程。
    try {
      final future = Hive.openBox<T>(name);
      // 超时后原始 future 仍可能在后台完成并抛错 → 消费其错误，避免 Unhandled Exception。
      unawaited(future.then((_) {}, onError: (Object _) {}));
      return await future.timeout(const Duration(seconds: 5));
    } catch (e) {
      Log.logPrint("打开[$name]箱超时/异常($e)，尝试删除重建");
    }
    // 超时后挂起的 openBox 可能仍占用文件句柄，删除也要限时+重试，失败直接走兜底。
    try {
      await _deleteBoxFilesDirect(name).timeout(const Duration(seconds: 5));
      Log.logPrint("检测到[$name]箱文件异常，已删除重建");
    } catch (_) {
      Log.logPrint("删除[$name]箱文件失败（可能被占用），改用临时空箱兜底");
    }
    // 第二步：删除后重开。也可能失败（锁未释放 / 原文件仍被占用），继续走兜底。
    try {
      final future = Hive.openBox<T>(name);
      unawaited(future.then((_) {}, onError: (Object _) {}));
      return await future.timeout(const Duration(seconds: 5));
    } catch (_) {
      Log.logPrint("打开[$name]箱失败，改用临时空箱兜底（该箱数据将为空）");
    }
    // 兜底：临时目录空箱，保证 App 不因任何单箱异常而卡死启动。
    try {
      final fallbackDir =
          p.join(Directory.systemTemp.path, 'suikan_box_fallback');
      return await Hive.openBox<T>('${name}_fb', path: fallbackDir);
    } catch (_) {
      // 极端情况：临时目录也失败。Hive 无法打开时抛出的异常会让上层崩溃，
      // 这里直接抛出一个明确的错误，由调用方记录后继续。
      Log.logPrint("打开[$name]箱兜底也失败，数据将被丢弃");
      rethrow;
    }
  }

  /// 箱文件完整路径（基于传入的 Hive 数据目录），无法确定时返回 null。
  String? _boxFilePath(String name) {
    final dir = _hiveDir;
    if (dir == null || dir.isEmpty) return null;
    return p.join(dir, '$name.hive');
  }

  /// 轻量校验 Hive 文件帧结构（长度边界），损坏返回 false。
  /// 目的：损坏文件会让 Hive.openBox 读取挂起（声明帧长超出文件剩余时死等），
  /// 提前发现直接走删除重建，避免启动卡死。
  bool _hiveFileFrameSafe(String path) {
    final f = File(path);
    if (!f.existsSync()) return true;
    try {
      final raf = f.openSync();
      try {
        final len = raf.lengthSync();
        if (len == 0) return true;
        final bytes = raf.readSync(len);
        var pos = 0;
        final nameLen = bytes[pos++];
        if (nameLen > 64 || pos + nameLen > len) return false;
        pos += nameLen;
        final bd = ByteData.sublistView(bytes);
        while (pos + 4 <= len) {
          final frameLen = bd.getUint32(pos, Endian.little);
          pos += 4;
          // 帧至少 keyLen(4)+valueLen(4)+crc(4)；且不能超出文件剩余。
          if (frameLen < 12 || frameLen > len - pos) return false;
          pos += frameLen;
        }
        return pos == len;
      } finally {
        raf.closeSync();
      }
    } catch (_) {
      return false;
    }
  }

  /// 直接用文件 API 删除箱文件（.hive/.lock），带重试。
  /// 不用 Hive.deleteBoxFromDisk：它可能触发 openBox 在损坏文件上挂起。
  Future<void> _deleteBoxFilesDirect(String name) async {
    final dir = _hiveDir;
    if (dir == null || dir.isEmpty) return;
    for (final ext in const ['.hive', '.lock']) {
      final f = File(p.join(dir, '$name$ext'));
      for (var i = 0; i < 3; i++) {
        try {
          if (await f.exists()) {
            await f.delete();
          }
          break;
        } catch (_) {
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
    }
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
  Future updateFollowTagOrder(List<FollowUserTag> userTagList) async {
    final Map<int, FollowUserTag> updatedMap = {
      for (int i = 0; i < userTagList.length; i++) i: userTagList[i]
    };
    await runExclusive(() async {
      await tagBox.clear();
      await tagBox.putAll(updatedMap);
    });
  }

  bool getFollowExist(String id) {
    return followBox.containsKey(id);
  }

  List<FollowUser> getFollowList() {
    return followBox.values.toList();
  }

  Future addFollow(FollowUser follow) async {
    await runExclusive(() => followBox.put(follow.id, follow));
  }

  Future addFollows(Iterable<FollowUser> follows) async {
    await runExclusive(() => followBox.putAll({
          for (final follow in follows) follow.id: follow,
        }));
  }

  Future deleteFollow(String id) async {
    await runExclusive(() => followBox.delete(id));
  }

  History? getHistory(String id) {
    if (historyBox.containsKey(id)) {
      return historyBox.get(id);
    }
    return null;
  }

  Future addOrUpdateHistory(History history) async {
    await runExclusive(() => historyBox.put(history.id, history));
  }

  List<History> getHistores() {
    var his = historyBox.values.toList();
    his.sort((a, b) => b.updateTime.compareTo(a.updateTime));
    return his;
  }
}
