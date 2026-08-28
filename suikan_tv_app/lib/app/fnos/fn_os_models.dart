import 'package:simple_live_tv_app/app/custom_source/m3u_models.dart';
import 'package:uuid/uuid.dart';

/// 飞牛影视（fnOS）服务器配置。
/// 地址/用户名/密码用于登录换取 token；token 缓存用于避免频繁登录。
/// 注意：密码以明文存入本地 Hive 箱（与现有自定义直播源 URL 的存储方式一致），
/// 仅保存在本机，用于 token 过期后自动重新登录。若对安全性要求更高可后续改为加密箱。
class FnOsServer {
  final String id;
  final String name;
  final String address; // 基础地址，如 http://192.168.1.100:5666
  final String username;
  final String password;
  final String? token; // 登录后缓存的 token（可能为空）
  final int? tokenTs; // token 获取时间（毫秒），用于判断过期
  final int addedAt; // 添加时间（毫秒），用于首页/分类按添加顺序排序
  final int? lastRefreshed; // 上次刷新影视库列表时间（毫秒）

  /// 自动刷新开关。
  final bool autoRefresh;
  /// 刷新方式：kRefreshModeManual / kRefreshModeInterval / kRefreshModeDaily。
  final String refreshMode;
  /// interval 模式：每隔多少小时刷新一次（默认 6）。
  final int refreshIntervalHours;
  /// daily 模式：每天几点刷新（0-23，默认 4）。
  final int refreshHour;

  FnOsServer({
    required this.id,
    required this.name,
    required this.address,
    required this.username,
    required this.password,
    this.token,
    this.tokenTs,
    this.addedAt = 0,
    this.lastRefreshed,
    this.autoRefresh = false,
    this.refreshMode = kRefreshModeManual,
    this.refreshIntervalHours = 6,
    this.refreshHour = 4,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'address': address,
        'username': username,
        'password': password,
        'token': token,
        'tokenTs': tokenTs,
        'addedAt': addedAt,
        'lastRefreshed': lastRefreshed,
        'autoRefresh': autoRefresh,
        'refreshMode': refreshMode,
        'refreshIntervalHours': refreshIntervalHours,
        'refreshHour': refreshHour,
      };

  factory FnOsServer.fromJson(Map<String, dynamic> j) => FnOsServer(
        id: (j['id'] as String?) ?? const Uuid().v4(),
        name: (j['name'] as String?) ?? '',
        address: (j['address'] as String?) ?? '',
        username: (j['username'] as String?) ?? '',
        password: (j['password'] as String?) ?? '',
        token: j['token'] as String?,
        tokenTs: j['tokenTs'] as int?,
        addedAt: (j['addedAt'] as int?) ?? 0,
        lastRefreshed: j['lastRefreshed'] as int?,
        autoRefresh: (j['autoRefresh'] as bool?) ?? false,
        refreshMode: (j['refreshMode'] as String?) ?? kRefreshModeManual,
        refreshIntervalHours: (j['refreshIntervalHours'] as int?) ?? 6,
        refreshHour: (j['refreshHour'] as int?) ?? 4,
      );

  FnOsServer copyWith({
    String? name,
    String? address,
    String? username,
    String? password,
    String? token,
    int? tokenTs,
    int? addedAt,
    int? lastRefreshed,
    bool? autoRefresh,
    String? refreshMode,
    int? refreshIntervalHours,
    int? refreshHour,
  }) =>
      FnOsServer(
        id: id,
        name: name ?? this.name,
        address: address ?? this.address,
        username: username ?? this.username,
        password: password ?? this.password,
        token: token ?? this.token,
        tokenTs: tokenTs ?? this.tokenTs,
        addedAt: addedAt ?? this.addedAt,
        lastRefreshed: lastRefreshed ?? this.lastRefreshed,
        autoRefresh: autoRefresh ?? this.autoRefresh,
        refreshMode: refreshMode ?? this.refreshMode,
        refreshIntervalHours:
            refreshIntervalHours ?? this.refreshIntervalHours,
        refreshHour: refreshHour ?? this.refreshHour,
      );
}

/// 影视库（媒体数据库）。
class FnOsLibrary {
  final String guid;
  final String name;
  final String category; // Movie / TV / ...

