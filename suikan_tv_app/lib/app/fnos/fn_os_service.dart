import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart' as crypto;
import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/custom_source/m3u_models.dart';
import 'package:simple_live_tv_app/app/event_bus.dart';
import 'package:simple_live_tv_app/app/log.dart';
import 'package:simple_live_tv_app/app/sites.dart';
import 'package:simple_live_tv_app/services/db_service.dart';
import 'package:uuid/uuid.dart';

import 'fn_os_models.dart';
import 'fn_os_site.dart';

/// 飞牛影视（fnOS）REST API 常量与签名。
/// 签名算法取自 fnOS 官方 Web 前端（fnos-tv-web / trimemedia-web），已与多个开源客户端核对：
///   sign = md5( api_key _ path _ nonce _ timestamp _ md5(JSON body) _ api_secret )
/// 其中 path 含 /v 前缀（如 /v/api/v1/login）；POST 时 body 为 JSON.stringify(data)（保持插入顺序，不含 body nonce）；
/// GET 时 body 为空串，md5("")。请求头：Authorization=<token>、Authx=<nonce&timestamp&sign>。
const String _kFnApiKey = 'NDzZTVxnRKP8Z0jXg1VAMonaG8akvh';
const String _kFnApiSecret = '16CCEB3D-AB42-077D-36A1-F355324E4237';
const String _kFnAppName = 'trimemedia-web';

/// 飞牛影视服务：负责登录、列出影视库、列出影片、获取播放直链与鉴权头，
/// 并把每个服务器注册成一个可被播放链路识别的 Site（以 fnos_ 前缀注册进 Sites.allSites，
/// 但不写入首页 siteSort，因此只出现在「我的 - NAS影视库」，不会上首页）。
class FnOsService extends GetxService {
  static FnOsService get instance => Get.find<FnOsService>();

  final RxList<FnOsServer> servers = <FnOsServer>[].obs;
  final Map<String, Site> registeredSites = {};

