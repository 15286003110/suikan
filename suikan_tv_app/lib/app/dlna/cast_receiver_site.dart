import 'package:simple_live_core/simple_live_core.dart';

import '../custom_source/custom_m3u_site.dart';

/// 投屏接收专用 Site：roomId=URL 直接播。
///
/// 拉流方式（关键）：
/// 默认走**接收端本地代理**（`/cast_stream`）——投屏 URL 交给本进程用
/// HttpClient 带 referer/UA 去拉，再流式转发给播放器。
/// 原因：mpv 的自定义请求头依赖 media_kit 的 `httpHeaders` 传递
/// （on_load 钩子按 URI 查缓存回写 `http-header-fields`），投屏场景下
/// 偶发不生效；而虎牙/斗鱼的 CDN 强制校验 referer/UA，缺头会先吐几秒
/// 数据再掐断 → 表现就是"播 1~2 秒后播放失败"。走本地代理后请求头由
/// 本进程完全掌控，且不受投屏端在线与否影响。
class CastReceiverSite extends CustomM3uSite {
  CastReceiverSite() : super(channels: []);

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    final raw = detail.url;
    final proxied = proxyUrlBuilder?.call(raw);
    if (proxied != null && proxied.isNotEmpty) {
      // 交给本地代理：请求头由代理端补齐，无需再传给 mpv。
      return Future.value(LivePlayUrl(urls: [proxied]));
    }
    // 代理不可用（服务未启动）：退回直连 + 请求头。
    return Future.value(LivePlayUrl(
      urls: [raw],
      headers: headersFor(raw),
    ));
  }

  /// 由 DLNA 接收服务注入：把原始流地址包成本地代理地址。
  /// 未注入（服务未启动）时为 null → 走直连。
  static String Function(String url)? proxyUrlBuilder;

  static const ua =
      'Mozilla/5.0 (Linux; Android 13; TV) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/120.0.0.0 Mobile Safari/537.36';

  /// 按 URL 域名补齐 referer/UA（代理与直连共用）。
  static Map<String, String>? headersFor(String url) {
    final host = Uri.tryParse(url)?.host ?? '';
    final referer = refererFor(host);
    if (referer == null) return null;
    return {'referer': referer, 'user-agent': ua};
  }

  static String? refererFor(String host) {
    final lh = host.toLowerCase();
    // 虎牙（含其 CDN 域名）
    if (lh.contains('huya.com') ||
        lh.contains('huscdn.com') ||
        lh.contains('hhimg.com') ||
        lh.contains('huya')) {
      return 'https://www.huya.com/';
    }
    // B站（含 CDN：bilivideo.com / hdslb.com）
    if (lh.contains('bilibili.com') ||
        lh.contains('bilivideo.com') ||
        lh.contains('hdslb.com')) {
      return 'https://www.bilibili.com/';
    }
    // 斗鱼（含 CDN：douyucdn.cn / douyucdn2.cn / douyucdn3.cn 等系列）
    if (lh.contains('douyu.com') ||
        lh.contains('douyucdn')) {
      return 'https://www.douyu.com/';
    }
    // 抖音
    if (lh.contains('douyin.com') ||
        lh.contains('douyincdn.com') ||
        lh.contains('zijieapi.com')) {
      return 'https://live.douyin.com/';
    }
    // 快手
    if (lh.contains('kuaishou.com')) {
      return 'https://live.kuaishou.com/';
    }
    return null;
  }
}