  FnOsLibrary({
    required this.guid,
    required this.name,
    this.category = '',
  });

  factory FnOsLibrary.fromJson(Map<String, dynamic> j) => FnOsLibrary(
        guid: (j['guid'] ?? '').toString(),
        name: (j['name'] ?? '').toString(),
        category: (j['category'] ?? '').toString(),
      );

  /// 展示名：name 为空时按分类兜底（飞牛影视影视库 name 常返回 null）。
  String get displayName {
    if (name.isNotEmpty) return name;
    if (category == 'Movie') return '电影';
    if (category == 'TV') return '电视剧';
    return category.isNotEmpty ? category : '影视库';
  }
}

/// 视频流信息（media_stream）。
class FnOsMediaStream {
  final List<String> resolutions;
  final List<String> audioTypes;
  final List<String> colorRangeTypes;

  const FnOsMediaStream({
    this.resolutions = const [],
    this.audioTypes = const [],
    this.colorRangeTypes = const [],
  });

  factory FnOsMediaStream.fromJson(dynamic j) {
    if (j is! Map) return const FnOsMediaStream();
    final map = Map<String, dynamic>.from(j);
    return FnOsMediaStream(
      resolutions: _stringList(map['resolutions']),
      audioTypes: _stringList(map['audio_type']),
      colorRangeTypes: _stringList(map['color_range_type']),
    );
  }

  bool get isEmpty =>
      resolutions.isEmpty && audioTypes.isEmpty && colorRangeTypes.isEmpty;

  static List<String> _stringList(dynamic v) {
    if (v is List) {
      return v.map((e) => e?.toString() ?? '').where((s) => s.isNotEmpty).toList();
    }
    if (v is String && v.isNotEmpty) return [v];
    return const [];
  }
}

/// 演职人员（仅在有数据时展示）。
class FnOsCastMember {
  final String name;
  final String role;
  final String? photo;

  FnOsCastMember({
    required this.name,
    this.role = '',
    this.photo,
  });

  factory FnOsCastMember.fromJson(Map<String, dynamic> j) => FnOsCastMember(
        name: (j['name'] ?? '').toString(),
        role: (j['role'] ?? j['character'] ?? j['job'] ?? '').toString(),
        photo: j['photo']?.toString() ??
            j['profile_path']?.toString() ??
            j['image']?.toString(),
      );
}

/// 通用字段解析工具。
class FnOsFieldUtils {
  static String titleFromJson(Map<String, dynamic> j) {
    for (final k in const ['title', 'tv_title', 'original_title', 'name', 'parent_title']) {
      final v = j[k];
      if (v is String && v.trim().isNotEmpty) return v.trim();
    }
    return '';
  }

  static String? overviewFromJson(Map<String, dynamic> j) {
    final v = j['overview'];
    return v is String && v.trim().isNotEmpty ? v.trim() : null;
  }

  static String? posterFromJson(Map<String, dynamic> j) {
    final v = j['poster'] ?? j['posters'] ?? j['still_path'];
    if (v is String && v.isNotEmpty) return v;
    // 详情接口无 poster 字段，用 backdrops 第一张兜底（列表接口才有 poster）。
    final bd = j['backdrops'];
    if (bd is List && bd.isNotEmpty) {
      final first = bd.first;
      if (first is String && first.isNotEmpty) return first;
      if (first is Map) {
        final p = first['path'] ?? first['url'];
        if (p is String && p.isNotEmpty) return p;
      }
    }
    return null;
  }

  static String? backdropFromJson(Map<String, dynamic> j) {
    final v = j['backdrop'] ?? j['backdrops'];
    if (v is String && v.isNotEmpty) return v;
    if (v is List && v.isNotEmpty) {
      final first = v.first;
      if (first is String && first.isNotEmpty) return first;
      if (first is Map) {
        final p = first['path'] ?? first['url'];
        if (p is String && p.isNotEmpty) return p;
      }
    }
    return null;
  }

