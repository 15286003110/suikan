import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:logger/logger.dart';

class Log {
  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  static Logger logger = Logger(
    printer: PrettyPrinter(
      methodCount: 0,
      errorMethodCount: 8,
      lineLength: 120,
      colors: true,
      printEmojis: true,
      dateTimeFormat: DateTimeFormat.none,
    ),
  );

  /// 发行版不打日志到 logcat：TV 盒子 CPU 弱，PrettyPrinter 的格式化 + print
  /// 是纯浪费（TV 没有日志页面，打出去也没人看）。
  /// 错误 e() 保留：量小，线上排障要靠它。
  /// 需要发行版也输出的（数据安全相关）请走 logAlways()。
  static bool get _printToConsole => !kReleaseMode;

  static void d(String message) {
    if (!_printToConsole) {
      return;
    }
    logger.d("${DateTime.now().toString()}\n$message");
  }

  static void i(String message) {
    if (!_printToConsole) {
      return;
    }
    logger.i("${DateTime.now().toString()}\n$message");
  }

  static void e(String message, StackTrace stackTrace) {
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
  }

  static void w(String message) {
    if (!_printToConsole) {
      return;
    }
    logger.w("${DateTime.now().toString()}\n$message");
  }

  static void logPrint(dynamic obj) {
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      print(obj);
    }
  }

  /// 关键日志（数据安全相关，如 Hive 箱的打开/备份/兜底）：**发行版也要输出**。
  /// logPrint 只在 debug 打印，导致线上丢数据时 logcat 一片空白、无从查证
  /// （2026-08-30 覆盖安装清空关注列表就是这么盲查的）。
  static void logAlways(dynamic obj) {
    debugPrint('[Suikan] $obj');
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
