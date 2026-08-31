import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_app/app/app_style.dart';
import 'package:simple_live_app/app/fnos/fn_os_models.dart';
import 'package:simple_live_app/modules/live_room/live_room_controller.dart';

/// 点播（影视）播放页的「集数」tab：
/// 季切换 + 集宫格；已看集带勾、当前播放集高亮；点集即切播。
class VodEpisodePanel extends StatefulWidget {
  final LiveRoomController controller;
  const VodEpisodePanel({super.key, required this.controller});

  @override
  State<VodEpisodePanel> createState() => _VodEpisodePanelState();
}

class _VodEpisodePanelState extends State<VodEpisodePanel> {
  int _seasonIndex = 0;

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final seasons = widget.controller.vodSeasons;
      if (seasons.isEmpty) {
        return const Center(child: Text('暂无剧集'));
      }
      if (_seasonIndex >= seasons.length) _seasonIndex = 0;
      final season = seasons[_seasonIndex];
      final episodes = season.episodes;

      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── 季切换 ───────────────────────────────
          SizedBox(
            height: 40,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: AppStyle.edgeInsetsH12,
              itemCount: seasons.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (_, i) {
                final s = seasons[i];
                final selected = i == _seasonIndex;
                return ChoiceChip(
                  label: Text(
                    s.title.isNotEmpty ? s.title : '第 ${s.seasonNumber} 季',
                  ),
                  selected: selected,
                  onSelected: (_) {
                    setState(() => _seasonIndex = i);
                    if (s.episodes.isEmpty) {
                      widget.controller.selectVodSeason(s);
                    }
                  },
                );
              },
            ),
          ),
          AppStyle.vGap8,
          // ── 集宫格 ───────────────────────────────
          Expanded(
            child: episodes.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : GridView.builder(
                    padding: AppStyle.edgeInsetsA12,
                    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: 5,
                      mainAxisSpacing: 8,
                      crossAxisSpacing: 8,
                      childAspectRatio: 1.1,
                    ),
                    itemCount: episodes.length,
                    itemBuilder: (_, i) => _EpisodeCell(
                      episode: episodes[i],
                      active: widget.controller.roomId == episodes[i].guid,
                      onTap: () => widget.controller.playVodEpisode(episodes[i]),
                    ),
                  ),
          ),
        ],
      );
    });
  }
}

class _EpisodeCell extends StatelessWidget {
  final FnOsEpisode episode;
  final bool active;
  final VoidCallback onTap;
  const _EpisodeCell({
    required this.episode,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = episode.title.trim().isNotEmpty
        ? episode.title.trim()
        : '第 ${episode.episodeNumber} 集';
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        decoration: BoxDecoration(
          color: active
              ? theme.colorScheme.primary
              : theme.colorScheme.surfaceContainerHighest,
          borderRadius: BorderRadius.circular(8),
          border: active
              ? Border.all(color: theme.colorScheme.primary, width: 1.5)
              : null,
        ),
        child: Stack(
          children: [
            Center(
              child: Padding(
                padding: const EdgeInsets.all(4),
                child: Text(
                  label,
                  textAlign: TextAlign.center,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: active
                        ? theme.colorScheme.onPrimary
                        : theme.textTheme.bodySmall?.color,
                    fontWeight: active ? FontWeight.bold : null,
                  ),
                ),
              ),
            ),
            if (episode.isWatched && !active)
              const Positioned(
                right: 3,
                top: 3,
                child: Icon(Icons.check_circle,
                    size: 12, color: Colors.green),
              ),
          ],
        ),
      ),
    );
  }
}