  static double? ratingFromJson(Map<String, dynamic> j) {
    final v = j['vote_average'] ?? j['rating'] ?? j['community_rating'];
    if (v is num) return v.toDouble();
    if (v is String) return double.tryParse(v);
    return null;
  }

  static int? yearFromJson(Map<String, dynamic> j) {
    final v = j['year'] ?? j['production_year'];
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    final date = _dateStr(j);
    if (date != null && date.length >= 4) return int.tryParse(date.substring(0, 4));
    return null;
  }

  static String? _dateStr(Map<String, dynamic> j) {
    for (final k in const ['release_date', 'first_air_date', 'air_date', 'last_air_date']) {
      final v = j[k];
      if (v is String && v.isNotEmpty) return v;
    }
    return null;
  }

  static int durationSeconds(Map<String, dynamic> j) {
    final v = j['duration'];
    if (v is int) return v;
    if (v is String) return int.tryParse(v) ?? 0;
    return 0;
  }

  static int? runtimeMinutes(Map<String, dynamic> j) {
    final v = j['runtime'];
    if (v is int) return v;
    if (v is String) return int.tryParse(v);
    return null;
  }

  static List<String> genresFromJson(Map<String, dynamic> j) {
    final v = j['genres'];
    if (v is List) {
      return v.map((e) {
        if (e is String && e.isNotEmpty) return e;
        final id = e is int ? e : int.tryParse(e?.toString() ?? '');
        if (id != null) return _genreName(id);
        return '';
      }).where((s) => s.isNotEmpty).toList();
    }
    if (v is String && v.isNotEmpty) {
      return v.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }

  static List<String> countriesFromJson(Map<String, dynamic> j) {
    final v = j['production_countries'] ?? j['countries'] ?? j['country'];
    if (v is List) {
      return v.map((e) => _countryName(e?.toString() ?? '')).where((s) => s.isNotEmpty).toList();
    }
    if (v is String && v.isNotEmpty) {
      return v.split(',').map((s) => _countryName(s.trim())).where((s) => s.isNotEmpty).toList();
    }
    return const [];
  }

  static String? contentRatingFromJson(Map<String, dynamic> j) {
    final v = j['content_ratings'] ?? j['content_rating'];
    if (v is String && v.isNotEmpty) return v;
    if (v is List && v.isNotEmpty) {
      final first = v.first;
      if (first is String && first.isNotEmpty) return first;
      if (first is Map) return (first['name'] ?? first['rating'])?.toString();
    }
    return null;
  }

  static List<FnOsCastMember> castFromJson(Map<String, dynamic> j) {
    final v = j['cast'] ?? j['actors'] ?? j['credits']?['cast'];
    if (v is List) {
      return v
          .whereType<Map>()
          .map((e) => FnOsCastMember.fromJson(Map<String, dynamic>.from(e)))
          .where((c) => c.name.isNotEmpty)
          .toList();
    }
    return const [];
  }

  static String? imdbIdFromJson(Map<String, dynamic> j) {
    final v = j['imdb_id'];
    if (v is String && v.isNotEmpty) return v;
    return null;
  }

  static String _genreName(int id) {
    const map = {
      28: '动作', 12: '冒险', 16: '动画', 35: '喜剧', 80: '犯罪', 99: '纪录',
      18: '剧情', 10751: '家庭', 14: '奇幻', 36: '历史', 27: '恐怖', 10402: '音乐',
      9648: '悬疑', 10749: '爱情', 878: '科幻', 10770: '电视电影', 53: '惊悚',
      10752: '战争', 37: '西部',
      10759: '动作冒险', 10762: '儿童', 10763: '新闻', 10764: '真人秀',
      10765: '科幻奇幻', 10766: '肥皂剧', 10767: '脱口秀', 10768: '战争政治',
      11: '犯罪', 13: '悬疑', 4: '喜剧', 5: '犯罪', 7: '悬疑', 9: '动作冒险',
    };
    return map[id] ?? id.toString();
  }

  static String _countryName(String code) {
    const map = {
      'US': '美国', 'GB': '英国', 'CN': '中国大陆', 'HK': '中国香港', 'TW': '中国台湾',
      'JP': '日本', 'KR': '韩国', 'IN': '印度', 'FR': '法国', 'DE': '德国',
      'IT': '意大利', 'ES': '西班牙', 'RU': '俄罗斯', 'CA': '加拿大', 'AU': '澳大利亚',
      'BR': '巴西', 'MX': '墨西哥', 'TH': '泰国', 'VN': '越南', 'SG': '新加坡',
    };
    return map[code.toUpperCase()] ?? code;
  }
}

/// 影片条目（影视库列表中的一项，电影或单集）。
class FnOsMovie {
  final String guid;
  final String title;
  final String? poster;
  final String? backdrop;
  final String type; // Movie / Episode / Video / Directory
  final int duration; // 秒
  final int? runtime; // 分钟（仅电影详情可能返回）
  final String? parentGuid;
  final String? overview;
  final double? rating;
  final String? contentRating;
  final int? year;
  final List<String> genres;
  final List<String> productionCountries;
  final FnOsMediaStream mediaStream;
  final String? imdbId;
  final List<FnOsCastMember> cast;
  final String? releaseDate;
  final bool isFavorite;
  final bool isWatched;
  final String lan; // 语言（列表接口返回）
  final String status; // 匹配状态（列表接口返回）

