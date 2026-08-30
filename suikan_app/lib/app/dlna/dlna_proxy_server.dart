import 'dart:async';
import 'dart:io';

import 'package:shelf/shelf.dart';
import 'package:shelf/shelf_io.dart' as shelf_io;

/// 本地 HTTP 代理：把带鉴权头的媒体流转发给 DLNA 设备。
///
/// 背景：fnOS 影视 URL 必须带 Authorization+Authx 实时签名头，且签名有时效；
/// DLNA 设备的 `<res http-header>` 扩展属性兼容性差（腾讯系/部分设备直接报
/// SOAP 500 或解析异常）。最稳的方案是：App 本地起代理，把代理地址推给设备，
/// 设备请求代理时由代理实时带鉴权头转发到真实服务器——设备只见普通 HTTP 流。
class DlnaProxyServer {
  static final DlnaProxyServer instance = DlnaProxyServer();

  HttpServer? _server;
  String? _targetUrl;
  Map<String, String>? _targetHeaders;

  bool get running => _server != null;

  /// 启动代理，返回本地代理地址（如 http://127.0.0.1:41234/）
  Future<String> start({
    required String targetUrl,
    Map<String, String>? headers,
  }) async {
    await stop();
    _targetUrl = targetUrl;
    _targetHeaders = headers;

    final handler = const Pipeline().addMiddleware(logRequests()).addHandler(_proxy);
    _server = await shelf_io.serve(handler, InternetAddress.loopbackIPv4, 0);
    final port = _server!.port;
    return 'http://127.0.0.1:$port/';
  }

  /// 转发请求：把设备的请求转发到目标 URL，带上目标 headers。
  Future<Response> _proxy(Request request) async {
    final target = _targetUrl;
    if (target == null) {
      return Response.notFound('proxy not configured');
    }
    final client = HttpClient();
    try {
      final uri = Uri.parse(target);
      // 透传 Range（进度拖动）、User-Agent 等
      final req = await client.getUrl(uri);
      req.headers.set('Range', request.headers['range'] ?? 'bytes=0-');
      req.headers.set('User-Agent', request.headers['user-agent'] ?? 'Suikan-DLNA');
      req.headers.set('Accept', '*/*');
      _targetHeaders?.forEach((k, v) {
        req.headers.set(k, v);
      });
      final resp = await req.close().timeout(const Duration(seconds: 15));
      // 转发状态码与响应头（Content-Length/Range/Content-Type 等）
      final headers = <String, String>{};
      resp.headers.forEach((k, v) {
        final lower = k.toLowerCase();
        if (lower == 'content-length' ||
            lower == 'content-type' ||
            lower == 'content-range' ||
            lower == 'accept-ranges' ||
            lower == 'content-disposition' ||
            lower == 'etag' ||
            lower == 'last-modified') {
          headers[k] = v.isNotEmpty ? v.first : '';
        }
      });
      return Response(
        resp.statusCode,
        headers: headers,
        body: resp,
      );
    } catch (e) {
      return Response(502, body: 'proxy error: $e');
    } finally {
      client.close();
    }
  }

  Future<void> stop() async {
    final s = _server;
    _server = null;
    _targetUrl = null;
    _targetHeaders = null;
    if (s != null) {
      try {
        await s.close(force: true);
      } catch (_) {}
    }
  }
}
