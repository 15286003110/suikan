import 'package:get/get.dart';

import 'package:simple_live_app/app/custom_source/custom_source_service.dart';
import 'package:simple_live_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_app/app/fnos/fn_os_service.dart';

/// 本地内容搜索（自定义直播源频道 + 影视库），供搜索页「本地内容」tab 使用。
/// 自定义源频道本地过滤；fnOS 服务器无搜索接口（实测 item/list 搜索参数全被忽略），
/// 采用「全量拉取一次（约 891 条）+ 本地标题过滤 + 内存缓存」。
class LocalContentSearchController extends GetxController {
  /// 0=直播源频道，1=影视库
  var searchMode = 0.obs;

  final results = <LocalSearchResult>[].obs;
  var searching = false.obs;

  String keyword = '';

  /// fnOS 全量内容缓存（server.id -> 合并内容），避免每次搜索重复拉取。
  final Map<String, FnOsLibraryContent> _contentCache = {};

  void changeMode(int m) {
    searchMode.value = m;
    if (keyword.isNotEmpty) search(keyword);
  }

  Future<void> search(String kw) async {
    keyword = kw.trim();
    if (keyword.isEmpty) {
      results.clear();
      return;
    }
    searching.value = true;
    results.clear();
    try {
      if (searchMode.value == 0) {
        _searchChannels();
      } else {
        await _searchMedia();
      }
    } finally {
      searching.value = false;
    }
  }

  /// 全局搜索用：同时搜直播源频道 + 影视库，合并结果。
  Future<void> searchAll(String kw) async {
    keyword = kw.trim();
    if (keyword.isEmpty) {
      results.clear();
      return;
    }
    searching.value = true;
    results.clear();
    try {
      _searchChannels();
      await _searchMedia();
    } finally {
      searching.value = false;
    }
  }

  /// 直播源频道：遍历所有自定义源的本地频道，按名称过滤。
  void _searchChannels() {
    final kw = keyword.toLowerCase();
    for (final src in CustomSourceService.instance.sources) {
      final site = CustomSourceService.instance.registeredSites[src.id];
      if (site == null) continue;
      for (final ch in src.channels) {
        if (!ch.name.toLowerCase().contains(kw)) continue;
        results.add(LocalSearchResult(
          kind: LocalSearchResult.kChannel,
          title: ch.name,
          subtitle: '${src.name}${ch.group != null && ch.group!.isNotEmpty ? ' · ${ch.group}' : ''}',
          cover: ch.logo,
          payload: ChannelSearchPayload(site: site, url: ch.url),
        ));
      }
    }
  }

  /// 影视库：逐个服务器全量拉取（缓存）后按标题过滤。
  Future<void> _searchMedia() async {
    final kw = keyword.toLowerCase();
    for (final server in FnOsService.instance.servers) {
      final content = _contentCache[server.id] ??= await _loadAllContent(server);
      for (final m in content.movies) {
        if (!m.title.toLowerCase().contains(kw)) continue;
        results.add(LocalSearchResult(
          kind: LocalSearchResult.kMovie,
          title: m.title,
          subtitle: '电影 · ${server.name}',
          cover: FnOsService.instance.posterUrl(server, m.poster),
          httpHeaders: FnOsService.instance.imageHeaders(server),
          payload: MovieSearchPayload(server: server, movie: m),
        ));
      }
      for (final s in content.series) {
        if (!s.title.toLowerCase().contains(kw)) continue;
        results.add(LocalSearchResult(
          kind: LocalSearchResult.kSeries,
          title: s.title,
          subtitle: '电视剧 · ${server.name}',
          cover: FnOsService.instance.posterUrl(server, s.poster),
          httpHeaders: FnOsService.instance.imageHeaders(server),
          payload: SeriesSearchPayload(server: server, series: s),
        ));
      }
    }
  }

  Future<FnOsLibraryContent> _loadAllContent(FnOsServer server) async {
    final libs = await FnOsService.instance.getLibraries(server);
    final movies = <FnOsMovie>[];
    final series = <FnOsTvSeries>[];
    for (final lib in libs) {
      final content =
          await FnOsService.instance.getLibraryContent(server, lib);
      movies.addAll(content.movies);
      series.addAll(content.series);
    }
    return FnOsLibraryContent(isTv: false, movies: movies, series: series);
  }
}

/// 搜索结果统一展示模型。
class LocalSearchResult {
  static const int kChannel = 0;
  static const int kMovie = 1;
  static const int kSeries = 2;

  final int kind;
  final String title;
  final String subtitle;
  final String? cover;
  final Map<String, String>? httpHeaders;
  final Object payload;

  const LocalSearchResult({
    required this.kind,
    required this.title,
    required this.subtitle,
    this.cover,
    this.httpHeaders,
    required this.payload,
  });
}

class ChannelSearchPayload {
  final dynamic site;
  final String url;
  const ChannelSearchPayload({required this.site, required this.url});
}

class MovieSearchPayload {
  final FnOsServer server;
  final FnOsMovie movie;
  const MovieSearchPayload({required this.server, required this.movie});
}

class SeriesSearchPayload {
  final FnOsServer server;
  final FnOsTvSeries series;
  const SeriesSearchPayload({required this.server, required this.series});
}
