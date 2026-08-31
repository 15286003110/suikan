import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shelf/shelf.dart' as shelf;
import 'package:shelf/shelf_io.dart' as shelf_io;
import 'package:simple_live_tv_app/app/controller/app_settings_controller.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/dlna/cast_receiver_site.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/modules/live_room/live_room_controller.dart';
import 'package:simple_live_tv_app/routes/app_navigation.dart';

/// DLNA/UPnP 投屏接收端服务（标准 MediaRenderer）。
///
/// 让装了 Suikan TV 的盒子/电视成为一个标准 DLNA 渲染器：
/// - HTTP 服务：设备描述 XML（宣告 MediaRenderer + AVTransport /
///   ConnectionManager / RenderingControl 三服务）+ 完整 SCPD 能力文档
/// - SOAP 控制：SetAVTransportURI / Play / Pause / Stop / Seek /
///   GetTransportInfo / GetPositionInfo / GetMediaInfo /
///   ConnectionManager（GetProtocolInfo 等）/ RenderingControl（音量/静音）
/// - SSDP：经 Android 原生 MulticastSocket（共享 UDP 1900，盒子系统服务
///   已占用该端口）响应局域网内所有投屏端（B站/抖音/爱奇艺/飞牛影视/各家
///   播放器）的 M-SEARCH（含 uuid 精确匹配），周期 NOTIFY alive，停止时 byebye
///
/// 收到 URL 后复用 CustomM3uSite 播放链路（roomId=URL 直接播），
/// 控制动作真实映射到 media_kit 播放器（play/pause/seek/音量/进度回读）。
class DlnaReceiverService extends GetxService {
  static final DlnaReceiverService instance = DlnaReceiverService();

  static const String _ssdpAddress = '239.255.255.250';
  static const int _ssdpPort = 1900;

  /// 与原生层（DlnaReceiverChannel.kt）通信的通道
  static const MethodChannel _channel = MethodChannel(
    'simple_live_tv/dlna_receiver',
  );

  /// 设备唯一标识（盒子固定，投屏端靠它记忆设备）
  static const String _uuid = 'uuid:5333d8a0-9c8f-4b2e-8f2e-1a2b3c4d5e6f';

  static const String _deviceType = 'urn:schemas-upnp-org:device:MediaRenderer:1';
  static const String _avtType = 'urn:schemas-upnp-org:service:AVTransport:1';
  static const String _cmType = 'urn:schemas-upnp-org:service:ConnectionManager:1';
  static const String _rcType = 'urn:schemas-upnp-org:service:RenderingControl:1';
  static const String _dialType = 'urn:dial-multiscreen-org:service:dial:1';

  HttpServer? _httpServer;
  Timer? _notifyTimer;
  Timer? _subTimer;

  /// 启动时缓存的局域网 IPv4（SSDP LOCATION / 设备描述都用它）
  String _cachedIp = '127.0.0.1';

  // ---------- 播放状态（SOAP 查询回读） ----------

  String _transportState = 'STOPPED'; // STOPPED / PLAYING / PAUSED
  String _currentUrl = '';
  bool _isVod = false;
  /// 本次投屏携带的请求头（由投出端随 SuikanHeaders 下发）。
  /// 自定义直播源靠它才能通过源站校验——TV 端按域名补头只覆盖虎牙/斗鱼等
  /// 几个平台，自定义源域名匹配不上就会裸请求被拒。
  /// m3u8 的分片请求 URL 与投屏 URL 不同，所以这里按"会话"保存而非按 URL。
  Map<String, String> _castHeaders = const {};
  String _currentTitle = '';
  String _currentMetaData = '';

  /// 当前投屏的 URL（供状态显示）
  final RxString currentUrl = ''.obs;

  bool get running => _httpServer != null;

  int get _httpPort => _httpServer?.port ?? 0;

  String get _localUrlBase => 'http://$_cachedIp:$_httpPort';

