import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

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
    // iOS 发组播必须绑定具体接口（绑定 0.0.0.0 报 "No route to host" errno 65）；
    // WIN/Android 走 anyIPv4 由系统选默认路由即可，强行绑接口反而可能选错网卡
    // （虚拟网卡/VPN 优先于 WiFi）导致收不到设备响应。
    RawDatagramSocket socket;
    if (Platform.isIOS) {
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
    try {
      socket.multicastHops = 4;
      try {
        socket.joinMulticast(InternetAddress(_ssdpAddress));
      } catch (e) {
        // 加入组播组失败时仍尝试发送（部分设备会回本机/仍可收到）。
        assert(() {
          // ignore: avoid_print
          print('DLNA joinMulticast failed: $e');
          return true;
        }());
      }
      // 轮换多个 ST：部分设备只响应 ssdp:all 或 rootdevice，不响应 MediaRenderer。
      // （飞牛播放器能发现设备的原因之一就是发送了更通用的搜索目标。）
      const searchTargets = [
        'urn:schemas-upnp-org:device:MediaRenderer:1',
        'ssdp:all',
        'upnp:rootdevice',
      ];
      for (final st in searchTargets) {
        final search = utf8.encode(
          'M-SEARCH * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'MAN: "ssdp:discover"\r\n'
          'MX: 3\r\n'
          'ST: $st\r\n'
          'USER-AGENT: Suikan/2.1 DLNADOC/1.50\r\n'
          '\r\n',
        );
        for (var i = 0; i < 2; i++) {
          socket.send(search, InternetAddress(_ssdpAddress), _ssdpPort);
          await Future.delayed(const Duration(milliseconds: 300));
        }
      }
      final until = DateTime.now().add(timeout);
      await for (final event in socket) {
        if (event == RawSocketEvent.read) {
          final dg = socket.receive();
          if (dg == null) continue;
          final data = String.fromCharCodes(dg.data);
          final location = _headerValue(data, 'LOCATION');
          if (location != null && !devices.containsKey(location)) {
            final dev = await _parseDevice(location);
            if (dev != null) devices[location] = dev;
          }
        }
        if (DateTime.now().isAfter(until)) break;
      }
    } finally {
      socket.close();
    }
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
  Future<void> cast(
    DlnaDevice device,
    String url, {
    Map<String, String>? headers,
    String? title,
  }) async {
    final metadata = _buildMetadata(title ?? '随看直播', url);
    await _soap(
      device.avTransportUrl,
      'SetAVTransportURI',
      '<InstanceID>0</InstanceID>'
      '<CurrentURI>${_esc(url)}</CurrentURI>'
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