  FnOsMovie({
    required this.guid,
    required this.title,
    this.poster,
    this.backdrop,
    this.type = '',
    this.duration = 0,
    this.runtime,
    this.parentGuid,
    this.overview,
    this.rating,
    this.contentRating,
    this.year,
    this.genres = const [],
    this.productionCountries = const [],
    this.mediaStream = const FnOsMediaStream(),
    this.imdbId,
    this.cast = const [],
    this.releaseDate,
    this.isFavorite = false,
    this.isWatched = false,
    this.lan = '',
    this.status = '',
  });

  factory FnOsMovie.fromJson(Map<String, dynamic> raw) {
    final j = Map<String, dynamic>.from(raw);
    final overview = FnOsFieldUtils.overviewFromJson(j);
    return FnOsMovie(
      guid: (j['guid'] ?? '').toString(),
      title: FnOsFieldUtils.titleFromJson(j),
      poster: FnOsFieldUtils.posterFromJson(j),
      backdrop: FnOsFieldUtils.backdropFromJson(j),
      type: (j['type'] ?? '').toString(),
      duration: FnOsFieldUtils.durationSeconds(j),
      runtime: FnOsFieldUtils.runtimeMinutes(j),
      parentGuid: j['parent_guid']?.toString(),
      overview: overview,
      rating: FnOsFieldUtils.ratingFromJson(j),
      contentRating: FnOsFieldUtils.contentRatingFromJson(j),
      year: FnOsFieldUtils.yearFromJson(j),
      genres: FnOsFieldUtils.genresFromJson(j),
      productionCountries: FnOsFieldUtils.countriesFromJson(j),
      mediaStream: FnOsMediaStream.fromJson(j['media_stream']),
      imdbId: FnOsFieldUtils.imdbIdFromJson(j),
      cast: FnOsFieldUtils.castFromJson(j),
      releaseDate: FnOsFieldUtils._dateStr(j),
      isFavorite: j['is_favorite'] == true || j['is_favorite'] == 1,
      isWatched: j['is_watched'] == true || j['is_watched'] == 1 || j['watched'] == true,
      lan: (j['lan'] ?? '').toString(),
      status: (j['status'] ?? '').toString(),
    );
  }

