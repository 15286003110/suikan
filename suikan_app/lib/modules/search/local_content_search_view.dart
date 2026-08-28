import 'package:flutter/material.dart';

import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/sites.dart';
import 'package:simple_live_app/modules/search/local_content_search_controller.dart';
import 'package:simple_live_app/modules/settings/fnos/fn_os_detail_page.dart';
import 'package:simple_live_app/routes/app_navigation.dart';
import 'package:simple_live_app/widgets/net_image.dart';
import 'package:simple_live_core/simple_live_core.dart';

/// 搜索页「本地内容」tab：自定义直播源频道 + 影视库（电影/剧集）。
class LocalContentSearchView extends StatelessWidget {
  const LocalContentSearchView({Key? key}) : super(key: key);

  LocalContentSearchController get controller =>
      Get.find<LocalContentSearchController>();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        // 搜索范围切换
        Padding(
          padding: AppStyle.edgeInsetsA12.copyWith(bottom: 4),
          child: SegmentedButton<int>(
            segments: const [
              ButtonSegment(
                value: 0,
                label: Text('直播源频道'),
                icon: Icon(Icons.live_tv_outlined, size: 16),
              ),
              ButtonSegment(
                value: 1,
                label: Text('影视库'),
                icon: Icon(Icons.video_library_outlined, size: 16),
              ),
            ],
            selected: {controller.searchMode.value},
            onSelectionChanged: (s) => controller.changeMode(s.first),
            showSelectedIcon: false,
          ),
        ),
        Expanded(
          child: Obx(() {
            if (controller.searching.value) {
              return const Center(child: CircularProgressIndicator());
            }
            if (controller.keyword.isEmpty) {
              return Center(
                child: Text(
                  '输入关键词搜索直播源频道或影视库内容',
                  style: theme.textTheme.bodySmall
                      ?.copyWith(color: theme.colorScheme.outline),
                ),
              );
            }
            if (controller.results.isEmpty) {
              return Center(child: Text('未找到相关内容', style: theme.textTheme.bodyMedium));
            }
            return ListView.separated(
              padding: AppStyle.edgeInsetsA12,
              itemCount: controller.results.length,
              separatorBuilder: (_, __) => AppStyle.divider,
              itemBuilder: (_, i) {
                final r = controller.results[i];
                return ListTile(
                  leading: _cover(r),
                  title: Text(
                    r.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.titleSmall,
                  ),
                  subtitle: Text(
                    r.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  trailing: const Icon(Icons.chevron_right, size: 20),
                  onTap: () => _open(r),
                );
              },
            );
          }),
        ),
      ],
    );
  }

  Widget _cover(LocalSearchResult r) {
    final cover = r.cover;
    if (cover == null || cover.isEmpty) {
      return Container(
        width: 48,
        height: 64,
        decoration: BoxDecoration(
          color: Theme.of(Get.context!).colorScheme.surfaceContainerHighest,
          borderRadius: AppStyle.radius8,
        ),
        child: Icon(
          r.kind == LocalSearchResult.kChannel
              ? Icons.live_tv
              : Icons.movie_outlined,
          size: 22,
          color: Theme.of(Get.context!).colorScheme.primary.withAlpha(120),
        ),
      );
    }
    return ClipRRect(
      borderRadius: AppStyle.radius8,
      child: NetImage(
        cover,
        width: 48,
        height: 64,
        fit: BoxFit.cover,
        httpHeaders: r.httpHeaders,
      ),
    );
  }

  void _open(LocalSearchResult r) {
    switch (r.kind) {
      case LocalSearchResult.kChannel:
        final p = r.payload as ChannelSearchPayload;
        AppNavigator.toLiveRoomDetail(
          site: p.site as Site,
          roomId: p.url,
        );
        break;
      case LocalSearchResult.kMovie:
        final p = r.payload as MovieSearchPayload;
        Get.to(() => FnOsDetailPage(movie: p.movie, server: p.server));
        break;
      case LocalSearchResult.kSeries:
        final p = r.payload as SeriesSearchPayload;
        Get.to(() => FnOsDetailPage(series: p.series, server: p.server));
        break;
    }
  }
}
