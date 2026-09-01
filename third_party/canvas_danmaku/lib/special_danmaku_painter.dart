import 'dart:math';
import 'dart:ui' as ui;

import 'package:canvas_danmaku/models/danmaku_content_item.dart';
import 'package:canvas_danmaku/models/danmaku_item.dart';
import 'package:flutter/material.dart';

class SpecialDanmakuPainter extends CustomPainter {
  final double progress;
  final List<DanmakuItem> specialDanmakuItems;
  final double fontSize;
  final int fontWeight;
  final String? fontFamily;
  final bool running;
  final int tick;
  final int batchThreshold;

  SpecialDanmakuPainter(
    this.progress,
    this.specialDanmakuItems,
    this.fontSize,
    this.fontWeight,
    this.fontFamily,
    this.running,
    this.tick, {
    this.batchThreshold = 10, // 默认值为10，可以自行调整
  });

  @override
  void paint(Canvas canvas, Size size) {
    var pictureCanvas = canvas;
    var batch = specialDanmakuItems.length > batchThreshold;
    late ui.PictureRecorder pictureRecorder;
    if (batch) {
      pictureRecorder = ui.PictureRecorder();
      pictureCanvas = Canvas(pictureRecorder);
    }
    for (final item in specialDanmakuItems) {
      final elapsed = tick - item.creationTime;
      final content = item.content as SpecialDanmakuContentItem;
      if (elapsed >= 0 && elapsed < content.duration) {
        _paintSpecialDanmaku(pictureCanvas, content, size, elapsed);
      }
    }
    if (batch) {
      canvas.drawPicture(pictureRecorder.endRecording());
    }
  }

  void _paintSpecialDanmaku(
    Canvas canvas,
    SpecialDanmakuContentItem item,
    Size size,
    int elapsed,
  ) {
    // 透明度动画
    //
    // alpha 量化到 32 档：原来只要 alphaTween 非空，颜色就逐帧变化 → 下面
    // 的 color 判等永远不成立 → 每帧都要重建 TextSpan 并 layout()（整段文本
    // 重新排版，还带 Shadow 的模糊重算）。量化后只有跨档才重建，排版次数降到
    // 约 1/30。32 档的透明度渐变肉眼不可辨。
    //
    // alphaTween 为空时 alpha 本就是常量，量化后仍是同一个常量，行为不变。
    final double rawAlpha =
        item.alphaTween?.transform(elapsed / item.duration) ??
        item.color.opacity;
    late final alpha = _quantizeAlpha(rawAlpha);
    final color = item.alphaTween == null
        ? item.color
        : item.color.withOpacity(alpha);
    // 文本
    if (color != item.painterCache?.text?.style?.color) {
      item.painterCache!.text = TextSpan(
        text: item.text,
        style: TextStyle(
          color: color,
          fontSize: item.fontSize,
          fontWeight: FontWeight.values[fontWeight],
          fontFamily: fontFamily,
          shadows: item.hasStroke
              ? [Shadow(color: Colors.black.withOpacity(alpha), blurRadius: 2)]
              : null,
        ),
      );
      item.painterCache!.layout();
    }

    // 路径动画 TODO

    // else 位移动画
    late double dx, dy;
    if (elapsed > item.translationStartDelay) {
      late double translateProgress = item.easingType.transform(
        min(
          1.0,
          (elapsed - item.translationStartDelay) / item.translationDuration,
        ),
      );

      double getOffset(Tween<double> tween) => tween is ConstantTween
          ? tween.begin!
          : tween.transform(translateProgress);

      dx = getOffset(item.translateXTween) * size.width;
      dy = getOffset(item.translateYTween) * size.height;
    } else {
      dx = item.translateXTween.begin! * size.width;
      dy = item.translateYTween.begin! * size.height;
    }

    if (item.matrix != null) {
      canvas.save();
      canvas.translate(dx, dy);
      canvas.transform(item.matrix!.storage);
      item.painterCache!.paint(canvas, Offset.zero);
      canvas.restore();
    } else {
      item.painterCache!.paint(canvas, Offset(dx, dy));
    }
  }

  @override
  bool shouldRepaint(covariant SpecialDanmakuPainter oldDelegate) {
    return true;
  }
}

/// 把 alpha 量化到 32 档（0/32 … 32/32）。
///
/// 返回值恒落在 [0,1]，所以喂给 `Color.withOpacity` 不会触发断言——这一点比
/// 直接透传原始 alpha 更安全（量化顺带兜住了越界值）。
///
/// 非有限值（NaN / Infinity）单独兜底为 1.0（不透明，保证弹幕可见）：
/// `(x * 32).round()` 对 Infinity 会直接抛 `Unsupported operation:
/// Infinity or NaN toInt`，而 `clamp` 对 NaN 是原样返回、拦不住——必须在这里
/// 提前挡掉，否则 painter 里抛异常就是整屏红屏。
double _quantizeAlpha(double alpha) {
  if (!alpha.isFinite) return 1.0;
  return (alpha * 32).round().clamp(0, 32) / 32;
}