  /// 详情端点字段更丰富，该方法用于从详情响应重建（保留已有字段）。
  FnOsMovie copyWith({
    String? title,
    String? poster,
    String? backdrop,
    String? type,
    int? duration,
    int? runtime,
    String? parentGuid,
    String? overview,
    double? rating,
    String? contentRating,
    int? year,
    List<String>? genres,
    List<String>? productionCountries,
    FnOsMediaStream? mediaStream,
    String? imdbId,
    List<FnOsCastMember>? cast,
    String? releaseDate,
    bool? isFavorite,
    bool? isWatched,
  }) =>
      FnOsMovie(
        guid: guid,
        title: title ?? this.title,
        poster: poster ?? this.poster,
        backdrop: backdrop ?? this.backdrop,
        type: type ?? this.type,
        duration: duration ?? this.duration,
        runtime: runtime ?? this.runtime,
        parentGuid: parentGuid ?? this.parentGuid,
        overview: overview ?? this.overview,
        rating: rating ?? this.rating,
        contentRating: contentRating ?? this.contentRating,
        year: year ?? this.year,
        genres: genres ?? this.genres,
        productionCountries: productionCountries ?? this.productionCountries,
        mediaStream: mediaStream ?? this.mediaStream,
        imdbId: imdbId ?? this.imdbId,
        cast: cast ?? this.cast,
        releaseDate: releaseDate ?? this.releaseDate,
        isFavorite: isFavorite ?? this.isFavorite,
        isWatched: isWatched ?? this.isWatched,
      );

  String get durationText {
    final total = duration > 0 ? duration : ((runtime ?? 0) * 60);
    if (total <= 0) return '';
    final h = total ~/ 3600;
    final m = (total % 3600) ~/ 60;
    if (h > 0) return '$h小时${m > 0 ? ' $m分钟' : ''}';
    return '$m分钟';
  }
}

/// 电视剧单集（type=Episode）。
class FnOsEpisode {
  final String guid;
  final String title; // 集标题（常为空）
  final int seasonNumber;
  final int episodeNumber;
  final int duration; // 秒
  final String? poster;
  final String? stillPath;
  final String? parentGuid; // 所属季 guid
  final String? overview;
  final double? rating;
  final FnOsMediaStream mediaStream;
  final bool isWatched;

  FnOsEpisode({
    required this.guid,
    required this.title,
    this.seasonNumber = 0,
    this.episodeNumber = 0,
    this.duration = 0,
    this.poster,
    this.stillPath,
    this.parentGuid,
    this.overview,
    this.rating,
    this.mediaStream = const FnOsMediaStream(),
    this.isWatched = false,
  });

  factory FnOsEpisode.fromJson(Map<String, dynamic> raw) {
    final j = Map<String, dynamic>.from(raw);
    return FnOsEpisode(
      guid: (j['guid'] ?? '').toString(),
      title: (j['title'] ?? '').toString(),
      seasonNumber: (j['season_number'] ?? 0) as int,
      episodeNumber: (j['episode_number'] ?? 0) as int,
      duration: FnOsFieldUtils.durationSeconds(j),
      poster: j['poster']?.toString() ?? j['posters']?.toString(),
      stillPath: j['still_path']?.toString(),
      parentGuid: j['parent_guid']?.toString(),
      overview: FnOsFieldUtils.overviewFromJson(j),
      rating: FnOsFieldUtils.ratingFromJson(j),
      mediaStream: FnOsMediaStream.fromJson(j['media_stream']),
      isWatched: j['is_watched'] == true || j['is_watched'] == 1 || j['watched'] == true,
    );
  }

  String get displayTitle {
    final t = title.trim();
    if (t.isNotEmpty) return t;
    return '第 $episodeNumber 集';
  }

  String get durationText {
    if (duration <= 0) return '';
    final m = duration ~/ 60;
    if (m < 60) return '$m分钟';
    final h = m ~/ 60;
    final rm = m % 60;
    return '$h小时${rm > 0 ? ' $rm分钟' : ''}';
  }
}

/// 电视剧某一季（type=Season）。
class FnOsSeason {
  final String guid;
  final String title;
  final int seasonNumber;
  final String? overview;
  final String? poster;
  final String? airDate;
  final int? episodeCount;
  final List<FnOsEpisode> episodes;
  final double? rating;

