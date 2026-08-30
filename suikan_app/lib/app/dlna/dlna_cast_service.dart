import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:network_info_plus/network_info_plus.dart';
import 'package:simple_live_app/app/dlna/dlna_proxy_server.dart';

/// 局域网 DLNA / UPnP 投屏（把当前直播直链推送到电视/盒子上的渲染设备）。
///
/// 仅依赖 dart:io，不引入额外依赖：
/// - 发现：UDP 多播 M-SEARCH 到 239.255.255.250:1900，解析各设备 LOCATION，
///   拉取设备描述 XML，找出 AVTransport 服务的控制地址。
/// - 控制：SOAP 调用 SetAVTransportURI + Play（停止用 Stop）。
class DlnaDevice {
  final String name;
  final String avTransportUrl;
  final String? location;

  const DlnaDevice({
    required this.name,
    required this.avTransportUrl,
    this.location,
  });
}

class DlnaCastService {
  static final DlnaCastService instance = DlnaCastService();

  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;
  static const MethodChannel _mc = MethodChannel('simple_live/dlna');

  /// 申请 Android Wifi 多播锁（无原生实现时静默失败，不影响其它平台）。
  Future<void> acquireMulticastLock() async {
    try {
      await _mc.invokeMethod('acquireMulticastLock');
    } catch (_) {
      // 桌面端或缺少原生实现：忽略。
    }
  }

  Future<void> releaseMulticastLock() async {
    try {
      await _mc.invokeMethod('releaseMulticastLock');
    } catch (_) {
      // 忽略。
    }
  }

  /// 发现局域网内支持投屏的渲染设备。
  Future<List<DlnaDevice>> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final devices = <String, DlnaDevice>{};
    // iOS 14+ 本地网络权限：未授权时所有局域网 UDP 被系统静默丢弃 → 搜不到
    // 任何设备。先访问 WiFi 信息触发权限弹窗（network_info_plus 方案，
    // 参考 rusty_dlna）；Info.plist 已配 NSLocalNetworkUsageDescription + Bonjour。
    if (Platform.isIOS) {
      try {
        await NetworkInfo().getWifiName();
      } catch (_) {}
    }
    // 绑定策略：
    // - iOS 必须绑定具体网卡（发组播硬性要求，否则 No route to host）
    // - WIN 也绑定具体网卡（anyIPv4 下 joinMulticast 可能失败导致收不到响应）
    // - Android 走 anyIPv4（原生 MulticastLock 已申请，系统选默认路由）
    // 网卡选择：过滤 loopback / link-local（169.254，如 iOS 的 awdl0 隧道），
    // 优先 WiFi 网卡（en* / wlan* / eth*）——绑到蜂窝/虚拟网卡组播发不出去。
    RawDatagramSocket socket;
    if (!Platform.isAndroid) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        InternetAddress? pick(NetworkInterface i) {
          for (final a in i.addresses) {
            if (a.type != InternetAddressType.IPv4) continue;
            if (a.isLoopback || a.isLinkLocal) continue;
            return a;
          }
          return null;
        }

