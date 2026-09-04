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
  /// 用户是否手动选过季。
  /// ⚠️ 必须保留：此前用「当前播放集所在季」无条件覆盖显示季，导致只要当前
  /// 集在第一季（默认就是），点第二季/第三季就切不动（手动选择被覆盖）。
  /// 手动选择优先，点了具体某集后（切集成功）再回到自动跟随。
  bool _userPickedSeason = false;
  /// 最近一次触发过"懒加载集列表"的季 guid（避免 build 反复请求）。
  String? _requestedSeasonGuid;

  /// 定位当前播放集所在的季；找不到（季集未加载完）返回 -1。
  int _locateSeasonIndex(List<FnOsSeason> seasons, String currentGuid) {
    for (var i = 0; i < seasons.length; i++) {
      if (seasons[i].episodes.any((e) => e.guid == currentGuid)) {
        return i;
      }
    }
    return -1;
  }

  @override
  Widget build(BuildContext context) {
    return Obx(() {
      final seasons = widget.controller.vodSeasons;
      if (seasons.isEmpty) {
        return const Center(child: Text('暂无剧集'));
      }
      // 切集/进入时跟随当前播放集所在季；手动切季后保持手动选择。
      final located = _locateSeasonIndex(seasons, widget.controller.roomId);
      var safeIndex = _seasonIndex;
      if (safeIndex >= seasons.length || safeIndex < 0) {
        safeIndex = 0;
      }
      final displayIndex = _userPickedSeason
          ? safeIndex
          : (located >= 0 ? located : safeIndex);
      _seasonIndex = safeIndex;
      final season = seasons[displayIndex];
      final episodes = season.episodes;
      // 当前季集未加载 → 懒加载（进入时若当前集在其它季，保证能展开该季）。
      if (episodes.isEmpty && _requestedSeasonGuid != season.guid) {
        _requestedSeasonGuid = season.guid;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.controller.selectVodSeason(season);
        });
      }

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
                final selected = i == displayIndex;
                return ChoiceChip(
                  label: Text(
                    s.title.isNotEmpty ? s.title : '第 ${s.seasonNumber} 季',
                  ),
                  selected: selected,
                  onSelected: (_) {
                    setState(() {
                      _seasonIndex = i;
                      _userPickedSeason = true;
                    });
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
                      onTap: () {
                        // 切集后回到"跟随当前播放集所在季"
                        if (_userPickedSeason) {
                          setState(() => _userPickedSeason = false);
                        }
                        widget.controller.playVodEpisode(episodes[i]);
                      },
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
    // 集格子显示纯集数（1/2/3…），与主流播放器一致；编号异常时退回标题。
    final label = episode.episodeNumber > 0
        ? '${episode.episodeNumber}'
        : (episode.title.trim().isNotEmpty
            ? episode.title.trim()
            : '?');
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