  FnOsSeason({
    required this.guid,
    required this.title,
    this.seasonNumber = 0,
    this.overview,
    this.poster,
    this.airDate,
    this.episodeCount,
    this.episodes = const [],
    this.rating,
  });

  factory FnOsSeason.fromJson(Map<String, dynamic> raw) {
    final j = Map<String, dynamic>.from(raw);
    final title = (j['title'] ?? '').toString();
    final seasonNumber = (j['season_number'] ?? 0) as int;
    return FnOsSeason(
      guid: (j['guid'] ?? '').toString(),
      title: title.isNotEmpty ? title : '第 $seasonNumber 季',
      seasonNumber: seasonNumber,
      overview: FnOsFieldUtils.overviewFromJson(j),
      poster: FnOsFieldUtils.posterFromJson(j),
      airDate: FnOsFieldUtils._dateStr(j),
      episodeCount: j['number_of_episodes'] is int ? j['number_of_episodes'] as int : null,
      rating: FnOsFieldUtils.ratingFromJson(j),
    );
  }

  FnOsSeason copyWith({
    String? title,
    int? seasonNumber,
    String? overview,
    String? poster,
    String? airDate,
    int? episodeCount,
    List<FnOsEpisode>? episodes,
    double? rating,
  }) =>
      FnOsSeason(
        guid: guid,
        title: title ?? this.title,
        seasonNumber: seasonNumber ?? this.seasonNumber,
        overview: overview ?? this.overview,
        poster: poster ?? this.poster,
        airDate: airDate ?? this.airDate,
        episodeCount: episodeCount ?? this.episodeCount,
        episodes: episodes ?? this.episodes,
        rating: rating ?? this.rating,
      );
}

/// 电视剧（type=TV），一部一海报，内含若干季与集。
class FnOsTvSeries {
  final String guid;
  final String title;
  final String? poster;
  final String? backdrop;
  final String? overview;
  final int numberOfSeasons;
  final int numberOfEpisodes;
  final String? firstAirDate;
  final String? lastAirDate;
  final List<FnOsSeason> seasons;
  final double? rating;
  final String? contentRating;
  final int? year;
  final List<String> genres;
  final List<String> productionCountries;
  final FnOsMediaStream mediaStream;
  final String? imdbId;
  final List<FnOsCastMember> cast;
  final bool isFavorite;
  final bool isWatched;
  final String lan;
  final String status;

  FnOsTvSeries({
    required this.guid,
    required this.title,
    this.poster,
    this.backdrop,
    this.overview,
    this.numberOfSeasons = 0,
    this.numberOfEpisodes = 0,
    this.firstAirDate,
    this.lastAirDate,
    this.seasons = const [],
    this.rating,
    this.contentRating,
    this.year,
    this.genres = const [],
    this.productionCountries = const [],
    this.mediaStream = const FnOsMediaStream(),
    this.imdbId,
    this.cast = const [],
    this.isFavorite = false,
    this.isWatched = false,
    this.lan = '',
    this.status = '',
  });

  factory FnOsTvSeries.fromJson(Map<String, dynamic> raw) {
    final j = Map<String, dynamic>.from(raw);
    return FnOsTvSeries(
      guid: (j['guid'] ?? '').toString(),
      title: FnOsFieldUtils.titleFromJson(j),
      poster: FnOsFieldUtils.posterFromJson(j),
      backdrop: FnOsFieldUtils.backdropFromJson(j),
      overview: FnOsFieldUtils.overviewFromJson(j),
      numberOfSeasons: (j['number_of_seasons'] ?? 0) as int,
      numberOfEpisodes: (j['number_of_episodes'] ?? 0) as int,
      firstAirDate: j['first_air_date'] is String ? j['first_air_date'] as String : null,
      lastAirDate: j['last_air_date'] is String ? j['last_air_date'] as String : null,
      rating: FnOsFieldUtils.ratingFromJson(j),
      contentRating: FnOsFieldUtils.contentRatingFromJson(j),
      year: FnOsFieldUtils.yearFromJson(j),
      genres: FnOsFieldUtils.genresFromJson(j),
      productionCountries: FnOsFieldUtils.countriesFromJson(j),
      mediaStream: FnOsMediaStream.fromJson(j['media_stream']),
      imdbId: FnOsFieldUtils.imdbIdFromJson(j),
      cast: FnOsFieldUtils.castFromJson(j),
      isFavorite: j['is_favorite'] == true || j['is_favorite'] == 1,
      isWatched: j['is_watched'] == true || j['is_watched'] == 1 || j['watched'] == true,
      lan: (j['lan'] ?? '').toString(),
      status: (j['status'] ?? '').toString(),
    );
  }

