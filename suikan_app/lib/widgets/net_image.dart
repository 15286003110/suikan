import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';

class NetImage extends StatelessWidget {
  static const liveCoverCacheName = 'simple_live_live_covers';

  /// 图片缓存上限，启动早期调一次。
  ///
  /// 框架默认 1000 张 / 100MB。一张 1920x1080 的直播封面解码后约 8MB，
  /// 网格页翻两屏就把 100MB 吃满 → 不停淘汰 + 重解码，滑回去要重新等图。
  /// 收到 64MB 后配合「按显示尺寸解码」，单张降到 ~0.5MB，
  /// 64MB 能装上百张，观感无差别而常驻内存明显下降。
  ///
  /// 注意：extended_image 的命名缓存是**独立的 ImageCache 实例**，
  /// 不吃 PaintingBinding 的全局上限，必须单独配。
  static void configureImageCaches() {
    const int maxImages = 400;
    const int maxBytes = 64 << 20;

    final ImageCache globalCache = PaintingBinding.instance.imageCache;
    globalCache.maximumSize = maxImages;
    globalCache.maximumSizeBytes = maxBytes;

    imageCaches
        .putIfAbsent(liveCoverCacheName, () => ImageCache())
      ..maximumSize = 120
      ..maximumSizeBytes = 32 << 20;
  }

  /// 网格封面：按父布局给到的真实宽度解码，而不是按原图分辨率。
  ///
  /// 封面/海报原图动辄 1920x1080，解码后约 8MB/张，一屏十几张就把图片缓存
  /// 吃满，表现为滑动回去要重新等图 + 常驻内存居高不下。
  ///
  /// 两点保证不会改坏画面：
  /// 1. 只传 [cacheWidth] 一维。ExtendedResizeImage 默认策略是
  ///    ResizeImagePolicy.exact，宽高都传会按 BoxFit.fill 拉伸变形；
  ///    只传一维则保持原图宽高比。
  /// 2. 默认 allowUpscaling=false，原图比显示尺寸小时不会被放大，
  ///    最差情况就是按原图解码，与改动前完全一致。
  ///
  /// 解码宽度量化到 64px 台阶：缩放窗口时不至于每变 1px 就产生新缓存 key
  /// 而反复重解码。向上取整，保证不会解码得比需要的更小。
  static Widget cover({
    required String url,
    double? width,
    double? height,
    BoxFit? fit,
    double borderRadius = 0,
    Map<String, String>? httpHeaders,
    VoidCallback? onLoadFailed,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final double boxWidth = constraints.maxWidth;
        final int? decodeWidth = boxWidth.isFinite && boxWidth > 0
            ? _quantizeDecodeWidth(
                boxWidth * MediaQuery.devicePixelRatioOf(context))
            : null;
        return NetImage(
          url,
          width: width ?? double.infinity,
          height: height,
          fit: fit ?? BoxFit.cover,
          borderRadius: borderRadius,
          cacheWidth: decodeWidth,
          httpHeaders: httpHeaders,
          onLoadFailed: onLoadFailed,
        );
      },
    );
  }

  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;
  final int? cacheWidth;
  final int? cacheHeight;
  final bool clearMemoryCacheWhenDispose;
  final String? imageCacheName;
  final Duration? cacheMaxAge;
  final bool cache;
  final Map<String, String>? httpHeaders;
  final VoidCallback? onLoadFailed;
  const NetImage(this.picUrl,
      {this.width,
      this.height,
      this.fit = BoxFit.cover,
      this.borderRadius = 0,
      this.cacheWidth,
      this.cacheHeight,
      this.clearMemoryCacheWhenDispose = false,
      this.imageCacheName,
      this.cacheMaxAge,
      this.cache = true,
      this.httpHeaders,
      this.onLoadFailed,
      Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
    if (picUrl.isEmpty) {
      return Image.asset(
        'assets/images/logo.png',
        width: width,
        height: height,
      );
    }
    var pic = picUrl;
    if (pic.startsWith("//")) {
      pic = 'https:$pic';
    }
    if (pic.startsWith("asset://")) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(borderRadius),
        child: Image.asset(
          pic.substring("asset://".length),
          fit: fit,
          height: height,
          width: width,
        ),
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: ExtendedImage.network(
        pic,
        fit: fit,
        height: height,
        width: width,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(borderRadius),
        cache: cache,
        cacheWidth: cacheWidth,
        cacheHeight: cacheHeight,
        clearMemoryCacheWhenDispose: clearMemoryCacheWhenDispose,
        imageCacheName: imageCacheName,
        cacheMaxAge: cacheMaxAge,
        headers: httpHeaders,
        loadStateChanged: (e) {
          if (e.extendedImageLoadState == LoadState.loading) {
            // 撑满容器尺寸的浅灰占位，而不是一个居中的 24px 灰点。图片区域
            // 在加载完成前有完整的轮廓，观感更好，也避免图片「啪」地弹出。
            // 尺寸直接复用图片的 width/height，保证与最终画面完全一致。
            return Container(
              width: width,
              height: height,
              color: Colors.black12,
              alignment: Alignment.center,
              child: const Icon(Icons.image, color: Colors.grey, size: 24),
            );
          }
          if (e.extendedImageLoadState == LoadState.failed) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              onLoadFailed?.call();
            });
            return Container(
              width: width,
              height: height,
              color: Colors.black12,
              alignment: Alignment.center,
              child: const Icon(
                Icons.broken_image,
                color: Colors.grey,
                size: 24,
              ),
            );
          }
          return null;
        },
      ),
    );
  }
}

/// 解码宽度量化到 64 的整数倍（向上取整）。
int _quantizeDecodeWidth(double devicePixels, [int step = 64]) {
  if (!devicePixels.isFinite || devicePixels <= 0) {
    return step;
  }
  return (devicePixels / step).ceil() * step;
}
