import 'package:flutter_test/flutter_test.dart';
import 'package:simple_live_app/services/ios_video_output_size.dart';

void main() {
  group('calculateIosVideoOutputSize', () {
    test('limits a 4K landscape stream to a landscape iPhone screen', () {
      final result = calculateIosVideoOutputSize(
        sourceWidth: 3840,
        sourceHeight: 2160,
        screenPhysicalWidth: 2796,
        screenPhysicalHeight: 1290,
      );

      expect(result, const IosVideoOutputSize(2292, 1290));
    });

    test('limits a 4K portrait stream to a portrait iPhone screen', () {
      final result = calculateIosVideoOutputSize(
        sourceWidth: 2160,
        sourceHeight: 3840,
        screenPhysicalWidth: 1290,
        screenPhysicalHeight: 2796,
      );

      expect(result, const IosVideoOutputSize(1290, 2292));
    });

    test('does not enlarge a 1080p stream', () {
      final result = calculateIosVideoOutputSize(
        sourceWidth: 1920,
        sourceHeight: 1080,
        screenPhysicalWidth: 2796,
        screenPhysicalHeight: 1290,
      );

      expect(result, const IosVideoOutputSize(1920, 1080));
    });

    test('returns null for incomplete or unusable dimensions', () {
      expect(
        calculateIosVideoOutputSize(
          sourceWidth: 0,
          sourceHeight: 2160,
          screenPhysicalWidth: 2796,
          screenPhysicalHeight: 1290,
        ),
        isNull,
      );
      expect(
        calculateIosVideoOutputSize(
          sourceWidth: 1,
          sourceHeight: 1,
          screenPhysicalWidth: 2796,
          screenPhysicalHeight: 1290,
        ),
        isNull,
      );
      expect(
        calculateIosVideoOutputSize(
          sourceWidth: 3840,
          sourceHeight: 2160,
          screenPhysicalWidth: double.nan,
          screenPhysicalHeight: 1290,
        ),
        isNull,
      );
    });

    test('recalculates against the current screen orientation', () {
      final landscape = calculateIosVideoOutputSize(
        sourceWidth: 3840,
        sourceHeight: 2160,
        screenPhysicalWidth: 2796,
        screenPhysicalHeight: 1290,
      );
      final portrait = calculateIosVideoOutputSize(
        sourceWidth: 3840,
        sourceHeight: 2160,
        screenPhysicalWidth: 1290,
        screenPhysicalHeight: 2796,
      );

      expect(landscape, const IosVideoOutputSize(2292, 1290));
      expect(portrait, const IosVideoOutputSize(1290, 724));
      expect(landscape, isNot(portrait));
    });

    test('caps output to maxLongEdge on a large-screen iPad', () {
      // iPad Pro 12.9" (2732x2048) 看 1080p 源：原逻辑 scale=1.0 不限制，
      // 加 maxLongEdge=1280 后压到 1280x720 纹理上屏（破例降渲染分辨率以降温）。
      final result = calculateIosVideoOutputSize(
        sourceWidth: 1920,
        sourceHeight: 1080,
        screenPhysicalWidth: 2732,
        screenPhysicalHeight: 2048,
        maxLongEdge: 1280,
      );

      expect(result, const IosVideoOutputSize(1280, 720));
    });

    test('does not cap when maxLongEdge is omitted (phones unchanged)', () {
      final result = calculateIosVideoOutputSize(
        sourceWidth: 1920,
        sourceHeight: 1080,
        screenPhysicalWidth: 2796,
        screenPhysicalHeight: 1290,
      );

      // 与既有用例一致：手机不传上限，保持原「不超过屏幕」行为。
      expect(result, const IosVideoOutputSize(1920, 1080));
    });
  });
}
