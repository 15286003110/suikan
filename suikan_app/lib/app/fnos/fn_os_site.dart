import 'package:simple_live_core/simple_live_core.dart';

import 'fn_os_models.dart';
import 'fn_os_service.dart';

/// 飞牛影视站点适配：把单个 fnOS 服务器上的影片当作「直播间」接入现有播放链路。
/// 浏览（影视库/影片列表）由 FnOsService 直接驱动，这里仅实现播放所需的几个方法：
/// getRoomDetail 取标题/封面，getPlayUrls 回带 media/range 直链与鉴权头。
class FnOsSite extends LiveSite {
  final FnOsServer server;

  FnOsSite({required this.server});

  @override
  Future<List<LiveCategory>> getCategores() => Future.value(const []);

  @override
  Future<LiveCategoryResult> getCategoryRooms(
    LiveSubCategory category, {
    int page = 1,
  }) =>
      Future.value(LiveCategoryResult(hasMore: false, items: []));

  @override
  Future<LiveRoomDetail> getRoomDetail({required String roomId}) async {
    final info = await FnOsService.instance.getItemInfo(server, roomId);
    final poster = FnOsService.instance.posterUrl(server, info.poster);
    return LiveRoomDetail(
      roomId: roomId,
      title: info.title,
      cover: poster,
      userName: info.title,
      userAvatar: poster,
      online: 0,
      status: true,
      url: roomId,
    );
  }

  @override
  Future<List<LivePlayQuality>> getPlayQualites({
    required LiveRoomDetail detail,
  }) =>
      Future.value([
        LivePlayQuality(quality: '原画', data: 'origin'),
      ]);

  @override
  Future<LivePlayUrl> getPlayUrls({
    required LiveRoomDetail detail,
    required LivePlayQuality quality,
  }) async {
    final r = await FnOsService.instance.getPlayUrl(server, detail.roomId);
    return LivePlayUrl(urls: [r.url], headers: r.headers);
  }

  @override
  Future<bool> getLiveStatus({required String roomId}) =>
      Future.value(true);
}
