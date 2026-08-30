import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
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
    // 绑定策略：
    // - iOS 必须绑定具体网卡（发组播硬性要求，否则 No route to host）
    // - WIN 也绑定具体网卡（anyIPv4 下 joinMulticast 可能失败导致收不到响应）
    // - Android 走 anyIPv4（原生 MulticastLock 已申请，系统选默认路由）
    RawDatagramSocket socket;
    if (!Platform.isAndroid) {
      try {
        final interfaces = await NetworkInterface.list(
          type: InternetAddressType.IPv4,
          includeLoopback: false,
        );
        RawDatagramSocket? bound;
        for (final iface in interfaces) {
          if (iface.addresses.isEmpty) continue;
          final addr = iface.addresses.first;
          if (addr.isLoopback) continue;
          bound = await RawDatagramSocket.bind(addr, 0);
          break;
        }
        socket = bound ??
            await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      } catch (_) {
        socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      }
    } else {
      socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
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
  Future<void> cast(
    DlnaDevice device,
    String url, {
    Map<String, String>? headers,
    String? title,
  }) async {
    var pushUrl = url;
    if (headers != null && headers.isNotEmpty) {
      pushUrl = await DlnaProxyServer.instance.start(
        targetUrl: url,
        headers: headers,
      );
    }
    final metadata = _buildMetadata(title ?? '随看直播', pushUrl);
    await _soap(
      device.avTransportUrl,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
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