  FnOsTvSeries copyWith({
    String? title,
    String? poster,
    String? backdrop,
    String? overview,
    int? numberOfSeasons,
    int? numberOfEpisodes,
    String? firstAirDate,
    String? lastAirDate,
    List<FnOsSeason>? seasons,
    double? rating,
    String? contentRating,
    int? year,
    List<String>? genres,
    List<String>? productionCountries,
    FnOsMediaStream? mediaStream,
    String? imdbId,
    List<FnOsCastMember>? cast,
    bool? isFavorite,
    bool? isWatched,
  }) =>
      FnOsTvSeries(
        guid: guid,
        title: title ?? this.title,
        poster: poster ?? this.poster,
        backdrop: backdrop ?? this.backdrop,
        overview: overview ?? this.overview,
        numberOfSeasons: numberOfSeasons ?? this.numberOfSeasons,
        numberOfEpisodes: numberOfEpisodes ?? this.numberOfEpisodes,
        firstAirDate: firstAirDate ?? this.firstAirDate,
        lastAirDate: lastAirDate ?? this.lastAirDate,
        seasons: seasons ?? this.seasons,
        rating: rating ?? this.rating,
        contentRating: contentRating ?? this.contentRating,
        year: year ?? this.year,
        genres: genres ?? this.genres,
        productionCountries: productionCountries ?? this.productionCountries,
        mediaStream: mediaStream ?? this.mediaStream,
        imdbId: imdbId ?? this.imdbId,
        cast: cast ?? this.cast,
        isFavorite: isFavorite ?? this.isFavorite,
        isWatched: isWatched ?? this.isWatched,
      );

  String get yearText {
    if (year != null) return year.toString();
    if (firstAirDate != null && firstAirDate!.length >= 4) return firstAirDate!.substring(0, 4);
    return '';
  }
}

/// 影视库内容：电影库返回 movies，电视剧库返回 series。
class FnOsLibraryContent {
  final bool isTv;
  final List<FnOsMovie> movies;
  final List<FnOsTvSeries> series;

  FnOsLibraryContent({
    required this.isTv,
    this.movies = const [],
    this.series = const [],
  });
}

/// 影片详情（play/info 返回的 item 信息）。
class FnOsMovieInfo {
  final String guid;
  final String title;
  final String? poster;
  final int duration;
  final String type;

  FnOsMovieInfo({
    required this.guid,
    required this.title,
    this.poster,
    this.duration = 0,
    this.type = '',
  });

  factory FnOsMovieInfo.fromJson(Map<String, dynamic> j) {
    final item = j['item'] is Map
        ? Map<String, dynamic>.from(j['item'] as Map)
        : <String, dynamic>{};
    return FnOsMovieInfo(
      guid: (j['guid'] ?? item['guid'] ?? '').toString(),
      title: (item['title'] ?? j['title'] ?? '').toString(),
      poster: item['posters'] as String?,
      duration: (item['duration'] ?? 0) as int,
      type: (item['type'] ?? '').toString(),
    );
  }
}

/// 播放直链与鉴权头。
class FnOsPlayUrl {
  final String url;
  final Map<String, String> headers;
  final String title;

  FnOsPlayUrl({
    required this.url,
    required this.headers,
    this.title = '',
  });
}
