// B站 WBI 风控自愈验证脚本（2026-09-05 新增）。
//
// 目的：f991ba6 修复"必须去网页验证才恢复弹幕"后，提供可重复的自测手段：
//  1) 用故意写坏的 WBI key 请求弹幕 token 接口，观察 B 站真实返回码，
//     验证 getWbiJson 拦截的 -352/-412/-509/-799 是否覆盖实际情况
//     （若实际是 -403 等码，说明拦截码集合不完整，自愈不会触发）。
//  2) 验证 getWbiJson 的自愈路径：坏 key → 触发 forceRefresh → 重新取 key
//     → 重试成功拿到弹幕 token。
//
// 跑法（在 suikan_core 目录下，需先 pub get）：
//   D:/dev/flutter/bin/cache/dart-sdk/bin/dart.exe tool/verify_bili_wbi.dart
//
// 注意：本脚本发真实网络请求到 B站，需要联网；脚本会污染 BiliBiliSite 的
// 静态 WBI key 缓存，仅在单进程内影响，不影响 App。

import 'package:dio/dio.dart';
import 'package:simple_live_core/src/bilibili_site.dart';
import 'package:simple_live_core/src/common/core_log.dart';
import 'package:simple_live_core/src/danmaku/bilibili_danmaku.dart';

/// 从 LiveRoomDetail.danmakuData 提取弹幕参数（实际为 BiliBiliDanmakuArgs）。
(String token, bool hostOk) extractDanmaku(dynamic danmakuData) {
  if (danmakuData is BiliBiliDanmakuArgs) {
    return (danmakuData.token, danmakuData.serverHost.isNotEmpty);
  }
  // 兜底：若不是标准对象则按 Map 再试一次
  if (danmakuData is Map) {
    final token = danmakuData["token"]?.toString() ?? "";
    final hostList = danmakuData["host_list"];
    return (
      token,
      hostList is List && hostList.isNotEmpty,
    );
  }
  return ("", false);
}

Future<void> main() async {
  CoreLog.enableLog = true;
  print("==== B站 WBI 自愈验证 ====");

  final site = BiliBiliSite();
  site.cookie = ""; // 匿名，最能代表"被风控"场景

  // 取一个真实直播间（避免用固定房间号踩到无弹幕的坑）
  print("\n[0] 取推荐流真实房间...");
  final recommend = await site.getRecommendRooms(page: 1);
  if (recommend.items.isEmpty) {
    print("    [失败] 推荐流为空 —— 网络/接口异常，后续无意义");
    return;
  }
  final roomId = recommend.items.first.roomId;
  print("    使用房间 roomId=$roomId title=${recommend.items.first.title}");

  // ---- 测试 A：坏 key 场景，验证自愈 + 观察 B 站返回码 ----
  print("\n[A] 写入坏 WBI key 请求弹幕 token（触发自愈）...");
  // 先取一次正常 key，把"_wbiKeysFetchedAt"推到"新鲜"，然后污染 key 内容。
  await site.getWbiKeys(forceRefresh: true);
  BiliBiliSite.kImgKey = "x" * 32;
  BiliBiliSite.kSubKey = "y" * 32;

  try {
    final detail = await site.getRoomDetail(roomId: roomId);
    final (token, hostOk) = extractDanmaku(detail.danmakuData);
    print("    token=${token.isEmpty ? "空" : "有值✓"} host=${hostOk ? "有✓" : "空"}");
    print("    => ${token.isNotEmpty && hostOk ? "自愈成功：坏 key 被强制刷新后恢复" : "自愈后仍失败"}"
        .replaceAll(RegExp(r'^    => '), "    => "));
  } catch (e) {
    print("    [自愈失败/异常] $e");
  }

  // ---- 测试 B：正常状态对照组 ----
  print("\n[B] 对照组：强制刷新干净 key 后请求...");
  try {
    await site.getWbiKeys(forceRefresh: true);
    final detail = await site.getRoomDetail(roomId: roomId);
    final (token, hostOk) = extractDanmaku(detail.danmakuData);
    print("    token=${token.isEmpty ? "空(异常)" : "有值✓"} host=${hostOk ? "有✓" : "空(异常)"}");
    print("    => ${token.isNotEmpty && hostOk ? "链路正常 ✓" : "异常，见上方原始返回"}"
        .replaceAll(RegExp(r'^    => '), "    => "));
  } catch (e) {
    print("    [失败] $e");
  }

  // ---- 测试 C：直接看一次原始响应，确认坏 key 的返回码 ----
  print("\n[C] 坏 key 的原始返回码（校验拦截码集合是否完整）...");
  try {
    await site.getWbiKeys(forceRefresh: true);
    BiliBiliSite.kImgKey = "x" * 32;
    BiliBiliSite.kSubKey = "y" * 32;
    // 手动构造一次坏签名请求（绕过自愈，直接看 code）
    final sign = await site.getWbiSign(
        "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?id=$roomId&type=0");
    final dio = Dio(BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 20),
    ));
    final resp = await dio.get(
      "https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo",
      queryParameters: sign,
      options: Options(
        responseType: ResponseType.plain,
        headers: await site.getHeader(),
      ),
    );
    final body = resp.data?.toString() ?? "";
    print("    坏 key 原始返回: ${body.substring(0, body.length > 200 ? 200 : body.length)}");
  } catch (e) {
    print("    [C 异常] $e");
  }

  print("\n==== 验证结束 ====");
}
