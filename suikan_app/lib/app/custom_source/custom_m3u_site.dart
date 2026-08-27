import 'package:simple_live_core/simple_live_core.dart';

import 'm3u_models.dart';

/// 自定义 M3U 直播源适配为 LiveSite，复用现有分类/详情/播放链路。
/// 频道以「分组」作为分类，房间 ID 直接使用播放地址，
/// 因此 getRoomDetail 可直接回带播放地址，无需二次解析。
class CustomM3uSite extends LiveSite {
  final List<M3uChannel> channels;

  late final Map<String, List<M3uChannel>> _groups;
  late final Map<String, M3uChannel> _byUrl;

  CustomM3uSite({required this.channels}) {
    _groups = <String, List<M3uChannel>>{};
    _byUrl = <String, M3uChannel>{};
    for (final c in channels) {
      final g = (c.group ?? '未分组').trim().isEmpty
          ? '未分组'
          : (c.group!).trim();
      _groups.putIfAbsent(g, () => <M3uChannel>[]).add(c);
      _byUrl[c.url] = c;
    }
  }

  @override
  Future<List<LiveCategory>> getCategores() {
    final children = _groups.keys
        .map(
          (g) => LiveSubCategory(
            id: g,
            name: g,
            parentId: 'custom',
          ),
        )
        .toList();
    return Future.value(
      [
        LiveCategory(
          id: 'all',
          name: '全部',
          children: children,
        ),
      ],
    );
  }

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) {
    final list = _groups[category.id] ?? <M3uChannel>[];
    final items = list
        .map(
          (c) => LiveRoomItem(
            roomId: c.url,
            title: c.name.isEmpty ? c.url : c.name,
            cover: c.logo ?? '',
            userName: c.name.isEmpty ? c.url : c.name,
          ),
        )
        .toList();
    return Future.value(LiveCategoryResult(hasMore: false, items: items));
  }

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) {
    final c = _byUrl[roomId];
    return Future.value(
      LiveRoomDetail(
        roomId: roomId,
        title: c?.name ?? roomId,
        cover: c?.logo ?? '',
        userName: c?.name ?? roomId,
        userAvatar: c?.logo ?? '',
        online: 0,
        status: true,
        url: roomId,
      ),
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) {
    return Future.value(
      [
        LivePlayQuality(quality: '原画', data: 'origin'),
      ],
    );
  }

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) {
    return Future.value(LivePlayUrl(urls: [detail.url]));
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) =>
      Future.value(true);
}
