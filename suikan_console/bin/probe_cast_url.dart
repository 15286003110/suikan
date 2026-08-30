import 'dart:convert';
import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';

/// 抓取虎牙/斗鱼真实直播直链（含平台要求的请求头），用于验证投屏代理。
///
/// 用法：dart probe_cast_url.dart huya|douyu
/// 输出 JSON：{"url": "...", "headers": {...}}
void main(List<String> args) async {
  CoreLog.enableLog = false;
  final which = (args.isNotEmpty ? args.first : 'douyu').toLowerCase();
  final site = which == 'huya' ? HuyaSite() : DouyuSite();
  try {
    final rooms = await site.getRecommendRooms(page: 1);
    if (rooms.items.isEmpty) {
      print(jsonEncode({'error': 'no rooms'}));
      exit(1);
    }
    LivePlayUrl? found;
    String? roomIdUsed;
    for (final item in rooms.items.take(8)) {
      try {
        final detail = await site.getRoomDetail(roomId: item.roomId);
        if (!detail.status) continue;
        final quals = await site.getPlayQualites(detail: detail);
        if (quals.isEmpty) continue;
        found = await site.getPlayUrls(detail: detail, quality: quals.first);
        roomIdUsed = item.roomId;
        if (found.urls.isNotEmpty) break;
      } catch (_) {
        // 换下一个房间
      }
    }
    if (found == null || found.urls.isEmpty) {
      print(jsonEncode({'error': 'no playable url'}));
      exit(1);
    }
    print(jsonEncode({
      'site': which,
      'roomId': roomIdUsed,
      'url': found.urls.first,
      'headers': found.headers ?? {},
    }));
  } catch (e) {
    print(jsonEncode({'error': e.toString()}));
    exit(1);
  }
  exit(0);
}
