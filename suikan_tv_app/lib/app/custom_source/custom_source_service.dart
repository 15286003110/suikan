import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
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
    startAutoRefresh();
    return this;
  }

  /// 频道唯一键：优先用 tvgId，否则用「名称+地址」避免同名多线路冲突。
  String _chanKey(M3uChannel c) {
    if (c.tvgId != null && c.tvgId!.isNotEmpty) return 't:${c.tvgId}';
    return 'n:${c.name} ${c.url}';
  }

  /// 刷新/改地址时保留用户已有顺序与字段：已有的就地更新地址/图标/分组，
  /// 末尾追加上游新增频道；上游已移除的频道不再保留，从而不破坏手动排序。
  List<M3uChannel> _mergeChannels(
    List<M3uChannel> existing,
    List<M3uChannel> fresh,
  ) {
    final freshMap = <String, M3uChannel>{};
    for (final f in fresh) {
      freshMap[_chanKey(f)] = f;
    }
    // 旧频道按名称索引，用于新频道缺台标时继承（tvgId/URL 变化后仍保留台标）。
    final oldByName = <String, M3uChannel>{};
    for (final e in existing) {
      oldByName.putIfAbsent(e.name, () => e);
    }
    final result = <M3uChannel>[];
    final used = <String>{};
    for (final e in existing) {
      final key = _chanKey(e);
      final f = freshMap[key];
      if (f != null) {
        result.add(M3uChannel(
          name: e.name,
          url: f.url,
          // 空串/空台标一律继承旧值（源站刷新常返回空 logo，会覆盖已有台标）
          logo: (f.logo == null || f.logo!.isEmpty) ? e.logo : f.logo,
          group: f.group ?? e.group,
          tvgId: e.tvgId,
        ));
        used.add(key);
      }
    }
    for (final f in fresh) {
      final key = _chanKey(f);
      if (used.contains(key)) continue;
      final old = oldByName[f.name];
      result.add(M3uChannel(
        name: f.name,
        url: f.url,
        logo: (f.logo == null || f.logo!.isEmpty)
            ? (old?.logo ?? f.logo)
            : f.logo,
        group: f.group,
        tvgId: f.tvgId,
      ));
    }
    return result;
  }

  /// 仅更新刷新规则，不触发网络拉取。
  Future<void> setRefreshRule(
    String id, {
    bool? autoRefresh,
    String? refreshMode,
    int? refreshIntervalHours,
    int? refreshHour,
  }) async {
    final idx = sources.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final src = sources[idx];
    final updated = M3uSource(
      id: src.id,
      name: src.name,
      url: src.url,
      enabled: src.enabled,
      lastUpdated: src.lastUpdated,
      addedAt: src.addedAt,
      channels: src.channels,
      sortMode: src.sortMode,
      autoRefresh: autoRefresh ?? src.autoRefresh,
      refreshMode: refreshMode ?? src.refreshMode,
      refreshIntervalHours: refreshIntervalHours ?? src.refreshIntervalHours,
      refreshHour: refreshHour ?? src.refreshHour,
    );
    sources[idx] = updated;
    await _persist(updated);
  }

  void _registerSite(M3uSource source) {
    final site = Site(
      id: 'custom_${source.id}',
      name: source.name.isEmpty ? '自定义源' : source.name,
      logo: 'assets/images/custom_source.png',
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
      addedAt: DateTime.now().millisecondsSinceEpoch,
      channels: channels,
    );
    sources.add(src);
    _registerSite(src);
    await _persist(src);
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
    return src;
  }

  /// 持久化手动排序后的频道顺序（用于浏览页「手动排序」）。
  Future<void> reorderChannels(String id, List<M3uChannel> ordered) async {
    final idx = sources.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final src = sources[idx];
    final updated = M3uSource(
      id: src.id,
      name: src.name,
      url: src.url,
      enabled: src.enabled,
      lastUpdated: src.lastUpdated,
      channels: ordered,
      sortMode: src.sortMode,
    );
    sources[idx] = updated;
    _registerSite(updated);
    await _persist(updated);
  }

  /// 持久化浏览页选择的排序方式（key 为 CustomSourceSortMode.name）。
  Future<void> updateSortMode(String id, String sortMode) async {
    final idx = sources.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final src = sources[idx];
    final updated = M3uSource(
      id: src.id,
      name: src.name,
      url: src.url,
      enabled: src.enabled,
      lastUpdated: src.lastUpdated,
      channels: src.channels,
      sortMode: sortMode,
    );
    sources[idx] = updated;
    await _persist(updated);
  }

  /// 刷新单个直播源（重新拉取 M3U，更新频道地址/台标/分组）。
  /// [notify] 为 true 时广播 kCustomSourcesChanged（添加/删除源时用）；
  /// 浏览页内原地刷新传 false，避免触发首页/分类重建标签页导致跳转到其它平台。
  Future<void> refreshSource(String id, {bool notify = true}) async {
    final idx = sources.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final src = sources[idx];
    final channels = await _fetchAndParse(src.url);
    final merged = _mergeChannels(src.channels, channels);
    final updated = M3uSource(
      id: src.id,
      name: src.name,
      url: src.url,
      enabled: src.enabled,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      addedAt: src.addedAt,
      channels: merged,
      sortMode: src.sortMode,
      autoRefresh: src.autoRefresh,
      refreshMode: src.refreshMode,
      refreshIntervalHours: src.refreshIntervalHours,
      refreshHour: src.refreshHour,
    );
    sources[idx] = updated;
    _registerSite(updated);
    await _persist(updated);
    if (notify) {
      EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
    }
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
        ? _mergeChannels(src.channels, await _fetchAndParse(newUrl))
        : src.channels;
    final updated = M3uSource(
      id: src.id,
      name: newName,
      url: newUrl,
      enabled: src.enabled,
      lastUpdated: DateTime.now().millisecondsSinceEpoch,
      addedAt: src.addedAt,
      channels: channels,
      sortMode: src.sortMode,
      autoRefresh: src.autoRefresh,
      refreshMode: src.refreshMode,
      refreshIntervalHours: src.refreshIntervalHours,
      refreshHour: src.refreshHour,
    );
    sources[idx] = updated;
    _registerSite(updated);
    await _persist(updated);
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
  }

  Future<void> removeSource(String id) async {
    sources.removeWhere((s) => s.id == id);
    registeredSites.remove(id);
    Sites.allSites.remove('custom_$id');
    await DBService.runExclusive(
      () => DBService.instance.customSourceBox.delete(id),
    );
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
  }

  Future<void> _persist(M3uSource src) async {
    await DBService.runExclusive(
      () => DBService.instance.customSourceBox.put(
            src.id,
            json.encode(src.toJson()),
          ),
    );
  }

  Site? siteForSource(String id) => registeredSites[id];

  // ---- 播放器内切换线路支持：按播放地址反查频道 ----

  /// 按播放地址反查所属源的裸 id（不含 custom_ 前缀）。找不到返回 null。
  String? sourceIdForUrl(String url) {
    for (final src in sources) {
      for (final c in src.channels) {
        if (c.url == url) return src.id;
      }
    }
    return null;
  }

  /// 按播放地址反查频道（同名多线路取第一条）。找不到返回 null。
  M3uChannel? channelForUrl(String url) {
    for (final src in sources) {
      for (final c in src.channels) {
        if (c.url == url) return c;
      }
    }
    return null;
  }

  /// 按播放地址反查「同名频道组」的全部线路（与浏览页合并规则一致：
  /// 名称 trim 后非空按名称合并，否则按地址合并）。找不到返回 null。
  List<M3uChannel>? linesForUrl(String url) {
    for (final src in sources) {
      for (final c in src.channels) {
        if (c.url != url) continue;
        final key = c.name.trim().isEmpty ? c.url : c.name.trim();
        return src.channels
            .where(
              (x) =>
                  (x.name.trim().isEmpty ? x.url : x.name.trim()) == key,
            )
            .toList();
      }
    }
    return null;
  }

  // ---- 自动/定时刷新调度 ----
  Timer? _autoTimer;

  /// 启动后台定时检查（每 15 分钟），按各源刷新规则自动刷新。
  /// 进程存活期间持续运行；重复调用会先取消旧计时器。
  void startAutoRefresh() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      unawaited(_autoRefreshDue());
    });
    unawaited(_autoRefreshDue());
  }

  Future<void> _autoRefreshDue() async {
    for (final s in List<M3uSource>.from(sources)) {
      if (!s.autoRefresh) continue;
      if (_isRefreshDue(s)) {
        try {
          await refreshSource(s.id);
        } catch (_) {
          // 单个源失败不影响其余
        }
      }
    }
  }

  bool _isRefreshDue(M3uSource s) {
    if (s.refreshMode == kRefreshModeManual) return false;
    final now = DateTime.now();
    final last = s.lastUpdated ?? 0;
    if (s.refreshMode == kRefreshModeDaily) {
      final target = DateTime(now.year, now.month, now.day, s.refreshHour, 0);
      if (now.isBefore(target)) return false;
      return last < target.millisecondsSinceEpoch;
    }
    final intervalMs =
        (s.refreshIntervalHours <= 0 ? 6 : s.refreshIntervalHours) *
            3600 *
            1000;
    return now.millisecondsSinceEpoch - last >= intervalMs;
  }
}
