import 'dart:ui' as ui;

import 'package:flutter/material.dart';

import 'models/danmaku_item.dart';
import 'scroll_danmaku_painter.dart';
import 'special_danmaku_painter.dart';
import 'static_danmaku_painter.dart';

/// 把滚动 / 静态 / 高级三层弹幕合成到一个 CustomPaint 里画。
///
/// 原来是 Stack 里三个 RepaintBoundary + 三个全屏 CustomPaint。每个
/// RepaintBoundary 都是一块独立合成层，而 CustomPaint 的 child 是个空
/// Container（在受限约束下会撑满），所以每层都是一整块屏幕大小的显存
/// ——1080p 约 8MB/层，三层约 25MB，每帧还要走三次合成。
///
/// 三层里其实只有两类节奏：
/// - 滚动 / 高级：需要逐帧（共用同一个 AnimationController）；
/// - 静态：完全不依赖动画进度，靠 setState 更新（_staticAnimationController
///   从来没有被启动过，仅作占位）。
/// 合到一层后，重绘由「滚动/高级的驱动源」统一触发，绘制顺序保持
/// 与原 Stack 子顺序一致：滚动 -> 静态 -> 高级。
///
/// **代价（写在这里别让人踩坑）**：静态弹幕原先只在父级 setState 时重绘，
/// 合并后改为逐帧重绘。但它重绘的成本很低——Paragraph 缓存在 DanmakuItem
/// 上（`item.paragraph ??=`），paint 里只是若干次 `drawParagraph`，没有重新
/// 排版；且顶部/底部每条轨道同时只占一条，数量被轨道数封顶（TV 约 20+20）。
/// 没有顶部/底部弹幕时两个 for 循环零次迭代，开销为零。
/// 相比省下的两块整屏合成层，这笔账划算。
class MergedDanmakuPainter extends CustomPainter {
  MergedDanmakuPainter({
    required this.scrollPainter,
    required this.staticPainter,
    required this.specialPainter,
  });

  final ScrollDanmakuPainter scrollPainter;
  final StaticDanmakuPainter staticPainter;
  final SpecialDanmakuPainter specialPainter;

  @override
  void paint(Canvas canvas, Size size) {
    // 顺序即层级，不能改：滚动在下、静态居中、高级在最上。
    scrollPainter.paint(canvas, size);
    staticPainter.paint(canvas, size);
    specialPainter.paint(canvas, size);
  }

  @override
  bool shouldRepaint(covariant MergedDanmakuPainter oldDelegate) {
    return true;
  }
}

/// 建一个合并后的 painter。
///
/// 参数与原来三层各自构造时完全一致，只是集中到一处，方便对照。
MergedDanmakuPainter buildMergedDanmakuPainter({
  required double progress,
  required double staticProgress,
  required List<DanmakuItem> scrollDanmakuItems,
  required List<DanmakuItem> topDanmakuItems,
  required List<DanmakuItem> bottomDanmakuItems,
  required List<DanmakuItem> specialDanmakuItems,
  required int danmakuDurationInSeconds,
  required double fontSize,
  required int fontWeight,
  required String? fontFamily,
  required bool showStroke,
  required double danmakuHeight,
  required bool running,
  required int tick,
  required Map<String, ui.Image> emojiImageCache,
}) {
  return MergedDanmakuPainter(
    scrollPainter: ScrollDanmakuPainter(
      progress,
      scrollDanmakuItems,
      danmakuDurationInSeconds,
      fontSize,
      fontWeight,
      fontFamily,
      showStroke,
      danmakuHeight,
      running,
      tick,
      emojiImageCache,
    ),
    staticPainter: StaticDanmakuPainter(
      staticProgress,
      topDanmakuItems,
      bottomDanmakuItems,
      danmakuDurationInSeconds,
      fontSize,
      fontWeight,
      fontFamily,
      showStroke,
      danmakuHeight,
      running,
      tick,
      emojiImageCache,
    ),
    specialPainter: SpecialDanmakuPainter(
      progress,
      specialDanmakuItems,
      fontSize,
      fontWeight,
      fontFamily,
      running,
      tick,
    ),
  );
}
