import 'dart:math' as math;

/// iPad 专用渲染纹理上限（按源最长边，单位像素）。
///
/// 背景：原「原画省电优化」逻辑 scale=min(1.0, 屏/源) 只缩小不放大，
/// 对 iPad（直播源常 < 屏幕物理像素）永不触发，故 iPad 一直按全源分辨率
/// 渲染并放大上屏，GPU 负载高、发热明显。
///
/// 用户于 2026-09-03 明确破例允许 iPad **降渲染分辨率**以降温（原则2例外，仅限 iPad）。
/// 本上限使 iPad 在开启「原画省电优化」时把渲染纹理压到不超过此值，
/// 从而显著降低 GPU 纹理处理/上采样负载。
///
/// 值越大越清晰、降温越弱；越小越糊、降温越强。1280≈把 1080p 源降到 720p 纹理上屏。
/// 若觉得画面过糊可上调到 1600，若仍热可下调。
const int kIosRenderCapLongEdge = 1280;

class IosVideoOutputSize {
  final int width;
  final int height;

  const IosVideoOutputSize(this.width, this.height);

  @override
  bool operator ==(Object other) {
    return other is IosVideoOutputSize &&
        other.width == width &&
        other.height == height;
  }

  @override
  int get hashCode => Object.hash(width, height);

  @override
  String toString() => '${width}x$height';
}

IosVideoOutputSize? calculateIosVideoOutputSize({
  required int sourceWidth,
  required int sourceHeight,
  required double screenPhysicalWidth,
  required double screenPhysicalHeight,
  /// iPad 专用：渲染纹理最长边上限（见 [kIosRenderCapLongEdge]）。
  /// 为 null 时按原逻辑（仅缩小到屏幕物理像素，不放大）。
  int? maxLongEdge,
}) {
  if (sourceWidth < 2 ||
      sourceHeight < 2 ||
      !screenPhysicalWidth.isFinite ||
      !screenPhysicalHeight.isFinite ||
      screenPhysicalWidth < 2 ||
      screenPhysicalHeight < 2) {
    return null;
  }

  final scale = math.min(
    1.0,
    math.min(
      screenPhysicalWidth / sourceWidth,
      screenPhysicalHeight / sourceHeight,
    ),
  );
  // iPad 破例：在「不超过屏幕」之外，再叠加一个绝对上限（可低于源分辨率），
  // 把渲染纹理压下来以降温。手机不传此参数，行为保持原样。
  final effectiveScale = maxLongEdge == null
      ? scale
      : math.min(scale, maxLongEdge / math.max(sourceWidth, sourceHeight));

  int toEvenDimension(double value) {
    final roundedDown = value.floor();
    if (roundedDown <= 2) {
      return 2;
    }
    return roundedDown.isEven ? roundedDown : roundedDown - 1;
  }

  return IosVideoOutputSize(
    toEvenDimension(sourceWidth * effectiveScale),
    toEvenDimension(sourceHeight * effectiveScale),
  );
}