  final Dio _dio = Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 20),
      receiveTimeout: const Duration(seconds: 60),
      headers: {
        'User-Agent':
            'Mozilla/5.0 (compatible; Suikan/2.1; +https://github.com/mobingchong/suikan)',
        'Content-Type': 'application/json',
      },
    ),
  );
  final Uuid _uuid = const Uuid();
  final Random _random = Random();

  /// 内存中的 token 缓存，避免每次都重新登录；持久化的 token 作为兜底。
  final Map<String, String> _tokenCache = {};

  FnOsService() {
    // 飞牛影视多为局域网自签证书，放行以便正常访问。
    _dio.httpClientAdapter = IOHttpClientAdapter(
      createHttpClient: () {
        final client = HttpClient();
        client.badCertificateCallback = (cert, host, port) => true;
        return client;
      },
    );
  }

  Future<FnOsService> init() async {
    final box = DBService.instance.fnOsBox;
    servers.clear();
    registeredSites.clear();
    for (final key in box.keys) {
      final raw = box.get(key);
      if (raw == null) continue;
      try {
        final s = FnOsServer.fromJson(json.decode(raw) as Map<String, dynamic>);
        servers.add(s);
        _registerSite(s);
      } catch (e, stack) {
        Log.e('fnOS 服务器[$key]解析失败: $e', stack);
      }
    }
    startAutoRefresh();
    return this;
  }

  void _registerSite(FnOsServer server) {
    final site = Site(
      id: 'fnos_${server.id}',
      name: server.name.isEmpty ? '飞牛影视' : server.name,
      logo: 'assets/images/fnos_movie.png',
      liveSite: FnOsSite(server: server),
    );
    Sites.allSites[site.id] = site;
    registeredSites[server.id] = site;
  }

  /// 去掉地址末尾的斜杠，避免拼出 //。
  String _base(FnOsServer s) => s.address.replaceFirst(RegExp(r'/+$'), '');

  /// 规范化用户输入的地址：补全协议(http) 与端口(飞牛影视媒体服务默认 8005)。
  /// fnOS 系统端口是 8000 / 5666，但飞牛影视(媒体)服务独立跑在 8005，两者不同。
  String _normalizeAddress(String raw) {
    var a = raw.trim();
    // 仅去尾部斜杠，避免误删 http:// 中的 //
    if (a.endsWith('/')) a = a.replaceFirst(RegExp(r'/+$'), '');
    if (!a.startsWith('http://') && !a.startsWith('https://')) {
      a = 'http://$a';
    }
    final uri = Uri.tryParse(a);
    if (uri != null && uri.hasAuthority && uri.port == 0) {
      a = '${uri.scheme}://${uri.host}:8005${uri.path.isEmpty ? '' : uri.path}';
    }
    return a;
  }

  String _md5(String s) => crypto.md5.convert(utf8.encode(s)).toString();

  /// 生成 Authx 请求头值。data 为 POST 请求体（用于计算 body 哈希）。
  String _genAuthx(String path, {Map<String, dynamic>? data}) {
    final nonce = (100000 + _random.nextInt(900000)).toString();
    final timestamp = DateTime.now().millisecondsSinceEpoch.toString();
    final bodyStr = data != null ? jsonEncode(data) : '';
    final bodyHash = _md5(bodyStr);
    final signSrc = [
      _kFnApiKey,
      path,
      nonce,
      timestamp,
      bodyHash,
      _kFnApiSecret,
    ].join('_');
    final sign = _md5(signSrc);
    return 'nonce=$nonce&timestamp=$timestamp&sign=$sign';
  }

  /// 海报地址补全：相对路径拼到 sys/img 接口，绝对 http(s) 原样返回。
  /// fnOS 的 sys/img 需要鉴权（实测无 authx 返回 501 Auth Failed），
  /// 相对路径图片 URL 追加 authx query 参数，NetImage 可直接加载。
  String posterUrl(FnOsServer s, String? poster) {
    if (poster == null || poster.isEmpty) return '';
    var p = poster;
    if (p.startsWith('/')) p = p.substring(1); // 去掉相对路径首斜杠，避免 // 重复
    if (p.startsWith('http://') || p.startsWith('https://')) {
      return p;
    }
    // 飞牛影视图片接口只认登录后的 cookie，不需要也不能带 authx query（带会 Auth Failed）。
    return '${_base(s)}/v/api/v1/sys/img/$p';
  }

  Future<String> _ensureToken(FnOsServer s) async {
    final cached = _tokenCache[s.id] ?? s.token;
    if (cached != null && cached.isNotEmpty) return cached;
    return _login(s);
  }

  Future<String> _login(FnOsServer s) async {
    const path = '/v/api/v1/login';
    final data = {
      'app_name': _kFnAppName,
      'username': s.username,
      'password': s.password,
    };
    final authx = _genAuthx(path, data: data);
    final bodyStr = jsonEncode(data);
    final resp = await _dio.post(
      '${_base(s)}$path',
      data: bodyStr,
      options: Options(
        headers: {'Authorization': '', 'Authx': authx},
      ),
    );
    final body = _asResponse(resp.data);
    final respData = body['data'];
    final token = (respData is Map ? respData['token'] : null) as String?;
    if (token == null || token.isEmpty) {
      throw Exception('登录失败：${body['msg'] ?? '未返回 token'}');
    }
    _tokenCache[s.id] = token;
    final updated = s.copyWith(
      token: token,
      tokenTs: DateTime.now().millisecondsSinceEpoch,
    );
    _updateServer(updated);
    return token;
  }

  /// 供 NetImage 等不经过 _request 的图片加载使用：返回当前已缓存的 token。
  /// 未缓存时返回 null（调用方应先用 _request 走一次正常流程触发登录）。
  String? cachedToken(FnOsServer s) {
    final t = _tokenCache[s.id] ?? s.token;
    return (t != null && t.isNotEmpty) ? t : null;
  }

  /// 图片接口（/v/api/v1/sys/img）接受 `Authorization: <token>` 头认证，
  /// 不接受 authx query（带会 Auth Failed）。返回供 NetImage 使用的请求头。
  Map<String, String>? imageHeaders(FnOsServer s) {
    final t = cachedToken(s);
    if (t == null || t.isEmpty) return null;
    return {'Authorization': t};
  }

  Map<String, dynamic> _asResponse(dynamic data) {
    if (data is Map) return Map<String, dynamic>.from(data);
    throw Exception('响应格式异常（非 JSON）');
  }

  /// 统一请求：自动带鉴权头，code!=0 时在 token 过期时尝试重新登录一次。
  Future<dynamic> _request(
    FnOsServer s,
    String method,
    String path, {
    Map<String, dynamic>? data,
    String? token,
  }) async {
    final tk = token ?? await _ensureToken(s);
    final authx = _genAuthx(path, data: data);
    final bodyStr = data != null ? jsonEncode(data) : null;
    final resp = await _dio.request(
      '${_base(s)}$path',
      data: bodyStr,
      options: Options(
        method: method,
        headers: {
          'Authorization': tk,
          'Authx': authx,
        },
      ),
    );
    final body = _asResponse(resp.data);
    final code = body['code'];
    if (code != 0) {
      if (code == -2) {
        _tokenCache.remove(s.id);
        final newToken = await _login(s);
        return _request(s, method, path, data: data, token: newToken);
      }
      throw Exception('请求失败($path)：${body['msg'] ?? code}');
    }
    return body['data'];
  }

  // ---- 对外 API ----

  /// 获取影视库列表。
  Future<List<FnOsLibrary>> getLibraries(FnOsServer s) async {
    final data = await _request(s, 'GET', '/v/api/v1/mediadb/list');
    if (data is List) {
      return data
          .map((e) => FnOsLibrary.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return [];
  }

  /// 列出某影视库下的影片。影视库 guid 作为 ancestor_guid 传入：
  /// fnOS 会递归返回该库下所有可播放条目（电影/剧集/单集等）。
  /// 注意：必须用 ancestor_guid，parent_guid 只匹配直接子级，实测在本类服务器上返回空列表。
  /// 用 tags.type 数组过滤（type 单字段在部分服务器版本被忽略），
  /// 过滤掉 Season / Directory / Folder 这类容器型条目，只保留可播放项。
  Future<List<FnOsMovie>> getMovies(FnOsServer s, String libraryGuid) async {
    final data = await _request(
      s,
      'POST',
      '/v/api/v1/item/list',
      data: {
        'ancestor_guid': libraryGuid,
        'tags': {
          'type': ['Movie', 'TV', 'Video'],
        },
        'exclude_grouped_video': 1,
        'sort_column': 'create_time',
        'sort_type': 'DESC',
        'page_size': _itemPageSize,
      },
    );
    if (data is Map && data['list'] is List) {
      return (data['list'] as List)
          .map((e) => FnOsMovie.fromJson(Map<String, dynamic>.from(e)))
          .where((m) =>
              m.type != 'Season' &&
              m.type != 'Directory' &&
              m.type != 'Folder')
          .toList();
    }
    return [];
  }

  /// 获取单个影片详情（用于播放页标题/封面）。
  Future<FnOsMovieInfo> getItemInfo(FnOsServer s, String guid) async {
    final data = await _request(s, 'GET', '/v/api/v1/item/$guid');
    return FnOsMovieInfo.fromJson(Map<String, dynamic>.from(data));
  }

  /// 获取单个 item 的原始详情 JSON（字段比列表接口丰富，含评分/年代/简介/视频流等）。
  Future<Map<String, dynamic>> getItemDetail(FnOsServer s, String guid) async {
    final data = await _request(s, 'GET', '/v/api/v1/item/$guid');
    if (data is Map) return Map<String, dynamic>.from(data);
    return <String, dynamic>{};
  }

  /// 官方接口获取某电视剧的季列表（season/list/:seriesGuid）。
  /// item/list 的 Season/Episode parent_guid 关系不可靠（实测大量失配），
  /// 详情页/季页必须用官方 season/episode 接口拉取正确层级（参照 thshu/fnos-tv）。
  Future<List<FnOsSeason>> getSeasons(FnOsServer s, String seriesGuid) async {
    final data = await _request(s, 'GET', '/v/api/v1/season/list/$seriesGuid');
    if (data is List) {
      return data
          .map((e) => FnOsSeason.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return [];
  }

  /// 官方接口获取某季的集列表（episode/list/:seasonGuid）。
  Future<List<FnOsEpisode>> getEpisodes(FnOsServer s, String seasonGuid) async {
    final data = await _request(s, 'GET', '/v/api/v1/episode/list/$seasonGuid');
    if (data is List) {
      return data
          .map((e) => FnOsEpisode.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return [];
  }

  /// 继续观看/最近播放列表（play/list），返回播放过的条目（电影/剧集/单集混合）。
  Future<List<FnOsMovie>> getResumeItems(FnOsServer s) async {
    final data = await _request(s, 'GET', '/v/api/v1/play/list');
    if (data is List) {
      return data
          .map((e) => FnOsMovie.fromJson(Map<String, dynamic>.from(e)))
          .toList();
    }
    return [];
  }

  /// 上报播放进度（POST /v/api/v1/play/record），失败静默。
  /// 内部先取 play/info 拿 media_guid，再上报位置/时长（秒）。
  Future<void> recordPlayStatus(
    FnOsServer s,
    String itemGuid, {
    required int ts,
    required int duration,
  }) async {
    try {
      final info = await _request(s, 'POST', '/v/api/v1/play/info', data: {
        'item_guid': itemGuid,
      });
      final mediaGuid =
          info is Map ? (info['media_guid']?.toString() ?? '') : '';
      if (mediaGuid.isEmpty) return;
      final host = Uri.tryParse(_base(s))?.host ?? '';
      await _request(s, 'POST', '/v/api/v1/play/record', data: {
        'item_guid': itemGuid,
        'media_guid': mediaGuid,
        'play_link': host,
        'ts': ts,
        'duration': duration,
      });
    } catch (e) {
      Log.logPrint('上报播放进度失败：$e');
    }
  }

  /// 标记已看完（POST /v/api/v1/item/watched），失败静默。
  Future<void> setWatched(FnOsServer s, String itemGuid) async {
    try {
      await _request(s, 'POST', '/v/api/v1/item/watched', data: {
        'item_guid': itemGuid,
      });
    } catch (e) {
      Log.logPrint('标记已看失败：$e');
    }
  }

  /// 用详情接口刷新电影字段。
  Future<FnOsMovie> fetchMovieDetail(FnOsServer s, FnOsMovie movie) async {
    final detail = await getItemDetail(s, movie.guid);
    if (detail.isEmpty) return movie;
    final parsed = FnOsMovie.fromJson(detail);
    return movie.copyWith(
      title: parsed.title,
      poster: parsed.poster,
      backdrop: parsed.backdrop,
      overview: parsed.overview,
      duration: parsed.duration,
      runtime: parsed.runtime,
      rating: parsed.rating,
      contentRating: parsed.contentRating,
      year: parsed.year,
      genres: parsed.genres,
      productionCountries: parsed.productionCountries,
      mediaStream: parsed.mediaStream,
      imdbId: parsed.imdbId,
      cast: parsed.cast,
      releaseDate: parsed.releaseDate,
      isFavorite: parsed.isFavorite,
      isWatched: parsed.isWatched,
    );
  }

  /// 用详情接口刷新电视剧字段。
  Future<FnOsTvSeries> fetchTvSeriesDetail(FnOsServer s, FnOsTvSeries series) async {
    final detail = await getItemDetail(s, series.guid);
    if (detail.isEmpty) return series;
    final parsed = FnOsTvSeries.fromJson(detail);
    return series.copyWith(
      title: parsed.title,
      poster: parsed.poster,
      backdrop: parsed.backdrop,
      overview: parsed.overview,
      numberOfSeasons: parsed.numberOfSeasons,
      numberOfEpisodes: parsed.numberOfEpisodes,
      firstAirDate: parsed.firstAirDate,
      lastAirDate: parsed.lastAirDate,
      rating: parsed.rating,
      contentRating: parsed.contentRating,
      year: parsed.year,
      genres: parsed.genres,
      productionCountries: parsed.productionCountries,
      mediaStream: parsed.mediaStream,
      imdbId: parsed.imdbId,
      cast: parsed.cast,
      isFavorite: parsed.isFavorite,
      isWatched: parsed.isWatched,
    );
  }

  /// 获取影视库内容：电影库返回按 Movie 过滤的影片列表；
  /// 电视剧库按 type 字段重建「电视剧(TV) → 季(Season) → 集(Episode)」层级，
  /// 满足「同一电视剧一个海报、内部分季、季下是集」的展示需求。
  /// 用 tags.type + 大 page_size 一次拉全（官方前端用法，实测分页在该服务器版本无效）。
  Future<FnOsLibraryContent> getLibraryContent(
    FnOsServer s,
    FnOsLibrary lib,
  ) async {
    final items = await _fetchAllItems(s, lib.guid);
    if (lib.category == 'TV') {
      return FnOsLibraryContent(isTv: true, series: _buildSeries(items));
    }
    final movies = items
        .where((e) => (e['type'] ?? '') == 'Movie')
        .map((e) => FnOsMovie.fromJson(e))
        .toList();
    return FnOsLibraryContent(isTv: false, movies: movies);
  }

  /// 拉取某影视库下的全部条目。
  /// 参照官方前端（thshu/fnos-tv-web）的正确用法：`tags.type` 数组过滤类型 +
  /// `exclude_grouped_video` + `page_size` 设大值一次拉全。
  /// ⚠️ 实测（2026-08-28）：该版本服务器 **忽略 page_index/type/exclude_folder/sort**，
  /// 只固定返回前 N 条（分页无效）—— 所以必须用大 page_size 一次拉全，
  /// 否则 891 条影视库只能拿到前 500 条（电影 818 / 剧 73 会大量缺失）。
  static const int _itemPageSize = 10000;

  Future<List<Map<String, dynamic>>> _fetchAllItems(
    FnOsServer s,
    String ancestorGuid, {
    List<String> types = const [
      'Movie',
      'TV',
      'Season',
      'Episode',
      'Directory',
      'Video',
    ],
  }) async {
    final all = <Map<String, dynamic>>[];
    var pageIndex = 0;
    while (true) {
      final data = await _request(
        s,
        'POST',
        '/v/api/v1/item/list',
        data: {
          'ancestor_guid': ancestorGuid,
          'tags': {'type': types},
          'exclude_grouped_video': 1,
          'sort_column': 'create_time',
          'sort_type': 'DESC',
          'page_index': pageIndex,
          'page_size': _itemPageSize,
        },
      );
      if (data is! Map) break;
      final list = data['list'];
      if (list is List) {
        for (final e in list) {
          all.add(Map<String, dynamic>.from(e));
        }
      }
      final totalRaw = data['total'];
      final total = totalRaw is num ? totalRaw.toInt() : 0;
      final got = list is List ? list.length : 0;
      pageIndex++;
      // 一次拉全（服务器忽略分页时第二次即返回空/重复，靠去重+总量判断停止）
      if (got == 0) break;
      if (total > 0 && all.length >= total) break;
      if (pageIndex > 50) break; // 防死循环
    }
    // 去重（分页异常时服务器可能返回重复条目）
    final seen = <String>{};
    return all.where((e) {
      final key = (e['guid'] ?? '').toString();
      if (key.isEmpty || seen.contains(key)) return false;
      seen.add(key);
      return true;
    }).toList();
  }

  /// 影视库条目统计（mediadb/sum，与飞牛 UI 精确一致）。
  /// 返回如 { "movie": 818, "tv": 73, "total": 891, "<库guid>": 819, ... }。
  Future<Map<String, int>> getLibrarySummary(FnOsServer s) async {
    final data = await _request(s, 'GET', '/v/api/v1/mediadb/sum');
    if (data is Map) {
      return data.map((k, v) => MapEntry(k.toString(), v is num ? v.toInt() : 0));
    }
    return {};
  }

  /// 由扁平的 item 列表重建电视剧层级。
  /// 优先按 TV → Season → Episode 的 parent_guid 关系组装；
  /// 若某部电视剧没有显式 Season 节点（实测部分库会出现），则按 tv_title 匹配 + season_number 合成季。
  List<FnOsTvSeries> _buildSeries(List<Map<String, dynamic>> items) {
    final seriesList = items.where((e) => (e['type'] ?? '') == 'TV').toList();
    final result = <FnOsTvSeries>[];
    final allEpisodes = items.where((e) => (e['type'] ?? '') == 'Episode').toList();
    final allSeasons = items.where((e) => (e['type'] ?? '') == 'Season').toList();

    for (final sMap in seriesList) {
      final series = FnOsTvSeries.fromJson(sMap);
      final seriesGuid = series.guid;
      final seriesTitle = series.title;

      // 显式 Season
      final seasonsRaw = allSeasons
          .where((e) => (e['parent_guid'] ?? '').toString() == seriesGuid)
          .toList();
      final seasons = <FnOsSeason>[];
      for (final seasonMap in seasonsRaw) {
        final season = FnOsSeason.fromJson(seasonMap);
        final episodesRaw = allEpisodes
            .where((e) => (e['parent_guid'] ?? '').toString() == season.guid)
            .toList()
          ..sort((a, b) =>
              ((a['episode_number'] ?? 0) as int)
                  .compareTo((b['episode_number'] ?? 0) as int));
        seasons.add(season.copyWith(
          episodes: episodesRaw.map((e) => FnOsEpisode.fromJson(e)).toList(),
        ));
      }
      seasons.sort((a, b) => a.seasonNumber.compareTo(b.seasonNumber));

      // 兜底：没有显式季时，按 tv_title 或 ancestor_name 匹配剧集并按 season_number 分组
      if (seasons.isEmpty) {
        final related = allEpisodes.where((e) {
          final tvTitle = e['tv_title']?.toString() ?? '';
          final ancestorName = e['ancestor_name']?.toString() ?? '';
          return tvTitle == seriesTitle ||
              (seriesTitle.isNotEmpty &&
                  (tvTitle.contains(seriesTitle) ||
                      seriesTitle.contains(tvTitle))) ||
              ancestorName == seriesTitle;
        }).toList();
        if (related.isNotEmpty) {
          final bySeason = <int, List<Map<String, dynamic>>>{};
          for (final ep in related) {
            final sn = (ep['season_number'] ?? 1) as int;
            bySeason.putIfAbsent(sn, () => []).add(ep);
          }
          for (final entry in bySeason.entries.toList()..sort((a, b) => a.key.compareTo(b.key))) {
            final eps = entry.value
              ..sort((a, b) =>
                  ((a['episode_number'] ?? 0) as int)
                      .compareTo((b['episode_number'] ?? 0) as int));
            seasons.add(FnOsSeason(
              guid: '${seriesGuid}_season_${entry.key}',
              title: entry.key == 0 ? '全部' : '第 ${entry.key} 季',
              seasonNumber: entry.key,
              episodes: eps.map((e) => FnOsEpisode.fromJson(e)).toList(),
            ));
          }
        }
      }

      result.add(series.copyWith(seasons: seasons));
    }
    return result;
  }

  /// 获取播放直链与鉴权头。返回 (url, headers)。
  Future<FnOsPlayUrl> getPlayUrl(FnOsServer s, String itemGuid) async {
    final info =
        await _request(s, 'POST', '/v/api/v1/play/info', data: {
      'item_guid': itemGuid,
    });
    final mediaGuid = info is Map ? info['media_guid'] as String? : null;
    if (mediaGuid == null || mediaGuid.isEmpty) {
      throw Exception('无法获取媒体播放地址');
    }
    final token = await _ensureToken(s);
    final path = '/v/api/v1/media/range/$mediaGuid';
    final authx = _genAuthx(path); // GET，无请求体
    final url = '${_base(s)}$path';
    final headers = {
      'Authorization': token,
      'Authx': authx,
    };
    final title = info is Map && info['item'] is Map
        ? (info['item']['title'] ?? '').toString()
        : '';
    return FnOsPlayUrl(url: url, headers: headers, title: title);
  }

  // ---- 持久化 ----

  Future<FnOsServer> addServer({
    required String name,
    required String address,
    required String username,
    required String password,
  }) async {
    final normalized = _normalizeAddress(address);
    final id = _uuid.v4();
    // 名称选填：留空则自动取地址中的主机名（IP/域名）作为名称。
    final resolvedName = name.trim().isNotEmpty
        ? name.trim()
        : (Uri.tryParse(normalized)?.host ?? normalized);
    // 先登录验证可用性，再保存。
    final temp = FnOsServer(
      id: id,
      name: resolvedName,
      address: normalized,
      username: username,
      password: password,
      addedAt: DateTime.now().millisecondsSinceEpoch,
    );
    final token = await _login(temp);
    final server = temp.copyWith(token: token);
    servers.add(server);
    _registerSite(server);
    await _persist(server);
    // 通知首页/分类重建标签页（飞牛影视已可作为标签页出现）。
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
    return server;
  }

  Future<void> removeServer(String id) async {
    servers.removeWhere((s) => s.id == id);
    registeredSites.remove(id);
    Sites.allSites.remove('fnos_$id');
    _tokenCache.remove(id);
    await DBService.runExclusive(
      () => DBService.instance.fnOsBox.delete(id),
    );
    // 通知首页/分类重建标签页。
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
  }

  /// 修改已添加的飞牛影视服务器（地址/用户名/密码），会重新登录校验。
  Future<void> updateServer({
    required String id,
    String? name,
    String? address,
    String? username,
    String? password,
  }) async {
    final idx = servers.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final old = servers[idx];
    final resolvedName =
        (name?.trim().isNotEmpty == true) ? name!.trim() : old.name;
    final normalized =
        address != null ? _normalizeAddress(address) : old.address;
    final temp = old.copyWith(
      name: resolvedName,
      address: normalized,
      username: username ?? old.username,
      password: password ?? old.password,
    );
    // _login 成功会内部更新列表并持久化（含新 token）。
    await _login(temp);
    EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
  }

  /// 仅更新刷新规则，不触发网络登录。
  Future<void> setRefreshRule(
    String id, {
    bool? autoRefresh,
    String? refreshMode,
    int? refreshIntervalHours,
    int? refreshHour,
  }) async {
    final idx = servers.indexWhere((s) => s.id == id);
    if (idx < 0) return;
    final s = servers[idx];
    final updated = s.copyWith(
      autoRefresh: autoRefresh ?? s.autoRefresh,
      refreshMode: refreshMode ?? s.refreshMode,
      refreshIntervalHours:
          refreshIntervalHours ?? s.refreshIntervalHours,
      refreshHour: refreshHour ?? s.refreshHour,
    );
    servers[idx] = updated;
    _registerSite(updated);
    await _persist(updated);
  }

  /// 手动/自动刷新影视库列表：重新拉取 mediadb/list 并更新 lastRefreshed。
  Future<List<FnOsLibrary>> refreshServerLibraries(FnOsServer server) async {
    final libs = await getLibraries(server);
    final idx = servers.indexWhere((s) => s.id == server.id);
    if (idx >= 0) {
      final updated = servers[idx].copyWith(
        lastRefreshed: DateTime.now().millisecondsSinceEpoch,
      );
      servers[idx] = updated;
      _persist(updated);
    }
    return libs;
  }

  Future<void> _updateServer(FnOsServer server) async {
    final idx = servers.indexWhere((s) => s.id == server.id);
    if (idx >= 0) servers[idx] = server;
    _registerSite(server);
    await _persist(server);
  }

  Future<void> _persist(FnOsServer server) async {
    await DBService.runExclusive(
      () => DBService.instance.fnOsBox.put(
            server.id,
            json.encode(server.toJson()),
          ),
    );
  }

  Site? siteForServer(String id) => registeredSites[id];

  /// 由站点 id（fnos_<uuid>）反查服务器配置，供首页/分类标签页使用。
  FnOsServer? serverForSiteId(String siteId) {
    if (!siteId.startsWith('fnos_')) return null;
    final bare = siteId.substring('fnos_'.length);
    for (final s in servers) {
      if (s.id == bare) return s;
    }
    return null;
  }

  // ---- 自动/定时刷新调度 ----
  Timer? _autoTimer;

  /// 启动后台定时检查（每 15 分钟），按各服务器刷新规则重新拉取影视库列表。
  void startAutoRefresh() {
    _autoTimer?.cancel();
    _autoTimer = Timer.periodic(const Duration(minutes: 15), (_) {
      unawaited(_autoRefreshDue());
    });
    unawaited(_autoRefreshDue());
  }

  Future<void> _autoRefreshDue() async {
    var refreshedAny = false;
    for (final s in List<FnOsServer>.from(servers)) {
      if (!s.autoRefresh) continue;
      if (_isRefreshDue(s)) {
        try {
          await refreshServerLibraries(s);
          refreshedAny = true;
        } catch (_) {
          // 单个失败不影响其余
        }
      }
    }
    // 仅在有实际刷新时才通知正在浏览的页面重新拉取。
    if (refreshedAny) {
      EventBus.instance.emit(EventBus.kCustomSourcesChanged, null);
    }
  }

  bool _isRefreshDue(FnOsServer s) {
    if (s.refreshMode == kRefreshModeManual) return false;
    final now = DateTime.now();
    final last = s.lastRefreshed ?? 0;
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
