import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/models/db/follow_user.dart';

class MultiRoomItem {
  final Site site;
  final String roomId;
  final String userName;
  final String face;

  const MultiRoomItem({
    required this.site,
    required this.roomId,
    required this.userName,
    required this.face,
  });

  /// 站点已删除/未注册（自定义源/影视库被删后仍在关注列表里）时返回 null，
  /// 由调用方过滤，避免 `Sites.allSites[...]!` 对 null 断言崩溃。
  static MultiRoomItem? fromFollow(FollowUser item) {
    final site = Sites.siteForKey(item.siteId);
    if (site == null) return null;
    return MultiRoomItem(
      site: site,
      roomId: item.roomId,
      userName: item.userName,
      face: item.face,
    );
  }

  String get key => "${site.id}_$roomId";
}
