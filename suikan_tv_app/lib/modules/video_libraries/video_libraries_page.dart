import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_style.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_tv_app/app/fnos/fn_os_service.dart';
import 'package:simple_live_tv_app/modules/settings/fnos/fn_os_browse_page.dart';
import 'package:simple_live_tv_app/widgets/focus_card.dart';
import 'package:simple_live_tv_app/widgets/live_room_grid_layout.dart';
import 'package:simple_live_tv_app/widgets/shadow_card.dart';

/// 电影电视页：列出所有添加的飞牛影视服务器，按添加日期升序，点击进入影视库浏览。
class VideoLibrariesPage extends StatelessWidget {
  const VideoLibrariesPage({Key? key}) : super(key: key);

  static const double _detailsExtent = 72;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        title: const Text('电影电视'),
      ),
      body: Obx(() {
        final servers = [...FnOsService.instance.servers]
          ..sort((a, b) => a.addedAt.compareTo(b.addedAt));
        if (servers.isEmpty) {
          return Center(
            child: Text(
              '还没有影视库\n请在「设置 - NAS影视库」添加飞牛影视服务器',
              textAlign: TextAlign.center,
              style: AppStyle.textStyleWhite,
            ),
          );
        }
        return LayoutBuilder(
          builder: (context, constraints) {
            final layout = LiveRoomGridLayout.resolve(
              constraints.maxWidth,
              detailsExtent: _detailsExtent,
            );
            return GridView.builder(
              padding: AppStyle.edgeInsetsA12,
              gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: layout.crossAxisCount,
                mainAxisSpacing: LiveRoomGridLayout.defaultSpacing,
                crossAxisSpacing: LiveRoomGridLayout.defaultSpacing,
                mainAxisExtent: layout.mainAxisExtent,
              ),
              itemCount: servers.length,
              itemBuilder: (_, i) {
                final server = servers[i];
                return FocusCard(
                  onActivate: () =>
                      Get.to(() => FnOsBrowsePage(server: server)),
                  child: _ServerCard(
                    server: server,
                    onTap: () => Get.to(() => FnOsBrowsePage(server: server)),
                  ),
                );
              },
            );
          },
        );
      }),
    );
  }
}

class _ServerCard extends StatelessWidget {
  final FnOsServer server;
  final VoidCallback onTap;
  const _ServerCard({required this.server, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final title = server.name.isNotEmpty ? server.name : server.address;
    return Semantics(
      button: true,
      label: title,
      child: ShadowCard(
        onTap: onTap,
        child: Padding(
          padding: AppStyle.edgeInsetsA8,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.movie_outlined,
                size: 36,
                color: theme.colorScheme.primary,
              ),
              AppStyle.vGap8,
              Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (server.name.isNotEmpty)
                Text(
                  server.address,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
