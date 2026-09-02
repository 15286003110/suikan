import 'dart:io';
import 'dart:ui' show PlatformDispatcher;

class PlatformUtils {
  PlatformUtils._();

  static bool get isMobileApp => Platform.isAndroid || Platform.isIOS;

  /// 是否 iPad（iOS 平板）。
  ///
  /// 用屏幕最短边的逻辑像素判断：iPad 系列最小的是 mini（744），而 iPhone
  /// 最大的机型也只有 430 上下，600 这个阈值能把两者干净分开，且不需要
  /// 异步探测（device_info_plus 的 isiPad 是异步的，会带来初始化时序问题）。
  ///
  /// 仅对 iOS 生效 —— Android 平板不算，多开同屏不向 Android 开放。
  static bool get isIPad {
    if (!Platform.isIOS) {
      return false;
    }
    final views = PlatformDispatcher.instance.views;
    if (views.isEmpty) {
      return false;
    }
    final view = views.first;
    final size = view.physicalSize / view.devicePixelRatio;
    final shortestSide = size.width < size.height ? size.width : size.height;
    return shortestSide >= 600;
  }

  /// 多开同屏的可用范围：桌面端 + iPad。
  ///
  /// 手机 / iPhone / 电视端不开放 —— 手机上多路直播既费电又难看清，电视端
  /// 是遥控器操作、没有多窗口入口。原本的写法是 `!isMobileApp`，会把 iPad
  /// 一并关掉（iPad 属于 iOS），这里把平板单独放开。
  static bool get supportsInlineMultiRoom =>
      Platform.isWindows || Platform.isMacOS || Platform.isLinux || isIPad;
}