        RawDatagramSocket? bound;
        InternetAddress? chosen;
        for (final iface in interfaces) {
          final a = pick(iface);
          if (a == null) continue;
          final n = iface.name.toLowerCase();
          if (n.startsWith('en') ||
              n.contains('wlan') ||
              n.contains('eth')) {
            chosen = a;
            break;
          }
        }
        chosen ??= interfaces
            .map(pick)
            .firstWhere((a) => a != null, orElse: () => null);
        if (chosen != null) {
          bound = await RawDatagramSocket.bind(chosen, 0);
        }
        socket = bound ??
            await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      } catch (_) {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }
    } else {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    }
    // 组播出口/入组设置（multicastInterface 在新 Dart 未实现，绑定具体网卡
    // 已保证发送出口与单播响应接收；join 失败仍可收到单播响应）：
    try {
      socket.multicastHops = 4;
      socket.joinMulticast(InternetAddress(_ssdpAddress));
    } catch (_) {
      // join 失败仍可能收到单播响应（设备单播回源地址）
    }

    // 轮换多个 ST：部分设备只响应 ssdp:all 或 rootdevice，不响应 MediaRenderer。
    const searchTargets = [
      'urn:schemas-upnp-org:device:MediaRenderer:1',
      'ssdp:all',
      'upnp:rootdevice',
    ];
    final searches = <List<int>>[
      for (final st in searchTargets)
        utf8.encode(
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 3\r\n'
          'ST: $st\r\n'
          'USER-AGENT: Suikan/2.1 DLNADOC/1.50\r\n'
          '\r\n',
        ),
    ];

    // 参考成熟实现（chromecast_dlna_finder 等）：socket.listen 收包 + Timer 周期发包，
    // 两者并行，避免"无人接收时响应丢失"或"无事件时死等发包"。
    final completer = Completer<void>();
    var sent = 0;
    late final Timer sendTimer;
    sendTimer = Timer.periodic(const Duration(milliseconds: 400), (_) {
      if (sent >= searches.length * 2) {
        sendTimer.cancel();
        return;
      }
      try {
        socket.send(
          searches[sent % searches.length],
          InternetAddress(_ssdpAddress),
          _ssdpPort,
        );
        sent++;
      } catch (_) {
        sendTimer.cancel();
      }
    });
    // 立即发第一个
    socket.send(
      searches.first,
      InternetAddress(_ssdpAddress),
      _ssdpPort,
    );
    sent++;

    socket.listen(
      (event) async {
        if (event == RawSocketEvent.read) {
          while (true) {
            final dg = socket.receive();
            if (dg == null) break;
            final data = String.fromCharCodes(dg.data);
            final location = _headerValue(data, 'LOCATION');
            if (location != null && !devices.containsKey(location)) {
              final dev = await _parseDevice(location);
              if (dev != null) devices[location] = dev;
            }
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (e) {
        if (!completer.isCompleted) completer.complete();
      },
    );

    // 等超时后收尾
    await Future.delayed(timeout);
    sendTimer.cancel();
    socket.close();
    await completer.future.timeout(const Duration(seconds: 1), onTimeout: () {});

    // 多播一条都没捞到 → 单播兜底扫描。iOS 未取得 multicast 授权、路由器
    // AP 隔离、安卓 ROM 限制等情况下多播包会被**静默丢弃**（不报错，就是没响应），
    // 这时只有单播这条路能救回来。成功找到设备时不会走这里，不增加耗时。
    if (devices.isEmpty) {
      final found =
          await _discoverByUnicast(timeout: const Duration(seconds: 4));
      for (final d in found) {
        final key = d.location;
        if (key != null) devices[key] = d;
      }
    }
    return devices.values.toList();
  }

  /// 单播兜底扫描：多播一条鱼都没捞到时，逐个 IP 发**单播** M-SEARCH。
  ///
  /// 为什么需要它：
  /// - iOS 14+ 发送 IP 多播必须声明 `com.apple.developer.networking.multicast`
  ///   （Apple 受限权限）。没拿到时系统会**静默丢弃**多播包 —— 不报错、不崩溃、
  ///   权限弹窗也照弹，但设备永远搜不到。这正是 iOS 端投屏列表为空的头号原因。
  /// - 另外家用路由器的 AP 隔离 / IGMP 设置、部分安卓 ROM 也会拦多播。
  ///
  /// 单播 M-SEARCH 走普通 UDP，**不需要多播权限**，只受本地网络权限约束
  /// （那个只需 NSLocalNetworkUsageDescription，已配）。这是 iOS 上最可靠的
  /// DLNA 发现路径，CocoaUPnP 一类成熟库在 iOS 上都这么干。
  /// 代价是要扫 254 个地址，分批发送 + 短超时，实际一秒多就能出结果。
  Future<List<DlnaDevice>> _discoverByUnicast({
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final devices = <String, DlnaDevice>{};
    // 本机 IPv4：优先 Wi-Fi 网卡，排除 loopback / link-local
    final interfaces = await NetworkInterface.list(
      type: InternetAddressType.IPv4,
      includeLoopback: false,
    );
    InternetAddress? local;
    for (final iface in interfaces) {
      final n = iface.name.toLowerCase();
      if (!(n.startsWith('en') || n.contains('wlan') || n.contains('eth'))) {
        continue;
      }
      for (final a in iface.addresses) {
        if (a.type == InternetAddressType.IPv4 &&
            !a.isLoopback &&
            !a.isLinkLocal) {
          local = a;
          break;
        }
      }
      if (local != null) break;
    }
    if (local == null) return const [];
    // 闭包内无法对可空局部变量做提升，这里固化成非空值供 IIFE 使用
    final self = local;

    // 家用网络基本都是 /24：取前三段。Dart 的 NetworkInterface **不暴露子网
    // 掩码**，无法精确计算网段，按 /24 扫是最实用的近似。
    final parts = self.address.split('.');
    if (parts.length != 4) return const [];
    final prefix = '${parts[0]}.${parts[1]}.${parts[2]}';

    RawDatagramSocket socket;
    try {
      socket = await RawDatagramSocket.bind(local, 0);
    } catch (_) {
      return const [];
    }

    final completer = Completer<void>();
    socket.listen(
      (event) async {
        if (event == RawSocketEvent.read) {
          while (true) {
            final dg = socket.receive();
            if (dg == null) break;
            final data = String.fromCharCodes(dg.data);
            final location = _headerValue(data, 'LOCATION');
            if (location != null && !devices.containsKey(location)) {
              final dev = await _parseDevice(location);
              if (dev != null) devices[location] = dev;
            }
          }
        }
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
      onError: (_) {
        if (!completer.isCompleted) completer.complete();
      },
    );

    // 分批发送：一口气泼 254 个包容易触发本地缓冲丢包 / 被路由器限速，
    // 每 50 个让出 30ms。用 IIFE 异步跑，不阻塞上面的响应监听。
    () async {
      final message = utf8.encode(
        'M-SEARCH * HTTP/1.1\r\n'
        'HOST: $prefix.255:$_ssdpPort\r\n'
        'MAN: "ssdp:discover"\r\n'
        'MX: 2\r\n'
        'ST: ssdp:all\r\n'
        'USER-AGENT: Suikan/2.1 DLNADOC/1.50\r\n'
        '\r\n',
      );
      for (var i = 1; i <= 254; i++) {
        final target = '$prefix.$i';
        if (target == self.address) continue;
        try {
          socket.send(message, InternetAddress(target), _ssdpPort);
        } catch (_) {}
        // 只扫 1~254，跳过 .0（网络号）与 .255（广播地址）
        if (i % 50 == 0) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
        }
      }
    }();

    await Future<void>.delayed(timeout);
    socket.close();
    await completer.future
        .timeout(const Duration(milliseconds: 500), onTimeout: () {});
    return devices.values.toList();
  }

  String? _headerValue(String data, String key) {
    final m = RegExp('$key:\\s*([^\\r\\n]+)', caseSensitive: false)
        .firstMatch(data);
    return m?.group(1)?.trim();
  }

  Future<DlnaDevice?> _parseDevice(String location) async {
    try {
      final uri = Uri.parse(location);
      final client = HttpClient();
      final req = await client.getUrl(uri);
      req.headers.set('Accept', '*/*');
      final resp = await req.close().timeout(const Duration(seconds: 4));
      final xml = await resp.transform(utf8.decoder).join().timeout(
            const Duration(seconds: 4),
          );
      client.close();
      final friendlyName = _xmlTag(xml, 'friendlyName') ?? uri.host;
      final controlUrl = _findAvTransportControlUrl(xml, location);
      if (controlUrl == null) return null;
      return DlnaDevice(
        name: friendlyName,
        avTransportUrl: controlUrl,
        location: location,
      );
    } catch (_) {
      return null;
    }
  }

  String? _xmlTag(String xml, String tag) {
    final m = RegExp('<$tag>([^<]*)</$tag>', caseSensitive: false)
        .firstMatch(xml);
    return m?.group(1)?.trim();
  }

  String? _findAvTransportControlUrl(String xml, String location) {
    final serviceRe = RegExp(
      '<service>(.*?)</service>',
      caseSensitive: false,
      dotAll: true,
    );
    final typeRe = RegExp(
      '<serviceType>[^<]*AVTransport[^<]*</serviceType>',
      caseSensitive: false,
    );
    final controlRe = RegExp(
      '<controlURL>(.*?)</controlURL>',
      caseSensitive: false,
    );
    for (final m in serviceRe.allMatches(xml)) {
      final block = m.group(1) ?? '';
      if (typeRe.hasMatch(block)) {
        final cm = controlRe.firstMatch(block);
        if (cm != null) {
          return _resolveUrl(location, cm.group(1)?.trim() ?? '');
        }
      }
    }
    return null;
  }

  String _resolveUrl(String base, String path) {
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return path;
    }
    final uri = Uri.parse(base);
    if (path.startsWith('/')) {
      return '${uri.scheme}://${uri.host}:${uri.port}$path';
    }
    final dir = uri.path.substring(0, uri.path.lastIndexOf('/') + 1);
    return '${uri.scheme}://${uri.host}:${uri.port}$dir$path';
  }

  /// 把视频直链推送到设备并播放。
  ///
  /// 若 [headers] 非空（如 fnOS 的 Authorization+Authx 鉴权），先在本地起
  /// HTTP 代理，把代理地址推给设备（设备请求代理时实时带鉴权头转发，绕开
  /// `<res http-header>` 非标属性兼容性差的问题）。
  /// 头是否"可推断"（接收端能自己补的，如 referer/user-agent）。
  /// 这类头不需要走本地代理——直接推原 URL，接收端（随看TV 按域名自动补
  /// referer）自己解决，投出端退出 App 也不影响接收方继续播。
  /// 反之（Authorization/Authx 签名等）必须走代理实时转发。
  bool _isInferableHeader(String key) {
    final k = key.toLowerCase();
    return k == 'referer' || k == 'user-agent' || k == 'accept' ||
        k == 'origin';
  }

  Future<void> cast(
    DlnaDevice device,
    String url, {
    Map<String, String>? headers,
    String? title,
    bool isVod = false,
  }) async {
    var pushUrl = url;
    final needsProxy = headers != null &&
        headers.entries.any((e) => !_isInferableHeader(e.key));
    if (needsProxy) {
      pushUrl = await DlnaProxyServer.instance.start(
        targetUrl: url,
        headers: headers,
      );
    }
    final metadata = _buildMetadata(title ?? '随看直播', pushUrl);
    // 请求头必须一并投给接收端。
    // 旧逻辑认为 referer/UA"接收端能按域名自己补"，于是不传——但随看TV 的
    // 按域名补头只认虎牙/斗鱼/B站/抖音/快手，自定义直播源（IPTV、私人 M3U）
    // 一个都匹配不上 → TV 端裸请求被源站拒绝 → 表现为"自定义源一投屏就出错"，
    // 而平台直播正常（它们本就在白名单里）。
    // 只在**直推原 URL** 时携带：走本机代理时头已由代理加上，再传会重复。
    final headersXml =
        (!needsProxy && headers != null && headers.isNotEmpty)
            // Base64 而非裸 JSON：JSON 里的引号经 XML 转义后，接收端用正则取
            // 出来是未解码的 &quot;，jsonDecode 会直接失败。Base64 只含
            // A-Za-z0-9+/=，不碰任何 XML 特殊字符。
            ? '<SuikanHeaders>'
                '${base64Encode(utf8.encode(jsonEncode(headers)))}'
                '</SuikanHeaders>'
            : '';
    await _soap(
      device.avTransportUrl,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
      // 自定义扩展：告诉随看TV 这次是点播还是直播（点播才出进度条/允许拖动）。
      // 标准 UPnP 设备会忽略未知元素，不影响第三方接收端。
      '<SuikanCastType>${isVod ? 'vod' : 'live'}</SuikanCastType>'
      '$headersXml'
      '<CurrentURI>${_esc(pushUrl)}</CurrentURI>'
      '<CurrentURIMetaData>${_esc(metadata)}</CurrentURIMetaData>',
    );
    await _soap(
      device.avTransportUrl,
      'Play',
      '<InstanceID>0</InstanceID><Speed>1</Speed>',
    );
  }

  Future<void> stop(DlnaDevice device) async {
    await _soap(
      device.avTransportUrl,
      'Stop',
      '<InstanceID>0</InstanceID>',
    );
    await DlnaProxyServer.instance.stop();
  }

  Future<void> _soap(String url, String action, String args) async {
    final body = '<?xml version="1.0" encoding="utf-8"?>'
        '<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" '
        's:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">'
        '<s:Body>'
        '<u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">'
        '$args'
        '</u:$action>'
        '</s:Body>'
        '</s:Envelope>';
    final uri = Uri.parse(url);
    final client = HttpClient();
    final req = await client.postUrl(uri);
    req.headers.contentType = ContentType('text', 'xml', charset: 'utf-8');
    req.headers.set(
      'SOAPACTION',
      '"urn:schemas-upnp-org:service:AVTransport:1#$action"',
    );
    req.headers.set('Accept', '*/*');
    req.write(body);
    final resp = await req.close().timeout(const Duration(seconds: 6));
    final code = resp.statusCode;
    final respBody = await resp.transform(utf8.decoder).join().timeout(
          const Duration(seconds: 4),
        );
    client.close();
    if (code >= 400) {
      throw Exception('投屏控制失败($code)');
    }
    if (respBody.contains('errorCode') && respBody.contains('>701<') == false) {
      // 部分设备会返回 200 但带 errorCode，做轻量提示。
      final ec = RegExp('errorCode>(\\d+)<').firstMatch(respBody);
      if (ec != null) {
        throw Exception('投屏设备返回错误码 ${ec.group(1)}');
      }
    }
  }

  String _esc(String s) => s
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;');

  String _buildMetadata(String title, String url) {
    return '<DIDL-Lite '
        'xmlns="urn:schemas-upnp-org:metadata-1-0/DIDL-Lite/" '
        'xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/" '
        'xmlns:dc="http://purl.org/dc/elements/1.1/">'
        '<item id="0" parentID="-1" restricted="1">'
        '<dc:title>${_esc(title)}</dc:title>'
        '<upnp:class>object.item.videoItem</upnp:class>'
        '<res protocolInfo="http-get:*:video/*:*">${_esc(url)}</res>'
        '</item></DIDL-Lite>';
  }
}
