import 'package:simple_live_core/simple_live_core.dart';

import '../custom_source/custom_m3u_site.dart';

/// 投屏接收专用 Site：roomId=URL 直接播。
///
/// 与 CustomM3uSite 的区别：按 URL 域名自动补 referer/UA 头。
/// 多数投屏端（B站/虎牙/斗鱼等）推的是裸 URL 不带头，而它们的 CDN
/// 校验 referer/UA——接收端不补会拉流 403/403 Forbidden
/// （虎牙/iOS B站投屏失败的典型原因）。
class CastReceiverSite extends CustomM3uSite {
  CastReceiverSite() : super(channels: []);

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    return Future.value(LivePlayUrl(
      urls: [detail.url],
      headers: _headersFor(detail.url),
    ));
  }

  static const _ua =
      'Mozilla/5.0 (Linux; Android 13; TV) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  Map<String, String>? _headersFor(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    final lh = host.toLowerCase();
    final referer = _refererFor(lh);
    if (referer == null) return null;
    return {'referer': referer, 'user-agent': _ua};
  }

  String? _refererFor(String host) {
    // 虎牙（含其 CDN 域名）
    if (host.contains('huya.com') ||
        host.contains('huscdn.com') ||
        host.contains('hhimg.com')) {
      return 'https://www.huya.com/';
    }
    // B站（含 CDN：bilivideo.com / hdslb.com）
    if (host.contains('bilibili.com') ||
        host.contains('bilivideo.com') ||
        host.contains('hdslb.com')) {
      return 'https://www.bilibili.com/';
    }
    // 斗鱼
    if (host.contains('douyu.com') || host.contains('douyucdn.cn')) {
      return 'https://www.douyu.com/';
    }
    // 抖音
    if (host.contains('douyin.com') ||
        host.contains('douyincdn.com') ||
        host.contains('zijieapi.com')) {
      return 'https://live.douyin.com/';
    }
    // 快手
    if (host.contains('kuaishou.com')) {
      return 'https://live.kuaishou.com/';
    }
    return null;
  }
}
