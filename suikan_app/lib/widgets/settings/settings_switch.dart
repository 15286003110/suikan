import 'package:flutter/material.dart';
import 'package:simple_live_app/app/app_style.dart';

/// 设置页开关行（紧凑版，2026-09-05 用户反馈优化）。
///
/// 不用 SwitchListTile 的原因：系统 SwitchListTile 的最小触控尺寸固定
/// （约 59×40），开关图形偏大、与单行标题不协调；且无法缩放 trailing。
/// 这里自组 ListTile + Transform.scale(0.75) 缩小开关，行高收紧：
/// 标题与开关视觉比例协调，多数项保持一行（subtitle 仅留给少数必需说明）。
class SettingsSwitch extends StatelessWidget {
  final bool value;
  final String title;
  final String? subtitle;
  final Function(bool) onChanged;
  const SettingsSwitch({
    required this.value,
    required this.title,
    this.subtitle,
    required this.onChanged,
    super.key,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Widget titleWidget = Text(
      title,
      style: theme.textTheme.bodyLarge,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
    return ListTile(
      dense: true,
      visualDensity: const VisualDensity(horizontal: -4, vertical: -2),
      contentPadding: AppStyle.edgeInsetsL16.copyWith(right: 12),
      title: subtitle == null
          ? titleWidget
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                titleWidget,
                if (subtitle != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Text(
                      subtitle!,
                      style: theme.textTheme.bodySmall!
                          .copyWith(color: Colors.grey),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
            ),
      trailing: Transform.scale(
        scale: 0.75,
        child: Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ),
      onTap: () => onChanged(!value),
    );
  }
}
