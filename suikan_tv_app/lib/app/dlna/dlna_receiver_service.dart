import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get/get.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:simple_live_tv_app/app/custom_source/custom_m3u_site.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';

/// DLNA/UPnP 投屏接收端服务。
///
/// 让装了 Suikan TV 的盒子/电视成为一个标准 MediaRenderer：
/// - HTTP 服务：提供 UPnP 设备描述 XML（宣告 MediaRenderer + AVTransport）
/// - SOAP 控制：SetAVTransportURI（拿到视频 URL）/ Play / Stop / Pause / Seek
/// - SSDP 应答：响应局域网内投屏端（B站/抖音/爱奇艺/飞牛影视等）的 M-SEARCH
///
/// 收到 URL 后通过 CustomM3uSite 复用现有播放链路（roomId=URL 直接播）。
class DlnaReceiverService extends GetxService {
  static final DlnaReceiverService instance = DlnaReceiverService();

  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;

  HttpServer? _httpServer;
  RawDatagramSocket? _ssdpSocket;
  Timer? _notifyTimer;

  /// 当前投屏的 URL（供状态显示）
  final RxString currentUrl = ''.obs;

  bool get running => _httpServer != null;

  int get _httpPort => _httpServer?.port ?? 0;

  /// 启动接收端服务。
  Future<void> start() async {
    await stop();
    // 1) HTTP 服务：设备描述 + SOAP 控制
    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addHandler(_handleHttp);
    _httpServer = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      0,
    );

    // 2) SSDP：响应 M-SEARCH + 周期发送 NOTIFY 宣告存在
    _ssdpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    _ssdpSocket!.multicastHops = 4;
    try {
      _ssdpSocket!.joinMulticast(InternetAddress(_ssdpAddress));
    } catch (_) {}
    _ssdpSocket!.listen((event) async {
      if (event == RawSocketEvent.read) {
        while (true) {
          final dg = _ssdpSocket!.receive();
          if (dg == null) break;
          final data = String.fromCharCodes(dg.data);
          if (data.contains('M-SEARCH')) {
            await _replySsdp(dg);
          }
        }
      }
    });

