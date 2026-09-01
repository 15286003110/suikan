import 'package:extended_image/extended_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_screenutil/flutter_screenutil.dart';

class NetImage extends StatelessWidget {
  /// 图片缓存上限，启动早期调一次。
  ///
  /// 框架默认 1000 张 / 100MB。一张 1920x1080 的封面解码后约 8MB，
  /// 首页/分类页翻几屏就把 100MB 吃满 → 不停淘汰 + 重解码，
  /// 在盒子这类弱 CPU 上表现为焦点移动时封面反复闪烁。
  /// 网格封面已按 400px 宽解码（单张 ~0.36MB），48MB 可容纳上百张，
  /// 观感无差别而常驻内存降到一半以下。
  static void configureImageCaches() {
    const int maxImages = 300;
    const int maxBytes = 48 << 20;

    final ImageCache globalCache = PaintingBinding.instance.imageCache;
    globalCache.maximumSize = maxImages;
    globalCache.maximumSizeBytes = maxBytes;
  }

  final String picUrl;
  final double? width;
  final double? height;
  final BoxFit? fit;
  final double borderRadius;
  final int? cacheWidth;
  final Map<String, String>? httpHeaders;
  const NetImage(this.picUrl,
      {this.width,
      this.height,
      this.fit = BoxFit.cover,
      this.borderRadius = 0,
      this.cacheWidth,
      this.httpHeaders,
      Key? key})
      : super(key: key);

  @override
  Widget build(BuildContext context) {
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
          cacheWidth: cacheWidth,
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
        cacheWidth: cacheWidth,
        headers: httpHeaders,
        shape: BoxShape.rectangle,
        borderRadius: BorderRadius.circular(borderRadius),
        loadStateChanged: (e) {
          if (e.extendedImageLoadState == LoadState.loading) {
            return const SizedBox();
          }
          if (e.extendedImageLoadState == LoadState.failed) {
            return Icon(
              Icons.broken_image,
              color: Colors.grey,
              size: 24.w,
            );
          }
          return null;
        },
      ),
    );
  }
}