  /// 启动接收端服务。
  Future<void> start() async {
    await stop();
    _cachedIp = await _localIp();
    await _initLogDir();
    _transportState = 'STOPPED';
    // 1) HTTP 服务：设备描述 + SOAP 控制 + SCPD
    final handler = const shelf.Pipeline()
        .addMiddleware(shelf.logRequests())
        .addHandler(_handleHttp);
    _httpServer = await shelf_io.serve(
      handler,
      InternetAddress.anyIPv4,
      0,
    );
    // 端口确定后才能把投屏流包成本地代理地址（请求头由本进程补齐，
    // 绕开 mpv 自定义头失效导致的虎牙/斗鱼播几秒就断）。
    CastReceiverSite.proxyUrlBuilder = (String url) =>
        'http://127.0.0.1:$_httpPort/cast_stream?vod=${_isVod ? 1 : 0}&u='
        '${Uri.encodeComponent(url)}';

    // 2) SSDP：原生 MulticastSocket 共享 UDP 1900（盒子系统服务已占用该端口，
    //    Dart 层 RawDatagramSocket 无法 bind）。原生收到 M-SEARCH 后回调 onSearch，
    //    由 Dart 构造响应再经原生 send() 回包。
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'onSearch') {
        final st = call.arguments['st'] as String?;
        final ip = call.arguments['ip'] as String?;
        final port = call.arguments['port'] as int?;
        if (st != null && ip != null && port != null) {
          _replySsdp(st, ip, port);
        }
      } else if (call.method == 'onError') {
        // 原生 1900 绑定失败（系统服务独占且无法共享）——回退开关并提示
        final msg = call.arguments['message'] as String? ?? '未知错误';
        if (Get.isRegistered<AppSettingsController>()) {
          Get.find<AppSettingsController>().dlnaReceiverEnable.value = false;
        }
        // ignore: avoid_print
        print('DLNA 接收端启动失败: $msg');
      }
      return null;
    });
    try {
      await _channel.invokeMethod('start');
    } catch (e) {
      // 原生通道不可用（非常规平台），忽略——HTTP 仍可用作手动投屏。
    }

    // 3) 周期 NOTIFY alive（rootdevice / uuid / MediaRenderer 三条，经原生组播发出）
    _notifyTimer = Timer.periodic(const Duration(seconds: 10), (_) {
      _sendNotify();
    });
    await _sendNotify();
  }

  Future<void> stop() async {
    await _sendByebye();
    _notifyTimer?.cancel();
    _notifyTimer = null;
    _subTimer?.cancel();
    _subTimer = null;
    try {
      await _httpServer?.close(force: true);
    } catch (_) {}
    _httpServer = null;
    try {
      _channel.setMethodCallHandler(null);
      await _channel.invokeMethod('stop');
    } catch (_) {}
  }

  // ---------- HTTP ----------

  Future<shelf.Response> _handleHttp(shelf.Request request) async {
    _logRequest(request.method, request.url.path, request.headers['soapaction'] ?? '');
    // GENA 事件订阅：部分严格投屏端先 SUBSCRIBE 订阅状态变化再投屏，
    // 不实现会被判设备不可用（Cling 系完整接收端都有）。
    if (request.method == 'SUBSCRIBE') {
      return _subscribe(request);
    }
    if (request.method == 'UNSUBSCRIBE') {
      return _unsubscribe(request);
    }
    final path = request.url.path;
    if (path.isEmpty || path == 'device.xml' || path == 'device_description.xml') {
      return shelf.Response.ok(await _deviceXml(), headers: {
        'Content-Type': 'text/xml; charset=utf-8',
        'Server': _serverHeader(),
      });
    }
    // 投屏流本地代理：播放器请求本机地址，由本进程带 referer/UA 去拉真实流。
    if (path == 'cast_stream') {
      return _handleCastStream(request);
    }
    if (path == 'control/avtransport_scpd.xml') {
      return shelf.Response.ok(_avtScpdXml(), headers: {
        'Content-Type': 'text/xml; charset=utf-8',
      });
    }
    if (path == 'control/cm_scpd.xml') {
      return shelf.Response.ok(_cmScpdXml(), headers: {
        'Content-Type': 'text/xml; charset=utf-8',
      });
    }
    if (path == 'control/rendering_scpd.xml') {
      return shelf.Response.ok(_rcScpdXml(), headers: {
        'Content-Type': 'text/xml; charset=utf-8',
      });
    }
    // DIAL（安卓 B站/虎牙/腾讯视频等投屏协议）：REST 接口
    if (path == 'apps' || path == 'apps/') {
      if (request.method == 'GET') {
        return _dialAppsIndex();
      }
      if (request.method == 'POST') {
        // 投屏端 POST 视频 URL 启动播放
        final body = await request.readAsString();
        final url = body.trim();
        if (url.isNotEmpty) {
          _currentUrl = url;
          currentUrl.value = url;
          _play(url);
        }
        return shelf.Response(201);
      }
      return shelf.Response.notFound('Not Found');
    }
    if (path.startsWith('apps/')) {
      final appId = path.substring('apps/'.length);
      if (request.method == 'GET') {
        return _dialAppState(appId);
      }
      if (request.method == 'POST') {
        final body = await request.readAsString();
        final url = body.trim();
        if (url.isNotEmpty) {
          _currentUrl = url;
          currentUrl.value = url;
          _play(url);
        }
        return shelf.Response(201);
      }
      if (request.method == 'DELETE') {
        _doStop();
        return shelf.Response(200);
      }
      return shelf.Response.notFound('Not Found');
    }
    if (path.startsWith('control')) {
      final body = await request.readAsString();
      final soapAction = request.headers['soapaction'] ?? '';
      return _handleControl(soapAction, body);
    }
    return shelf.Response.notFound('Not Found');
  }

  String _serverHeader() => 'SuikanTV/2.1 UPnP/1.0 SuikanTV-DLNADOC/1.50';

  /// 诊断日志目录（app 私有目录，无存储权限问题；盒子 logcat 不稳，投屏排查用）。
  String _logDir = '';

  Future<void> _initLogDir() async {
    try {
      final dir = await getApplicationSupportDirectory();
      _logDir = dir.path;
    } catch (_) {}
  }

  void _logRequest(String method, String path, String extra) {
    if (_logDir.isEmpty) return;
    try {
      final f = File('$_logDir/suikan_dlna.log');
      f.writeAsStringSync(
        '${DateTime.now().toIso8601String()} $method $path $extra\n',
        mode: FileMode.append,
      );
    } catch (_) {}
  }

  // ---------- GENA 事件订阅 ----------

  /// 订阅者（callback URL + SID），投屏端 SUBSCRIBE 后靠 NOTIFY 推送状态变化。
  final Map<String, String> _subscribers = <String, String>{}; // sid -> callback
  int _eventSeq = 0;

  shelf.Response _subscribe(shelf.Request request) {
    final callback = request.headers['callback'] ?? '';
    final nt = request.headers['nt'] ?? '';
    if (callback.isEmpty || (nt.isNotEmpty && nt != 'upnp:event')) {
      return shelf.Response(412, body: 'Precondition Failed');
    }
    // callback 形如 <http://192.168.1.5:1234/notify>，提取 URL
    final m = RegExp(r'<([^>]+)>').firstMatch(callback);
    final url = m?.group(1);
    if (url == null) {
      return shelf.Response(412, body: 'Precondition Failed');
    }
    // 幂等：同一 callback 复用 SID
    String? sid = _subscribers.entries
        .where((e) => e.value == url)
        .map((e) => e.key)
        .firstOrNull;
    if (sid == null) {
      sid = 'uuid:${DateTime.now().microsecondsSinceEpoch.toRadixString(16)}';
      _subscribers[sid] = url;
    }
    return shelf.Response.ok('', headers: {
      'SID': sid,
      'TIMEOUT': 'Second-1800',
    });
  }

  shelf.Response _unsubscribe(shelf.Request request) {
    final sid = request.headers['sid'] ?? '';
    _subscribers.remove(sid);
    return shelf.Response.ok('');
  }

  /// 状态变化时向所有订阅者推送 NOTIFY（GENA propchange）。
  void _notifyEvent() {
    final state = _queryState();
    final body =
        '<?xml version="1.0"?>'
        '<e:propertyset xmlns:e="urn:schemas-upnp-org:event-1-0">'
        '<e:property><TransportState>$state</TransportState></e:property>'
        '<e:property><CurrentTransportActions>Play,Pause,Stop,Seek</CurrentTransportActions></e:property>'
        '</e:propertyset>';
    final seq = _eventSeq++;
    for (final entry in _subscribers.entries) {
      unawaited(_postNotify(entry.value, entry.key, seq, body));
    }
  }

  Future<void> _postNotify(
    String callback,
    String sid,
    int seq,
    String body,
  ) async {
    try {
      final uri = Uri.parse(callback);
      final client = HttpClient();
      try {
        final req = await client.postUrl(uri);
        req.headers.set('CONTENT-TYPE', 'text/xml; charset="utf-8"');
        req.headers.set('NT', 'upnp:event');
        req.headers.set('NTS', 'upnp:propchange');
        req.headers.set('SID', sid);
        req.headers.set('SEQ', '$seq');
        req.add(utf8.encode(body));
        await req.close().timeout(const Duration(seconds: 3));
      } finally {
        client.close();
      }
    } catch (_) {
      // 订阅者不在线，忽略（下次状态变化重试）
    }
  }

  // ---------- DIAL REST ----------

  shelf.Response _dialAppsIndex() {
    const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<service xmlns="urn:dial-multiscreen-org:schemas:2012:dial">
  <name>随看TV</name>
  <options allowStop="true"/>
</service>''';
    return shelf.Response.ok(xml, headers: {
      'Content-Type': 'application/xml; charset=utf-8',
    });
  }

  shelf.Response _dialAppState(String appId) {
    final xml = '''<?xml version="1.0" encoding="UTF-8"?>
<service xmlns="urn:dial-multiscreen-org:schemas:2012:dial">
  <name>$appId</name>
  <state>${_transportState == 'STOPPED' ? 'stopped' : 'running'}</state>
  <options allowStop="true"/>
</service>''';
    return shelf.Response.ok(xml, headers: {
      'Content-Type': 'application/xml; charset=utf-8',
    });
  }

  // ---------- 设备描述 ----------

  Future<String> _deviceXml() async {
    final ip = await _localIp();
    return '''<?xml version="1.0"?>
<root xmlns="urn:schemas-upnp-org:device-1-0"
      xmlns:dlna="urn:schemas-dlna-org:device-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <device>
    <deviceType>$_deviceType</deviceType>
    <friendlyName>随看TV</friendlyName>
    <manufacturer>Suikan</manufacturer>
    <manufacturerURL>https://github.com/mobingchong/suikan</manufacturerURL>
    <modelDescription>Suikan TV DLNA Media Renderer</modelDescription>
    <modelName>Suikan TV</modelName>
    <modelNumber>2.1.24</modelNumber>
    <modelURL>https://github.com/mobingchong/suikan</modelURL>
    <serialNumber>SuikanTV001</serialNumber>
    <UDN>$_uuid</UDN>
    <dlna:X_DLNADOC>DMR-1.50</dlna:X_DLNADOC>
    <dlna:X_DLNACAP>av-upload,av-play,av-pause,av-stop,av-seek</dlna:X_DLNACAP>
    <dial:additionalApplication xmlns:dial="urn:dial-multiscreen-org:schemas:2012:dial"
                                dial:appId="suikan.tv" dial:name="随看TV"/>
    <serviceList>
      <service>
        <serviceType>$_avtType</serviceType>
        <serviceId>urn:upnp-org:serviceId:AVTransport</serviceId>
        <controlURL>/control/avtransport</controlURL>
        <eventSubURL>/control/event</eventSubURL>
        <SCPDURL>/control/avtransport_scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>$_cmType</serviceType>
        <serviceId>urn:upnp-org:serviceId:ConnectionManager</serviceId>
        <controlURL>/control/cm</controlURL>
        <eventSubURL>/control/event</eventSubURL>
        <SCPDURL>/control/cm_scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>$_rcType</serviceType>
        <serviceId>urn:upnp-org:serviceId:RenderingControl</serviceId>
        <controlURL>/control/rendering</controlURL>
        <eventSubURL>/control/event</eventSubURL>
        <SCPDURL>/control/rendering_scpd.xml</SCPDURL>
      </service>
      <service>
        <serviceType>$_dialType</serviceType>
        <serviceId>urn:dial-multiscreen-org:serviceId:dial</serviceId>
        <controlURL>/apps</controlURL>
        <eventSubURL>/apps</eventSubURL>
        <SCPDURL></SCPDURL>
      </service>
    </serviceList>
    <presentationURL>http://$ip:$_httpPort/</presentationURL>
  </device>
</root>''';
  }

  // ---------- SCPD 能力文档 ----------

  String _avtScpdXml() {
    return '''<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>SetAVTransportURI</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>CurrentURI</name><direction>in</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
        <argument><name>CurrentURIMetaData</name><direction>in</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>SetNextAVTransportURI</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>NextURI</name><direction>in</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
        <argument><name>NextURIMetaData</name><direction>in</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>Play</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Speed</name><direction>in</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>Pause</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>Stop</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>Seek</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Unit</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekMode</relatedStateVariable></argument>
        <argument><name>Target</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_SeekTarget</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>Next</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>Previous</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetTransportInfo</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>CurrentTransportState</name><direction>out</direction><relatedStateVariable>TransportState</relatedStateVariable></argument>
        <argument><name>CurrentTransportStatus</name><direction>out</direction><relatedStateVariable>TransportStatus</relatedStateVariable></argument>
        <argument><name>CurrentSpeed</name><direction>out</direction><relatedStateVariable>TransportPlaySpeed</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetPositionInfo</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Track</name><direction>out</direction><relatedStateVariable>CurrentTrack</relatedStateVariable></argument>
        <argument><name>TrackDuration</name><direction>out</direction><relatedStateVariable>CurrentTrackDuration</relatedStateVariable></argument>
        <argument><name>TrackMetaData</name><direction>out</direction><relatedStateVariable>CurrentTrackMetaData</relatedStateVariable></argument>
        <argument><name>TrackURI</name><direction>out</direction><relatedStateVariable>CurrentTrackURI</relatedStateVariable></argument>
        <argument><name>RelTime</name><direction>out</direction><relatedStateVariable>RelativeTimePosition</relatedStateVariable></argument>
        <argument><name>AbsTime</name><direction>out</direction><relatedStateVariable>AbsoluteTimePosition</relatedStateVariable></argument>
        <argument><name>RelCount</name><direction>out</direction><relatedStateVariable>RelativeCounterPosition</relatedStateVariable></argument>
        <argument><name>AbsCount</name><direction>out</direction><relatedStateVariable>AbsoluteCounterPosition</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetDeviceCapabilities</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>PlayMedia</name><direction>out</direction><relatedStateVariable>PossiblePlaybackStorageMedia</relatedStateVariable></argument>
        <argument><name>RecMedia</name><direction>out</direction><relatedStateVariable>PossibleRecordStorageMedia</relatedStateVariable></argument>
        <argument><name>RecQualityModes</name><direction>out</direction><relatedStateVariable>PossibleRecordQualityModes</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetTransportSettings</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>PlayMode</name><direction>out</direction><relatedStateVariable>CurrentPlayMode</relatedStateVariable></argument>
        <argument><name>RecQualityMode</name><direction>out</direction><relatedStateVariable>CurrentRecordQualityMode</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetMediaInfo</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>NrTracks</name><direction>out</direction><relatedStateVariable>NumberOfTracks</relatedStateVariable></argument>
        <argument><name>MediaDuration</name><direction>out</direction><relatedStateVariable>CurrentMediaDuration</relatedStateVariable></argument>
        <argument><name>CurrentURI</name><direction>out</direction><relatedStateVariable>AVTransportURI</relatedStateVariable></argument>
        <argument><name>CurrentURIMetaData</name><direction>out</direction><relatedStateVariable>AVTransportURIMetaData</relatedStateVariable></argument>
        <argument><name>NextURI</name><direction>out</direction><relatedStateVariable>NextAVTransportURI</relatedStateVariable></argument>
        <argument><name>NextURIMetaData</name><direction>out</direction><relatedStateVariable>NextAVTransportURIMetaData</relatedStateVariable></argument>
        <argument><name>PlayMedium</name><direction>out</direction><relatedStateVariable>PlaybackStorageMedium</relatedStateVariable></argument>
        <argument><name>RecordMedium</name><direction>out</direction><relatedStateVariable>RecordStorageMedium</relatedStateVariable></argument>
        <argument><name>WriteStatus</name><direction>out</direction><relatedStateVariable>RecordMediumWriteStatus</relatedStateVariable></argument>
      </argumentList>
    </action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekMode</name><dataType>string</dataType>
      <allowedValueList><allowedValue>ABS_TIME</allowedValue><allowedValue>REL_TIME</allowedValue><allowedValue>TRACK_NR</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_SeekTarget</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>TransportState</name><dataType>string</dataType>
      <allowedValueList><allowedValue>STOPPED</allowedValue><allowedValue>PLAYING</allowedValue><allowedValue>TRANSITIONING</allowedValue><allowedValue>PAUSED_PLAYBACK</allowedValue><allowedValue>PAUSED_RECORDING</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>TransportStatus</name><dataType>string</dataType>
      <allowedValueList><allowedValue>OK</allowedValue><allowedValue>ERROR_OCCURRED</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>TransportPlaySpeed</name><dataType>string</dataType>
      <allowedValueList><allowedValue>1</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>AVTransportURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>AVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>NextAVTransportURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>NextAVTransportURIMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrack</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackDuration</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackMetaData</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentTrackURI</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RelativeTimePosition</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AbsoluteTimePosition</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>RelativeCounterPosition</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>AbsoluteCounterPosition</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>CurrentPlayMode</name><dataType>string</dataType>
      <allowedValueList><allowedValue>NORMAL</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>CurrentRecordQualityMode</name><dataType>string</dataType>
      <allowedValueList><allowedValue>NOT_IMPLEMENTED</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>NumberOfTracks</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>CurrentMediaDuration</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>PlaybackStorageMedium</name><dataType>string</dataType>
      <allowedValueList><allowedValue>NETWORK</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>RecordStorageMedium</name><dataType>string</dataType>
      <allowedValueList><allowedValue>NOT_IMPLEMENTED</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>RecordMediumWriteStatus</name><dataType>string</dataType>
      <allowedValueList><allowedValue>NOT_IMPLEMENTED</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>PossiblePlaybackStorageMedia</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>PossibleRecordStorageMedia</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>PossibleRecordQualityModes</name><dataType>string</dataType></stateVariable>
  </serviceStateTable>
</scpd>''';
  }

  String _cmScpdXml() {
    return '''<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>GetProtocolInfo</name>
      <argumentList>
        <argument><name>Source</name><direction>out</direction><relatedStateVariable>SourceProtocolInfo</relatedStateVariable></argument>
        <argument><name>Sink</name><direction>out</direction><relatedStateVariable>SinkProtocolInfo</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetCurrentConnectionIDs</name>
      <argumentList>
        <argument><name>ConnectionIDs</name><direction>out</direction><relatedStateVariable>CurrentConnectionIDs</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetCurrentConnectionInfo</name>
      <argumentList>
        <argument><name>ConnectionID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
        <argument><name>RcsID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_RcsID</relatedStateVariable></argument>
        <argument><name>AVTransportID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_AVTransportID</relatedStateVariable></argument>
        <argument><name>ProtocolInfo</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ProtocolInfo</relatedStateVariable></argument>
        <argument><name>PeerConnectionManager</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionManager</relatedStateVariable></argument>
        <argument><name>PeerConnectionID</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionID</relatedStateVariable></argument>
        <argument><name>Direction</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_Direction</relatedStateVariable></argument>
        <argument><name>Status</name><direction>out</direction><relatedStateVariable>A_ARG_TYPE_ConnectionStatus</relatedStateVariable></argument>
      </argumentList>
    </action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>SourceProtocolInfo</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>SinkProtocolInfo</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>CurrentConnectionIDs</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionStatus</name><dataType>string</dataType>
      <allowedValueList><allowedValue>OK</allowedValue><allowedValue>ContentFormatMismatch</allowedValue><allowedValue>InsufficientBandwidth</allowedValue><allowedValue>UnreliableChannel</allowedValue><allowedValue>Unknown</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionManager</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_Direction</name><dataType>string</dataType>
      <allowedValueList><allowedValue>Input</allowedValue><allowedValue>Output</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ProtocolInfo</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_ConnectionID</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_AVTransportID</name><dataType>i4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_RcsID</name><dataType>i4</dataType></stateVariable>
  </serviceStateTable>
</scpd>''';
  }

  String _rcScpdXml() {
    return '''<?xml version="1.0"?>
<scpd xmlns="urn:schemas-upnp-org:service-1-0">
  <specVersion><major>1</major><minor>0</minor></specVersion>
  <actionList>
    <action><name>GetVolume</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>Channel</relatedStateVariable></argument>
        <argument><name>CurrentVolume</name><direction>out</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>SetVolume</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>Channel</relatedStateVariable></argument>
        <argument><name>DesiredVolume</name><direction>in</direction><relatedStateVariable>Volume</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>GetMute</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>Channel</relatedStateVariable></argument>
        <argument><name>CurrentMute</name><direction>out</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>SetMute</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>Channel</name><direction>in</direction><relatedStateVariable>Channel</relatedStateVariable></argument>
        <argument><name>DesiredMute</name><direction>in</direction><relatedStateVariable>Mute</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>ListPresets</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>CurrentPresetNameList</name><direction>out</direction><relatedStateVariable>PresetNameList</relatedStateVariable></argument>
      </argumentList>
    </action>
    <action><name>SelectPreset</name>
      <argumentList>
        <argument><name>InstanceID</name><direction>in</direction><relatedStateVariable>A_ARG_TYPE_InstanceID</relatedStateVariable></argument>
        <argument><name>PresetName</name><direction>in</direction><relatedStateVariable>PresetName</relatedStateVariable></argument>
      </argumentList>
    </action>
  </actionList>
  <serviceStateTable>
    <stateVariable sendEvents="no"><name>A_ARG_TYPE_InstanceID</name><dataType>ui4</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>Channel</name><dataType>string</dataType>
      <allowedValueList><allowedValue>Master</allowedValue><allowedValue>LF</allowedValue><allowedValue>RF</allowedValue></allowedValueList>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>Volume</name><dataType>ui2</dataType>
      <allowedValueRange><minimum>0</minimum><maximum>100</maximum><step>1</step></allowedValueRange>
    </stateVariable>
    <stateVariable sendEvents="yes"><name>Mute</name><dataType>boolean</dataType></stateVariable>
    <stateVariable sendEvents="yes"><name>PresetNameList</name><dataType>string</dataType></stateVariable>
    <stateVariable sendEvents="no"><name>PresetName</name><dataType>string</dataType></stateVariable>
  </serviceStateTable>
</scpd>''';
  }

  // ---------- SOAP 控制 ----------

  /// 解析 SOAPACTION 头（如 "urn:schemas-upnp-org:service:AVTransport:1#SetAVTransportURI"）
  Future<shelf.Response> _handleControl(String soapAction, String body) async {
    final action = _soapActionName(soapAction, body);
    final service = _soapService(soapAction, body);
    _logRequest('SOAP', action ?? '?', body.substring(0, body.length > 200 ? 200 : body.length));
    try {
      switch (action) {
        // ---- AVTransport ----
        case 'SetAVTransportURI':
          return _avtResponse(
            service,
            'SetAVTransportURIResponse',
            onSuccess: () async {
              final uri = _xmlArg(body, 'CurrentURI') ?? '';
              final metaData = _xmlArg(body, 'CurrentURIMetaData') ?? '';
              // 投屏端（随看）会带类型标记：点播才显示进度条/允许拖动进度。
              final castType =
                  (_xmlArg(body, 'SuikanCastType') ?? '').toLowerCase();
              final isVod = castType == 'vod';
              // 投出端直推原 URL 时会把自定义请求头一起带过来；没带就清空，
              // 避免上一次投屏（自定义源）的头污染下一次（平台直播）。
              _castHeaders = _parseCastHeaders(_xmlArg(body, 'SuikanHeaders'));
              if (uri.isNotEmpty) {
                _currentUrl = uri;
                _currentMetaData = metaData;
                _currentTitle = _extractTitle(metaData) ?? '';
                currentUrl.value = uri;
                _play(uri, title: _currentTitle, isVod: isVod);
              }
            },
          );
        case 'Play':
          return _avtResponse(service, 'PlayResponse', onSuccess: _doPlay);
        case 'Pause':
          return _avtResponse(service, 'PauseResponse', onSuccess: _doPause);
        case 'Stop':
          return _avtResponse(service, 'StopResponse', onSuccess: _doStop);
        case 'Seek':
          return _avtResponse(
            service,
            'SeekResponse',
            onSuccess: () async {
              final target = _xmlArg(body, 'Target') ?? '';
              final secs = _parseDlnaTime(target);
              if (secs >= 0) _doSeek(secs);
            },
          );
        case 'Next':
          return _avtResponse(service, 'NextResponse');
        case 'Previous':
          return _avtResponse(service, 'PreviousResponse');
        case 'GetTransportInfo':
          return _avtResponse(
            service,
            'GetTransportInfoResponse',
            inner: '<CurrentTransportState>${_queryState()}</CurrentTransportState>'
                '<CurrentTransportStatus>OK</CurrentTransportStatus>'
                '<CurrentSpeed>1</CurrentSpeed>',
          );
        case 'GetPositionInfo':
          final pos = _queryPosition();
          return _avtResponse(
            service,
            'GetPositionInfoResponse',
            inner: '<Track>0</Track>'
                '<TrackDuration>${_fmtDlnaTime(pos.duration)}</TrackDuration>'
                '<TrackMetaData>${_xmlEscape(_currentMetaData)}</TrackMetaData>'
                '<TrackURI>${_xmlEscape(_currentUrl)}</TrackURI>'
                '<RelTime>${_fmtDlnaTime(pos.position)}</RelTime>'
                '<AbsTime>${_fmtDlnaTime(pos.position)}</AbsTime>'
                '<RelCount>2147483647</RelCount>'
                '<AbsCount>2147483647</AbsCount>',
          );
        case 'GetDeviceCapabilities':
          return _avtResponse(
            service,
            'GetDeviceCapabilitiesResponse',
            inner: '<PlayMedia>NETWORK</PlayMedia>'
                '<RecMedia>NOT_IMPLEMENTED</RecMedia>'
                '<RecQualityModes>NOT_IMPLEMENTED</RecQualityModes>',
          );
        case 'GetTransportSettings':
          return _avtResponse(
            service,
            'GetTransportSettingsResponse',
            inner: '<PlayMode>NORMAL</PlayMode>'
                '<RecQualityMode>NOT_IMPLEMENTED</RecQualityMode>',
          );
        case 'GetMediaInfo':
          final duration = _queryPosition().duration;
          return _avtResponse(
            service,
            'GetMediaInfoResponse',
            inner: '<NrTracks>1</NrTracks>'
                '<MediaDuration>${_fmtDlnaTime(duration)}</MediaDuration>'
                '<CurrentURI>${_xmlEscape(_currentUrl)}</CurrentURI>'
                '<CurrentURIMetaData>${_xmlEscape(_currentMetaData)}</CurrentURIMetaData>'
                '<NextURI>NOT_IMPLEMENTED</NextURI>'
                '<NextURIMetaData>NOT_IMPLEMENTED</NextURIMetaData>'
                '<PlayMedium>NETWORK</PlayMedium>'
                '<RecordMedium>NOT_IMPLEMENTED</RecordMedium>'
                '<WriteStatus>NOT_IMPLEMENTED</WriteStatus>',
          );

        // ---- ConnectionManager ----
        case 'GetProtocolInfo':
          return _cmResponse(
            service,
            'GetProtocolInfoResponse',
            inner: '<Source>http-get:*:video/mp4:*,http-get:*:video/x-matroska:*,http-get:*:video/webm:*,http-get:*:application/vnd.apple.mpegurl:*,http-get:*:application/x-mpegURL:*,http-get:*:video/mp2t:*,http-get:*:audio/mpeg:*,http-get:*:audio/mp4:*,http-get:*:audio/aac:*,http-get:*:video/*:*,http-get:*:audio/*:*</Source>'
                '<Sink>http-get:*:video/*:*,http-get:*:audio/*:*,http-get:*:image/*:*</Sink>',
          );
        case 'GetCurrentConnectionIDs':
          return _cmResponse(
            service,
            'GetCurrentConnectionIDsResponse',
            inner: '<ConnectionIDs>0</ConnectionIDs>',
          );
        case 'GetCurrentConnectionInfo':
          return _cmResponse(
            service,
            'GetCurrentConnectionInfoResponse',
            inner: '<RcsID>0</RcsID>'
                '<AVTransportID>0</AVTransportID>'
                '<ProtocolInfo>http-get:*:video/*:*</ProtocolInfo>'
                '<PeerConnectionManager>NOT_IMPLEMENTED</PeerConnectionManager>'
                '<PeerConnectionID>-1</PeerConnectionID>'
                '<Direction>Input</Direction>'
                '<Status>OK</Status>',
          );

        // ---- RenderingControl ----
        case 'GetVolume':
          return _rcResponse(
            service,
            'GetVolumeResponse',
            inner: '<CurrentVolume>${_queryVolume()}</CurrentVolume>',
          );
        case 'SetVolume':
          final v = int.tryParse(_xmlArg(body, 'DesiredVolume') ?? '') ?? -1;
          if (v >= 0) _setVolume(v);
          return _rcResponse(service, 'SetVolumeResponse');
        case 'GetMute':
          return _rcResponse(
            service,
            'GetMuteResponse',
            inner: '<CurrentMute>${_queryMute() ? 1 : 0}</CurrentMute>',
          );
        case 'SetMute':
          final m = _xmlArg(body, 'DesiredMute') == '1';
          _setMute(m);
          return _rcResponse(service, 'SetMuteResponse');
        case 'ListPresets':
          return _rcResponse(
            service,
            'ListPresetsResponse',
            inner: '<CurrentPresetNameList>FactoryDefaults</CurrentPresetNameList>',
          );
        case 'SelectPreset':
          return _rcResponse(service, 'SelectPresetResponse');

        default:
          return _fault(service, 'InvalidAction');
      }
    } catch (e) {
      return _fault(service, 'ActionFailed', detail: '$e');
    }
  }

  String? _soapActionName(String soapAction, String body) {
    // SOAPACTION: "urn:...#ActionName"
    final m = RegExp('#([^"]+)"?\$', caseSensitive: false)
        .firstMatch(soapAction.trim());
    if (m != null) return m.group(1);
    // 回退：从 body 的 <u:ActionName 提取
    final m2 = RegExp(r'<u:(\w+)\b', caseSensitive: false).firstMatch(body);
    if (m2 != null) return m2.group(1);
    return null;
  }

  String _soapService(String soapAction, String body) {
    if (soapAction.contains('RenderingControl')) return _rcType;
    if (soapAction.contains('ConnectionManager')) return _cmType;
    if (soapAction.contains('AVTransport')) return _avtType;
    // 回退：从 body 的 xmlns:u= 提取
    final m = RegExp('xmlns:u="([^"]+)"').firstMatch(body);
    if (m != null) return m.group(1)!;
    return _avtType;
  }

  shelf.Response _avtResponse(String service, String action,
      {String inner = '', Future<void> Function()? onSuccess}) {
    return _soapResponse(service, action, inner: inner, onSuccess: onSuccess);
  }

  shelf.Response _cmResponse(String service, String action,
      {String inner = ''}) {
    return _soapResponse(service, action, inner: inner);
  }

  shelf.Response _rcResponse(String service, String action,
      {String inner = ''}) {
    return _soapResponse(service, action, inner: inner);
  }

  shelf.Response _soapResponse(String service, String action,
      {String inner = '', Future<void> Function()? onSuccess}) {
    if (onSuccess != null) {
      unawaited(onSuccess());
    }
    final xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <u:$action xmlns:u="$service">$inner</u:$action>
  </s:Body>
</s:Envelope>''';
    return shelf.Response.ok(xml, headers: {
      'Content-Type': 'text/xml; charset="utf-8"',
      'EXT': '',
    });
  }

  shelf.Response _fault(String service, String code, {String detail = ''}) {
    final xml = '''<?xml version="1.0" encoding="utf-8"?>
<s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/" s:encodingStyle="http://schemas.xmlsoap.org/soap/encoding/">
  <s:Body>
    <s:Fault>
      <faultcode>s:Client</faultcode>
      <faultstring>UPnPError</faultstring>
      <detail>
        <UPnPError xmlns="urn:schemas-upnp-org:control-1-0">
          <errorCode>402</errorCode>
          <errorDescription>$code $detail</errorDescription>
        </UPnPError>
      </detail>
    </s:Fault>
  </s:Body>
</s:Envelope>''';
    return shelf.Response(500, body: xml, headers: {
      'Content-Type': 'text/xml; charset="utf-8"',
    });
  }

  // ---------- 播放器联动 ----------

  LiveRoomController? _liveRoom() {
    if (Get.isRegistered<LiveRoomController>()) {
      return Get.find<LiveRoomController>();
    }
    return null;
  }

  Future<void> _doPlay() async {
    _transportState = 'PLAYING';
    _notifyEvent();
    final c = _liveRoom();
    if (c != null) {
      try {
        await c.player.play();
      } catch (_) {}
    }
  }

  Future<void> _doPause() async {
    _transportState = 'PAUSED';
    _notifyEvent();
    final c = _liveRoom();
    if (c != null) {
      try {
        await c.player.pause();
      } catch (_) {}
    }
  }

  Future<void> _doStop() async {
    _transportState = 'STOPPED';
    _notifyEvent();
    final c = _liveRoom();
    if (c != null) {
      try {
        await c.player.stop();
      } catch (_) {}
    }
  }

  Future<void> _doSeek(int seconds) async {
    final c = _liveRoom();
    if (c != null) {
      try {
        await c.player.seek(Duration(seconds: seconds));
      } catch (_) {}
    }
  }

  Future<void> _setVolume(int volume) async {
    final v = volume.clamp(0, 100);
    final c = _liveRoom();
    if (c != null) {
      try {
        await c.player.setVolume(v.toDouble());
        c.muted.value = v == 0;
      } catch (_) {}
    }
  }

  Future<void> _setMute(bool mute) async {
    final c = _liveRoom();
    if (c != null) {
      try {
        c.muted.value = mute;
        await c.player.setVolume(mute ? 0 : 100);
      } catch (_) {}
    }
  }

  String _queryState() {
    final c = _liveRoom();
    if (c != null) {
      try {
        if (c.player.state.playing) return 'PLAYING';
        if (_transportState == 'PAUSED') return 'PAUSED_PLAYBACK';
        return _transportState;
      } catch (_) {}
    }
    return _transportState;
  }

  ({Duration position, Duration duration}) _queryPosition() {
    final c = _liveRoom();
    if (c != null) {
      try {
        return (
          position: c.player.state.position,
          duration: c.player.state.duration,
        );
      } catch (_) {}
    }
    return (position: Duration.zero, duration: Duration.zero);
  }

  int _queryVolume() {
    final c = _liveRoom();
    if (c != null) {
      try {
        return c.player.state.volume.round().clamp(0, 100);
      } catch (_) {}
    }
    return 50;
  }

  bool _queryMute() {
    final c = _liveRoom();
    if (c != null) {
      try {
        return c.player.state.volume <= 0.5;
      } catch (_) {}
    }
    return false;
  }

  // ---------- 播放对接 ----------

  /// 播放器侧按总时长补判为点播后回调：把当前投屏升级成点播态。
  ///
  /// 第三方投屏端（飞牛影视等）不发 SuikanCastType，进来时一律按直播处理，
  /// 代理地址也就带着 vod=0（屏蔽 Range）。播起来后播放器按 duration 认出是
  /// 点播，必须在这里同步标记，否则代理不放行 Range → 拖动进度无效。
  void markVodDetected() {
    if (_isVod) return;
    _isVod = true;
    Log.i('投屏内容已补判为点播，代理开放 Range（支持拖动进度）');
  }

  /// 投屏接收专用 Site：roomId=URL 直接播 + 按域名补 referer/UA。
  Site _castSite() => Site(
        id: 'cast_receiver',
        name: '投屏接收',
        logo: '',
        liveSite: CastReceiverSite(),
      );

  void _play(String url, {String title = '', bool isVod = false}) {
    _currentUrl = url;
    currentUrl.value = url;
    _isVod = isVod;
    _transportState = 'PLAYING';
    _notifyEvent();
    // 已有投屏页面（本页或其它投屏端投的）在播：原地切换播放——
    // 同一播放器换源，新投屏全面顶掉旧投屏（旧流先 stop，不会双声音）。
    // 必须传 newSite（CastReceiverSite）：否则复用旧站点解析 URL 会失败，
    // 误报"未开播"（虎牙/斗鱼投屏黑屏的根因）。
    final c = _liveRoom();
    if (c != null) {
      unawaited(c.switchRoom(url, newSite: _castSite(), newIsVod: isVod));
      return;
    }
    // 无投屏页面：新建直播间页开播
    AppNavigator.toLiveRoomDetail(
      site: _castSite(),
      roomId: url,
      isVod: isVod,
    );
  }

  // ---------- SSDP ----------

  /// 原生收到 M-SEARCH 后回调：构造标准响应并经原生 socket 回包。
  void _replySsdp(String st, String ip, int port) {
    final respSt = _matchSearchTarget(st);
    if (respSt == null) return;
    final usn = respSt == _uuid ? _uuid : '$_uuid::$respSt';
    final body =
        'HTTP/1.1 200 OK\r\n'
        'CACHE-CONTROL: max-age=1800\r\n'
        'DATE: ${HttpDate.format(DateTime.now().toUtc())}\r\n'
        'EXT:\r\n'
        'LOCATION: $_localUrlBase/device.xml\r\n'
        'SERVER: ${_serverHeader()}\r\n'
        'ST: $respSt\r\n'
        'USN: $usn\r\n'
        'BOOTID.UPNP.ORG: 1\r\n'
        '\r\n';
    _channelSend(ip, port, body);
  }

  /// 判断 M-SEARCH 的 ST 是否命中本设备；命中返回应响应的 ST，未命中返回 null。
  String? _matchSearchTarget(String st) {
    if (st == 'ssdp:all') return 'upnp:rootdevice';
    if (st == 'upnp:rootdevice') return 'upnp:rootdevice';
    if (st == _uuid) return _uuid;
    if (st == _deviceType) return _deviceType;
    if (st == _avtType) return _avtType;
    if (st == _cmType) return _cmType;
    if (st == _rcType) return _rcType;
    if (st == _dialType) return _dialType;
    // 部分端会搜 通配 的 MediaRenderer
    if (st.startsWith('urn:schemas-upnp-org:device:MediaRenderer')) {
      return _deviceType;
    }
    return null;
  }

  void _channelSend(String ip, int port, String body) {
    try {
      _channel.invokeMethod(
        'send',
        {'ip': ip, 'port': port, 'data': body},
      );
    } catch (_) {}
  }

  Future<void> _sendNotify() async {
    const nts = 'ssdp:alive';
    final targets = <String>[
      'upnp:rootdevice',
      _uuid,
      _deviceType,
      _dialType,
    ];
    for (final nt in targets) {
      final usn = nt == _uuid ? _uuid : '$_uuid::$nt';
      final body =
          'NOTIFY * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'CACHE-CONTROL: max-age=1800\r\n'
          'LOCATION: $_localUrlBase/device.xml\r\n'
          'NT: $nt\r\n'
          'NTS: $nts\r\n'
          'SERVER: ${_serverHeader()}\r\n'
          'USN: $usn\r\n'
          'BOOTID.UPNP.ORG: 1\r\n'
          '\r\n';
      _channelSend(_ssdpAddress, _ssdpPort, body);
    }
  }

  Future<void> _sendByebye() async {
    const nts = 'ssdp:byebye';
    final targets = <String>[
      'upnp:rootdevice',
      _uuid,
      _deviceType,
      _dialType,
    ];
    for (final nt in targets) {
      final usn = nt == _uuid ? _uuid : '$_uuid::$nt';
      final body =
          'NOTIFY * HTTP/1.1\r\n'
          'HOST: $_ssdpAddress:$_ssdpPort\r\n'
          'NT: $nt\r\n'
          'NTS: $nts\r\n'
          'SERVER: ${_serverHeader()}\r\n'
          'USN: $usn\r\n'
          '\r\n';
      _channelSend(_ssdpAddress, _ssdpPort, body);
    }
  }

  // ---------- 工具 ----------

  /// 投屏流本地代理：播放器请求本机地址，本进程带 referer/UA 去拉真实流，
  /// 流式转发回去。
  ///
  /// 为什么要绕一圈：直连时请求头由 mpv 发送，依赖 media_kit 在 on_load 钩子
  /// 里按 URI 查缓存回写 `http-header-fields`，投屏场景偶发不生效；虎牙/斗鱼
  /// 这类校验严格 CDN 缺头会先吐几秒数据再掐断，表现为"播 1~2 秒就播放失败"。
  /// 走代理后请求头完全由本进程控制，且能记录源站状态码便于定位。
  Future<shelf.Response> _handleCastStream(shelf.Request request) async {
    final target = request.url.queryParameters['u'] ?? '';
    final uri = Uri.tryParse(target);
    if (target.isEmpty || uri == null) {
      return shelf.Response.badRequest(body: 'missing url');
    }
    final headers = <String, String>{
      'User-Agent': CastReceiverSite.ua,
      'Accept': '*/*',
    };
    final extra = CastReceiverSite.headersFor(target);
    if (extra != null) headers.addAll(extra);
    // 投出端随投屏下发的自定义头优先级最高：按域名补头只覆盖虎牙/斗鱼等平台，
    // 自定义源域名匹配不上时只有这些头能让源站放行。
    if (_castHeaders.isNotEmpty) headers.addAll(_castHeaders);

    final client = HttpClient();
    client.connectionTimeout = const Duration(seconds: 10);
    // 必须关掉自动解压：默认 autoUncompress=true 会让 Dart 尝试按 gzip 处理
    // 响应体，对 FLV 这类二进制直播流会导致数据被缓冲/提前结束（实测代理
    // 0.7 秒就 EOF，直连却能稳定 25 秒）。流式转发必须原样透传字节。
    client.autoUncompress = false;
    try {
      // 点播（影视库）需要支持拖动进度：转发 Range 并保留 Accept-Ranges/
      // Content-Range；直播则必须屏蔽（分段返回会被播放器当成播完）。
      //
      // 这里读**服务的实时标记**而不是 URL 里烘焙的 vod 参数：第三方投屏进来
      // 时 isVod 是 false，代理地址生成时就固定带上了 vod=0；等播放器按总时长
      // 补判出点播再回头改标记，URL 并不会重新生成 —— 只有读实时标记才能让
      // 代理跟上"后知后觉的点播"，Range 得以放行。
      final isVod = _isVod;
      final req = await client.openUrl('GET', uri);
      headers.forEach((k, v) => req.headers.set(k, v));
      if (isVod) {
        final range = request.headers[HttpHeaders.rangeHeader];
        if (range != null) {
          req.headers.set(HttpHeaders.rangeHeader, range);
        }
      }
      // 关键：明确要求源站不要压缩。Dart HttpClient 默认带
      // `Accept-Encoding: gzip`，CDN 会返回压缩后的流，而代理是原样转发字节的，
      // 转发时又不能带 content-encoding（长度未知、且播放器会按流式解析）→
      // 播放器收到 gzip 数据却不知道要解压 → 播几秒就"播放失败"。
      // 要求 identity（不压缩），转发链路上的字节即源站原始字节。
      req.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final resp = await req.close();
      Log.i('投屏代理 ${uri.host} → ${resp.statusCode}');

      // HLS 播放列表必须改写后才能转发：m3u8 里的分片大量写成相对路径
      // （如 `segment001.ts`、`720p/index.m3u8`），原样转发的话播放器会拿
      // **代理地址**当基准去拼 → 拼出 http://127.0.0.1:<port>/xxx.ts 必然 404，
      // 表现就是"自定义直播源一投屏就直接出错"。
      // 虎牙/斗鱼/抖音等平台直播是 FLV 单流，没有播放列表，所以这个问题
      // 只在自定义源（M3U 里绝大多数是 HLS）上暴露。
      if (_isHlsPlaylist(target, resp.headers.contentType)) {
        final rewritten = await _rewriteHlsPlaylist(resp, uri);
        client.close();
        if (rewritten != null) {
          Log.i('投屏代理 HLS 列表已改写 ${uri.host}');
          return shelf.Response(
            resp.statusCode,
            body: rewritten,
            headers: const {
              'content-type': 'application/vnd.apple.mpegurl',
              'cache-control': 'no-cache',
            },
          );
        }
        // 改写失败（超大/编码异常）：内容已被读走，无法再流式转发，
        // 只能报错，避免返回半截数据让播放器更难排查。
        return shelf.Response.internalServerError(
          body: 'playlist rewrite failed',
        );
      }

      // 流结束/播放器断开时释放上游连接（直播是长连接，停止播放才触发）
      final out = StreamController<List<int>>();
      final up = resp.listen(
        out.add,
        onError: out.addError,
        onDone: () {
          unawaited(out.close());
          client.close();
        },
        cancelOnError: true,
      );
      out.onCancel = () {
        unawaited(up.cancel());
        client.close();
      };
      final outHeaders = <String, Object>{};
      resp.headers.forEach((name, values) {
        switch (name.toLowerCase()) {
          case 'connection':
          case 'transfer-encoding':
          case 'content-length':
          case 'content-encoding':
            break;
          // 直播不可 seek：屏蔽 Range 相关头，避免 mpv 把分段当成整个资源
          // （播完一段就结束）。点播保留，供拖动进度使用。
          case 'accept-ranges':
          case 'content-range':
            if (!isVod) break;
            outHeaders[name] = values.join(', ');
            break;
          default:
            outHeaders[name] = values.join(', ');
        }
      });
      return shelf.Response(
        resp.statusCode,
        body: out.stream,
        headers: outHeaders,
        context: const {'shelf.io.buffer_output': false},
      );
    } catch (e, s) {
      client.close();
      Log.e('投屏代理失败：$target $e', s);
      return shelf.Response.internalServerError(body: 'proxy error: $e');
    }
  }

  /// m3u8 改写体积上限：播放列表正常只有几 KB～几十 KB，超过这个量级
  /// 基本可以断定不是真正的播放列表（或被伪造成 .m3u8 的流），不再改写。
  static const int _maxPlaylistBytes = 4 * 1024 * 1024;

  /// 判断响应是否为 HLS 播放列表（m3u8）。
  /// 自定义源常不带规范 content-type，所以同时看 URL 后缀。
  bool _isHlsPlaylist(String url, ContentType? contentType) {
    final path = Uri.tryParse(url)?.path.toLowerCase() ?? '';
    if (path.endsWith('.m3u8')) return true;
    final mime = contentType?.mimeType.toLowerCase() ?? '';
    return mime == 'application/vnd.apple.mpegurl' ||
        mime == 'application/x-mpegurl' ||
        mime == 'audio/mpegurl' ||
        mime == 'audio/x-mpegurl';
  }

  /// 把 m3u8 中的分片/嵌套列表地址全部改写成"经本代理"的绝对地址。
  /// [base] 是该 m3u8 自身的 URL——相对地址必须以它为基准解析。
  Future<String?> _rewriteHlsPlaylist(HttpClientResponse resp, Uri base) async {
    try {
      final buffer = <int>[];
      await for (final chunk in resp) {
        buffer.addAll(chunk);
        if (buffer.length > _maxPlaylistBytes) return null;
      }
      final text = utf8.decode(buffer, allowMalformed: true);
      final out = StringBuffer();
      for (final rawLine in text.split(RegExp(r'\r?\n'))) {
        final line = rawLine.trim();
        if (line.isEmpty) {
          out.writeln();
        } else if (line.startsWith('#')) {
          // 标签里也可能带 URI（如 #EXT-X-KEY 的密钥、#EXT-X-MAP 的初始化段）
          out.writeln(_rewritePlaylistTagUri(line, base));
        } else {
          out.writeln(_proxiedSegmentUrl(line, base));
        }
      }
      return out.toString();
    } catch (e) {
      Log.e('HLS 播放列表改写失败：$e', StackTrace.current);
      return null;
    }
  }

  /// 改写 m3u8 标签内的 URI="..."（AES-128 密钥、初始化段等）。
  String _rewritePlaylistTagUri(String line, Uri base) {
    return line.replaceAllMapped(
      RegExp(r'URI="([^"]+)"', caseSensitive: false),
      (m) => 'URI="${_proxiedSegmentUrl(m.group(1)!, base)}"',
    );
  }

  /// 把（可能相对的）地址解析为绝对地址，再包一层本代理，
  /// 这样分片请求也由本进程带 referer/UA 去取（防盗链通常同样校验分片）。
  String _proxiedSegmentUrl(String ref, Uri base) {
    final absolute = base.resolve(ref);
    // 已经是本代理地址就别再套一层（避免 ?u= 嵌套编码导致解析失败）
    if (absolute.host == '127.0.0.1' && absolute.path == '/cast_stream') {
      return absolute.toString();
    }
    // 分片按点播处理：允许 Range，拖动/续播更稳
    return 'http://127.0.0.1:$_httpPort/cast_stream?vod=1'
        '&u=${Uri.encodeComponent(absolute.toString())}';
  }

  /// 解析投出端下发的请求头（Base64(JSON)）。
  /// 用 Base64 是因为 JSON 的引号经 XML 转义后，正则取出来是未解码的
  /// `&quot;`，直接 jsonDecode 必失败；Base64 不含任何 XML 特殊字符。
  /// 自定义直播源（IPTV/私人 M3U）全靠这些头才能通过源站校验。
  Map<String, String> _parseCastHeaders(String? raw) {
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(utf8.decode(base64Decode(raw)));
      if (decoded is Map) {
        return decoded.map((k, v) => MapEntry(k.toString(), v.toString()));
      }
    } catch (e) {
      Log.i('投屏请求头解析失败：$e');
    }
    return const {};
  }

  String? _xmlArg(String xml, String tag) {
    final m = RegExp('<$tag>(.*?)</$tag>', dotAll: true, caseSensitive: false)
        .firstMatch(xml);
    if (m == null) return null;
    return _xmlUnescape(m.group(1)!.trim());
  }

  String? _extractTitle(String metaData) {
    if (metaData.isEmpty) return null;
    final m = RegExp(r'<dc:title>(.*?)</dc:title>',
            dotAll: true, caseSensitive: false)
        .firstMatch(metaData);
    if (m == null) return null;
    final t = _xmlUnescape(m.group(1)!.trim());
    return t.isEmpty ? null : t;
  }

  String _xmlUnescape(String s) {
    return s
        .replaceAll('&amp;', '&')
        .replaceAll('&lt;', '<')
        .replaceAll('&gt;', '>')
        .replaceAll('&quot;', '"')
        .replaceAll('&#39;', "'")
        .replaceAll('&apos;', "'");
  }

  String _xmlEscape(String s) {
    return s
        .replaceAll('&', '&amp;')
        .replaceAll('<', '&lt;')
        .replaceAll('>', '&gt;')
        .replaceAll('"', '&quot;');
  }

  /// 解析 DLNA 时间（H:MM:SS / HH:MM:SS / 纯秒），失败返回 -1
  int _parseDlnaTime(String s) {
    final t = s.trim();
    if (t.isEmpty) return -1;
    final parts = t.split(':');
    if (parts.length == 3) {
      final h = int.tryParse(parts[0]);
      final m = int.tryParse(parts[1]);
      final sec = int.tryParse(parts[2]);
      if (h != null && m != null && sec != null) {
        return h * 3600 + m * 60 + sec;
      }
      return -1;
    }
    return int.tryParse(t) ?? -1;
  }

  String _fmtDlnaTime(Duration d) {
    final total = d.inSeconds < 0 ? 0 : d.inSeconds;
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    final s = total % 60;
    return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
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