    // 周期 NOTIFY（部分设备/投屏端靠它发现新设备）
    _notifyTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _sendNotify();
    });
    await _sendNotify();
  }

  Future<void> stop() async {
    _notifyTimer?.cancel();
    _notifyTimer = null;
    try {
      await _httpServer?.close(force: true);
    } catch (_) {}
    _httpServer = null;
    try {
      _ssdpSocket?.close();
    } catch (_) {}
    _ssdpSocket = null;
  }

  // ---------- HTTP ----------

  Future<shelf.Response> _handleHttp(shelf.Request request) async {
    final path = request.url.path;
    if (path.isEmpty || path == 'device.xml' || path == 'device_description.xml') {
      return shelf.Response.ok(await _deviceXml(), headers: {
        'Content-Type': 'text/xml; charset=utf-8',
        'Server': 'SuikanTV/2.1 UPnP/1.0 DLNADOC/1.50',
      });
    }
    if (path == 'control/avtransport_scpd.xml' ||
        path == 'control/cm_scpd.xml') {
      // 部分投屏端（尤其严格实现的播放器）会先拉 SCPD 验证服务能力，
      // 404 会被判为无效设备。这里返回最小可用能力文档。
      return shelf.Response.ok(_scpdXml(), headers: {
        'Content-Type': 'text/xml; charset=utf-8',
      });
    }
    if (path.startsWith('control')) {
      final body = await request.readAsString();
      return _handleControl(body);
    }
    return shelf.Response.notFound('Not Found');
  }

  String _scpdXml() {
    return '''<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>SetAVTransportURI</name></action>
    <action><name>Play</name></action>
    <action><name>Stop</name></action>
    <action><name>Pause</name></action>
    <action><name>Seek</name></action>
    <action><name>GetTransportInfo</name></action>
    <action><name>GetPositionInfo</name></action>
    <action><name>GetMediaInfo</name></action>
  </actionList>
</scpd>''';
  }

  Future<String> _deviceXml() async {
    final ip = await _localIp();
    return '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>Suikan TV（投屏接收）</friendlyName>
    <manufacturer>Suikan</manufacturer>
    <manufacturerURL>https://github.com/mobingchong/suikan</manufacturerURL>
    <modelName>Suikan TV Receiver</modelName>
    <UDN>uuid:suikan-tv-receiver-0001</UDN>
    <serviceList>
      <service>
        <serviceType>urn:schemas-upnp-org:service:AVTransport:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/control/avtransport</controlURL>
        <eventSubURL>/control/event</eventSubURL>
        <SCPDURL>/control/avtransport_scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>urn:schemas-upnp-org:service:ConnectionManager:1</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/control/cm</controlURL>
        <eventSubURL>/control/event</eventSubURL>
        <SCPDURL>/control/cm_scpd.xml</SCPDURL>
      </service>
    </serviceList>
    <presentationURL>http://$ip:$_httpPort/</presentationURL>
  </device>
</root>''';
  }

  Future<shelf.Response> _handleControl(String body) async {
    if (body.contains('SetAVTransportURI')) {
      final urlMatch = RegExp('<CurrentURI>(.*?)</CurrentURI>', dotAll: true)
          .firstMatch(body);
      final url = urlMatch?.group(1)?.trim() ?? '';
      if (url.isNotEmpty) {
        currentUrl.value = url;
        _play(url);
      }
      return _soapResponse('SetAVTransportURIResponse');
    }
    if (body.contains('>Play<')) {
      return _soapResponse('PlayResponse');
    }
    if (body.contains('>Stop<')) {
      return _soapResponse('StopResponse');
    }
    if (body.contains('>Pause<')) {
      return _soapResponse('PauseResponse');
    }
    if (body.contains('>Seek<')) {
      return _soapResponse('SeekResponse');
    }
    if (body.contains('GetTransportInfo')) {
      return _soapResponse(
        'GetTransportInfoResponse',
        inner: '<CurrentTransportState>PLAYING</CurrentTransportState>'
            '<CurrentTransportStatus>OK</CurrentTransportStatus>'
            '<CurrentSpeed>1</CurrentSpeed>',
      );
    }
    return _soapResponse('UnknownResponse');
  }

  shelf.Response _soapResponse(String action, {String inner = ''}) {
    final xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="urn:schemas-upnp-org:service:AVTransport:1">$inner</u:$action>
  </s:Body>
</s:Envelope>''';
    return shelf.Response.ok(xml, headers: {
      'Content-Type': 'text/xml; charset="utf-8"',
      'EXT': '',
    });
  }

  // ---------- 播放对接 ----------

  void _play(String url) {
    // 复用 CustomM3uSite：roomId=URL 直接播（空 channels，getRoomDetail
    // 对未知 URL 回退用 roomId 本身作为播放地址，正好匹配投屏场景）。
    final site = Site(
      id: 'cast_receiver',
      name: '投屏接收',
      logo: '',
      liveSite: CustomM3uSite(channels: []),
    );
    AppNavigator.toLiveRoomDetail(
      site: site,
      roomId: url,
      isVod: true,
    );
  }

  // ---------- SSDP ----------

  Future<void> _replySsdp(Datagram dg) async {
    final st = _header(dg.data, 'ST');
    if (st == null) return;
    final isTarget = st.contains('MediaRenderer') ||
        st == 'ssdp:all' ||
        st == 'upnp:rootdevice';
    if (!isTarget) return;
    final ip = await _localIp();
    final response = utf8.encode(
      'HTTP/1.1 200 OK\r\n'
      'CACHE-CONTROL: max-age=1800\r\n'
      'EXT:\r\n'
      'LOCATION: http://$ip:$_httpPort/device.xml\r\n'
      'SERVER: SuikanTV/2.1 UPnP/1.0 DLNADOC/1.50\r\n'
      'ST: $st\r\n'
      'USN: uuid:suikan-tv-receiver-0001::$st\r\n'
      '\r\n',
    );
    _ssdpSocket?.send(response, dg.address, dg.port);
  }

  Future<void> _sendNotify() async {
    final ip = await _localIp();
    final data = utf8.encode(
      'NOTIFY * HTTP/1.1\r\n'
      'HOST: $_ssdpAddress:$_ssdpPort\r\n'
      'CACHE-CONTROL: max-age=1800\r\n'
      'LOCATION: http://$ip:$_httpPort/device.xml\r\n'
      'NT: upnp:rootdevice\r\n'
      'NTS: ssdp:alive\r\n'
      'SERVER: SuikanTV/2.1 UPnP/1.0 DLNADOC/1.50\r\n'
      'USN: uuid:suikan-tv-receiver-0001::upnp:rootdevice\r\n'
      '\r\n',
    );
    _ssdpSocket?.send(data, InternetAddress(_ssdpAddress), _ssdpPort);
  }

  String? _header(List<int> data, String key) {
    final s = String.fromCharCodes(data);
    final m = RegExp('$key:\\s*([^\\r\\n]+)', caseSensitive: false)
        .firstMatch(s);
    return m?.group(1)?.trim();
  }

  Future<String> _localIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        if (iface.addresses.isEmpty) continue;
        final addr = iface.addresses.first;
        if (addr.isLoopback) continue;
        return addr.address;
      }
    } catch (_) {}
    return '127.0.0.1';
  }

  @override
  void onClose() {
    stop();
    super.onClose();
  }
}
