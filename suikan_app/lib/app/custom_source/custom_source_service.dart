import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/log.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/services/db_service.dart';
import 'package:uuid/uuid.dart';

import 'custom_m3u_site.dart';
import 'm3u_models.dart';
import 'm3u_parser.dart';

/// 自定义直播源管理：负责拉取/解析 M3U、持久化、并把每个源注册成
/// 可被播放链路识别的 Site（注册进 Sites.allSites，便于关注/历史恢复）。
class CustomSourceService extends GetxService {
  static CustomSourceService get instance => Get.find<CustomSourceService>();

  final RxList<M3uSource> sources = <M3uSource>[].obs;
  final Map<String, Site> registeredSites = {};

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 45),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (compatible; Suikan/2.1; +https://github.com/mobingchong/suikan)',
      },
    ),
  );
  final Uuid _uuid = const Uuid();

  Future<CustomSourceService> init() async {
    final box = DBService.instance.customSourceBox;
    sources.clear();
    registeredSites.clear();
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final src = M3uSource.fromJson(json.decode(raw) as Map<String, dynamic>);
        sources.add(src);
        _registerSite(src);
      } catch (e, stack) {
        Log.e('自定义源[$key]解析失败: $e', stack);
      }
    }
    return this;
  }

  void _registerSite(M3uSource source) {
    final site = Site(
      id: 'custom_${source.id}',
      name: source.name.isEmpty ? '自定义源' : source.name,
      logo: 'assets/images/logo.png',
      liveSite: CustomM3uSite(channels: source.channels),
    );
    Sites.allSites[site.id] = site;
    registeredSites[source.id] = site;
  }

  Future<List<M3uChannel>> _fetchAndParse(String url) async {
    final resp = await _dio.get<ResponseBody>(
      url,
      options: Options(
        responseType: ResponseType.stream,
        followRedirects: true,
      ),
    );
    final stream = resp.data?.stream;
    if (stream == null) return [];
    final bytes = <int>[];
    await for (final Uint8List chunk in stream) {
      bytes.addAll(chunk);
    }
    final content = utf8.decode(bytes, allowMalformed: true);
    return parseM3u(content);
  }

  Future<M3uSource> addSource({
    required String name,
    required String url,
  }) async {
    final id = _uuid.v4();
    final channels = await _fetchAndParse(url);
    final src = M3uSource(
      id: id,
      name: name,
      url: url,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      channels: channels,
    );
    sources.add(src);
    _registerSite(src);
    await _persist(src);
    return src;
  }

  Future<void> refreshSource(String id) async {
    final idx = sources.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final src = sources[idx];
    final channels = await _fetchAndParse(src.url);
    final updated = M3uSource(
      id: src.id,
      name: src.name,
      url: src.url,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      channels: channels,
    );
    sources[idx] = updated;
    _registerSite(updated);
    await _persist(updated);
  }

  Future<void> updateSource(
    String id, {
    String? name,
    String? url,
  }) async {
    final idx = sources.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final src = sources[idx];
    final newName = name ?? src.name;
    final newUrl = url ?? src.url;
    final channels = (url != null && url != src.url)
        ? await _fetchAndParse(newUrl)
        : src.channels;
    final updated = M3uSource(
      id: src.id,
      name: newName,
      url: newUrl,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      channels: channels,
    );
    sources[idx] = updated;
    _registerSite(updated);
    await _persist(updated);
  }

  Future<void> removeSource(String id) async {
    sources.removeWhere((s) => s.id == id);
    registeredSites.remove(id);
    Sites.allSites.remove('custom_$id');
    await DBService.instance.customSourceBox.delete(id);
  }

  Future<void> _persist(M3uSource src) async {
    await DBService.instance.customSourceBox.put(
      src.id,
      json.encode(src.toJson()),
    );
  }

  Site? siteForSource(String id) => registeredSites[id];
}
