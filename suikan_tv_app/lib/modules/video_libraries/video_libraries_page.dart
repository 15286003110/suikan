import 'package:flutter/material.dart';
import 'package:simple_live_tv_app/modules/settings/fnos/fn_os_browse_page.dart';

/// 电影电视页：聚合所有飞牛影视服务器的全部内容（电影 + 剧集），
/// 顶部含「全部/电影/电视剧」类型切换 + 排序 + 刷新，默认按添加日期升序。
/// 直接复用 FnOsBrowsePage 的聚合模式（server 传 null）。
class VideoLibrariesPage extends StatelessWidget {
  const VideoLibrariesPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return const FnOsBrowsePage(embedded: false);
  }
}
