import 'dart:io';

import 'package:simple_live_core/simple_live_core.dart';

/// 探测各平台搜索是否可用（用于排查抖音失败/快手 0 结果）。
///
/// 用法：dart probe_search.dart <关键词> [房间|主播]
void main(List<String> args) async {
  CoreLog.enableLog = true;
  final keyword = args.isNotEmpty ? args.first : '游戏';
  final mode = args.length > 1 ? args[1] : '房间';
  final sites = <LiveSite>[
    BiliBiliSite(),
    DouyuSite(),
    HuyaSite(),
    DouyinSite(),
    KuaishouSite(),
  ];
  for (final site in sites) {
    final name = site.name;
    try {
      if (mode == '主播') {
        final r = await site.searchAnchors(keyword, page: 1);
        print('[OK] $name 主播：${r.items.length} 条');
      } else {
        final r = await site.searchRooms(keyword, page: 1);
        print('[OK] $name 房间：${r.items.length} 条');
        for (final item in r.items.take(3)) {
          print('     - ${item.title} / ${item.userName}');
        }
      }
    } catch (e) {
      print('[FAIL] $name：$e');
    }
  }
  exit(0);
}
