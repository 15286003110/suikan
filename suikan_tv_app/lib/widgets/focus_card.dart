import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:simple_live_tv_app/app/app_focus_node.dart';

/// TV 遥控焦点卡片：包裹任意可聚焦卡片，获得焦点时显示高亮边框 + 阴影。
/// 解决自定义源/影视库浏览页（从手机端移植）遥控选中看不到位置的问题。
class FocusCard extends StatefulWidget {
  final Widget child;
  final double radius;
  const FocusCard({super.key, required this.child, this.radius = 10});

  @override
  State<FocusCard> createState() => _FocusCardState();
}

class _FocusCardState extends State<FocusCard> {
  final AppFocusNode _focusNode = AppFocusNode();

  @override
  void dispose() {
    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Focus(
      focusNode: _focusNode,
      child: Obx(() {
        final focused = _focusNode.isFoucsed.value;
        return Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(widget.radius),
            border: Border.all(
              color: focused
                  ? Theme.of(context).colorScheme.primary
                  : Colors.transparent,
              width: focused ? 3 : 0,
            ),
            boxShadow: focused
                ? [
                    BoxShadow(
                      blurRadius: 14,
                      color: Theme.of(context)
                          .colorScheme
                          .primary
                          .withAlpha(90),
                    ),
                  ]
                : null,
          ),
          child: widget.child,
        );
      }),
    );
  }
}
