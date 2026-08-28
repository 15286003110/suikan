class M3uChannel {
  final String name;
  final String url;
  final String? logo;
  final String? group;
  final String? tvgId;

  M3uChannel({
    required this.name,
    required this.url,
    this.logo,
    this.group,
    this.tvgId,
  });

  Map<String, dynamic> toJson() => {
        'name': name,
        'url': url,
        'logo': logo,
        'group': group,
        'tvgId': tvgId,
      };

  factory M3uChannel.fromJson(Map<String, dynamic> j) => M3uChannel(
        name: (j['name'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        logo: j['logo'] as String?,
        group: j['group'] as String?,
        tvgId: j['tvgId'] as String?,
      );
}

/// 刷新方式：manual=仅手动；interval=每隔 N 小时；daily=每天指定时刻。
const String kRefreshModeManual = 'manual';
const String kRefreshModeInterval = 'interval';
const String kRefreshModeDaily = 'daily';

class M3uSource {
  final String id;
  final String name;
  final String url;
  final bool enabled;
  final int? lastUpdated;
  final int? addedAt; // 添加时间（毫秒），用于首页/分类按添加顺序排序
  final List<M3uChannel> channels;
  final String? sortMode; // 上次使用的排序方式名（CustomSourceSortMode.name）

  /// 自动刷新开关。
  final bool autoRefresh;
  /// 刷新方式：kRefreshModeManual / kRefreshModeInterval / kRefreshModeDaily。
  final String refreshMode;
  /// interval 模式：每隔多少小时刷新一次（默认 6）。
  final int refreshIntervalHours;
  /// daily 模式：每天几点刷新（0-23，默认 4）。
  final int refreshHour;

  M3uSource({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.lastUpdated,
    this.addedAt,
    this.channels = const [],
    this.sortMode,
    this.autoRefresh = false,
    this.refreshMode = kRefreshModeManual,
    this.refreshIntervalHours = 6,
    this.refreshHour = 4,
  });

  int get channelCount => channels.length;

  String get groupCountText {
    final groups = channels.map((e) => e.group ?? '未分组').toSet();
    return '${channels.length} 个频道 · ${groups.length} 个分组';
  }

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'url': url,
        'enabled': enabled,
        'lastUpdated': lastUpdated,
        'addedAt': addedAt,
        'channels': channels.map((e) => e.toJson()).toList(),
        'sortMode': sortMode,
        'autoRefresh': autoRefresh,
        'refreshMode': refreshMode,
        'refreshIntervalHours': refreshIntervalHours,
        'refreshHour': refreshHour,
      };

  factory M3uSource.fromJson(Map<String, dynamic> j) => M3uSource(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        lastUpdated: j['lastUpdated'] as int?,
        addedAt: j['addedAt'] as int?,
        channels: (j['channels'] as List? ?? [])
            .map((e) => M3uChannel.fromJson(e as Map<String, dynamic>))
            .toList(),
        sortMode: j['sortMode'] as String?,
        autoRefresh: (j['autoRefresh'] as bool?) ?? false,
        refreshMode: (j['refreshMode'] as String?) ?? kRefreshModeManual,
        refreshIntervalHours: (j['refreshIntervalHours'] as int?) ?? 6,
        refreshHour: (j['refreshHour'] as int?) ?? 4,
      );
}
