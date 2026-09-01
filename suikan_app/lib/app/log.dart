import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:intl/intl.dart';
import 'package:logger/logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:simple_live_app/app/utils.dart';

class Log {
  static LogFileWriter? logFileWriter;
  static void initWriter() {
    logFileWriter = LogFileWriter();
  }

  static Future<void> disposeWriter() async {
    final writer = logFileWriter;
    logFileWriter = null;
    await writer?.close();
  }

  static Future<void> flushWriter() async {
    await logFileWriter?.flush();
  }

  static void writeLog(content, [Level level = Level.info]) {
    logFileWriter
        ?.write("[${level.name.toUpperCase()}] $_currentTime：$content");
  }

  static RxList<DebugLogModel> debugLogs = <DebugLogModel>[].obs;

  static void addDebugLog(String content, Color? color) {
    if (kReleaseMode) {
      return;
    }
    if (content.contains("请求响应")) {
      content = content.split("\n").join('\n💡 ');
    }
    try {
      debugLogs.insert(0, DebugLogModel(DateTime.now(), content, color: color));
    } catch (e) {
      if (kDebugMode) {
        print(e);
      }
    }
  }

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

  /// 发行版是否把日志打到 stdout/logcat。
  /// 页面内的「调试日志」列表（addDebugLog）本来就只在 debug 收集，
  /// 发行版打出去既看不到又白付字符串拼接 + PrettyPrinter + print 的成本。
  /// 写文件不受影响：那是设置项控制的用户可见功能，且定位线上问题要靠它。
  static bool get _printToConsole => !kReleaseMode;

  static void d(String message, [bool writeFile = true]) {
    addDebugLog(message, Colors.orange);
    if (_printToConsole) {
      logger.d("${DateTime.now().toString()}\n$message");
    }
    if (writeFile) {
      writeLog(message, Level.debug);
    }
  }

  static void i(String message, [bool writeFile = true]) {
    addDebugLog(message, Colors.blue);
    if (_printToConsole) {
      logger.i("${DateTime.now().toString()}\n$message");
    }
    if (writeFile) {
      // 原来这里手写一行 "[INFO] ..." 后紧接着又调 writeLog()，
      // 两行内容完全一样 → 日志文件里每条 info 都重复两遍，去掉手写那行。
      writeLog(message, Level.info);
    }
  }

  /// 错误日志发行版照打：量小，且是线上排障唯一抓手。
  static void e(String message, StackTrace stackTrace,
      [bool writeFile = true]) {
    addDebugLog('$message\r\n\r\n$stackTrace', Colors.red);
    logger.e("${DateTime.now().toString()}\n$message", stackTrace: stackTrace);
    if (writeFile) {
      writeLog("$message\n$stackTrace", Level.error);
    }
  }

  static void w(String message, [bool writeFile = true]) {
    addDebugLog(message, Colors.pink);
    if (_printToConsole) {
      logger.w("${DateTime.now().toString()}\n$message");
    }
    if (writeFile) {
      writeLog(message, Level.warning);
    }
  }

  static void logPrint(dynamic obj, [bool writeFile = true]) {
    addDebugLog(obj.toString(), Colors.red);
    if (writeFile) {
      writeLog(obj, Level.info);
    }
    //logger.e(obj.toString(), obj, obj?.stackTrace);
    if (kDebugMode) {
      print(obj);
    }
  }

  /// 关键日志（数据安全相关，如 Hive 箱的打开/备份/兜底）：**发行版也要输出**。
  /// logPrint 只在 debug 打印，导致线上丢数据时 logcat 一片空白、无从查证
  /// （2026-08-30 覆盖安装清空关注列表就是这么盲查的）。
  static void logAlways(dynamic obj, [bool writeFile = true]) {
    addDebugLog(obj.toString(), Colors.red);
    if (writeFile) {
      writeLog(obj, Level.info);
    }
    debugPrint('[Suikan] $obj');
  }

  static String get _currentTime => Utils.timeFormat.format(DateTime.now());
}

class LogFileWriter {
  late String fileName;
  LogFileWriter() {
    var dt = DateFormat("yyyy-MM-dd HH-mm-ss").format(DateTime.now());
    fileName = "$dt.log";
    initFile();
  }
  IOSink? fileWriter;
  void initFile() async {
    var supportDir = await getApplicationSupportDirectory();
    var logDir = Directory("${supportDir.path}/log");
    if (!await logDir.exists()) {
      await logDir.create();
    }
    var logFile = File("${logDir.path}/$fileName");
    fileWriter = logFile.openWrite(mode: FileMode.append);
    writeSystemInfo();
  }

  void write(String content) {
    fileWriter?.write(content);
    fileWriter?.write("\r\n");
  }

  Future<void> flush() async {
    await fileWriter?.flush();
  }

  Future close() async {
    final writer = fileWriter;
    fileWriter = null;
    if (writer == null) {
      return;
    }
    await writer.flush();
    await writer.close();
  }

  void writeSystemInfo() async {
    DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
    write("System Info:");
    write("Current Time: ${DateTime.now()}");
    write("Platform: ${Platform.operatingSystem}");
    write("Version: ${Platform.operatingSystemVersion}");
    write("Local: ${Platform.localeName}");
    write(
        "App Version: ${Utils.packageInfo.version}+${Utils.packageInfo.buildNumber}");
    if (Platform.isAndroid) {
      write((await deviceInfo.androidInfo).data.toString());
    } else if (Platform.isIOS) {
      write((await deviceInfo.iosInfo).data.toString());
    } else if (Platform.isLinux) {
      write((await deviceInfo.linuxInfo).data.toString());
    } else if (Platform.isMacOS) {
      write((await deviceInfo.macOsInfo).data.toString());
    } else if (Platform.isWindows) {
      write((await deviceInfo.windowsInfo).data.toString());
    }
    write("End System Info");
  }
}

class DebugLogModel {
  final String content;
  final DateTime datetime;
  final Color? color;
  DebugLogModel(this.datetime, this.content, {this.color});
}
