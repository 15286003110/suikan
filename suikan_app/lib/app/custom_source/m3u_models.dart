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

class M3uSource {
  final String id;
  final String name;
  final String url;
  final bool enabled;
  final int? lastUpdated;
  final List<M3uChannel> channels;

  M3uSource({
    required this.id,
    required this.name,
    required this.url,
    this.enabled = true,
    this.lastUpdated,
    this.channels = const [],
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
        'channels': channels.map((e) => e.toJson()).toList(),
      };

  factory M3uSource.fromJson(Map<String, dynamic> j) => M3uSource(
        id: (j['id'] as String?) ?? '',
        name: (j['name'] as String?) ?? '',
        url: (j['url'] as String?) ?? '',
        enabled: (j['enabled'] as bool?) ?? true,
        lastUpdated: j['lastUpdated'] as int?,
        channels: (j['channels'] as List? ?? [])
            .map((e) => M3uChannel.fromJson(e as Map<String, dynamic>))
            .toList(),
      );
}
