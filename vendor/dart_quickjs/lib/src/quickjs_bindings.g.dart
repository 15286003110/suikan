// Copyright (c) 2024, the Dart project authors. Please see the AUTHORS file
// for details. All rights reserved. Use of this source code is governed by a
// BSD-style license that can be found in the LICENSE file.

// AUTO GENERATED FILE, DO NOT EDIT.
// Generated QuickJS-ng FFI bindings.

// ignore_for_file: non_constant_identifier_names, camel_case_types

// 【本地化改造 v2】多平台智能加载, 兼容所有 Flutter 版本
// - TV 版 (Flutter 3.24.5 + Android arm32): jniLibs 预编译 libquickjs.so 优先
// - 手机版 (Flutter 3.47 + Android arm64): arm64 路径无预编译 .so, fallback 到
//   DynamicLibrary.process(), native assets 在构建时自动编出 libquickjs.so
// - Windows (Flutter 3.47 + x64): 无预编译 dll, fallback 到 process, native assets 接管
// - 其他平台同理 fallback
// 这样三平台共用一个 vendor/dart_quickjs, core 永远指向 vendor, 不用再切换。
library;

import 'dart:ffi' as ffi;
import 'dart:io' as io;

import 'package:ffi/ffi.dart';

/// 智能加载: 优先按平台尝试预编译库, 失败 fallback 到 process(native assets 接管)
ffi.DynamicLibrary _loadLib() {
  try {
    if (io.Platform.isAndroid) {
      // 方案0: MainActivity 已把 libquickjs.so 从 APK 提取到 filesDir (绝对路径),
      // 直接 dlopen 最可靠 (小米盒子 ROM 不解压 so 到 nativeLibraryDir)。
      // /data/data 可能是 /data/user/0 的 symlink 且部分 ROM 不跟随, 两个路径都试。
      const candidates = <String>[
        '/data/user/0/com.xycz.simple_live_tv/files/libquickjs.so',
        '/data/data/com.xycz.simple_live_tv/files/libquickjs.so',
      ];
      for (final p in candidates) {
        try {
          if (io.File(p).existsSync()) {
            return ffi.DynamicLibrary.open(p);
          }
        } catch (_) {}
      }
      // 方案1: 从 /proc/self/maps 找已加载的 libquickjs.so 绝对路径
      try {
        final maps = io.File('/proc/self/maps').readAsStringSync();
        final m = RegExp(r'(/\S+libquickjs\.so)').firstMatch(maps);
        if (m != null) {
          final p = m.group(1)!;
          if (io.File(p).existsSync()) {
            return ffi.DynamicLibrary.open(p);
          }
        }
      } catch (_) {
        // maps 读取失败, 继续下一方案
      }
      // 方案2: 遍历 LD_LIBRARY_PATH (部分 ROM 会包含 nativeLibraryDir)
      final ld = io.Platform.environment['LD_LIBRARY_PATH'] ?? '';
      for (final dir in ld.split(':')) {
        if (dir.isEmpty) continue;
        final p = '$dir/libquickjs.so';
        try {
          if (io.File(p).existsSync()) {
            return ffi.DynamicLibrary.open(p);
          }
        } catch (_) {
          // 该目录不存在/不可读, 继续尝试下一个
        }
      }
      // 方案3: 裸名 dlopen (某些 ROM 的 linker 搜索路径包含 nativeLibraryDir)
      return ffi.DynamicLibrary.open('libquickjs.so');
    }
    if (io.Platform.isWindows) {
      return ffi.DynamicLibrary.open('quickjs.dll');
    }
    if (io.Platform.isLinux) {
      return ffi.DynamicLibrary.open('libquickjs.so');
    }
    if (io.Platform.isMacOS || io.Platform.isIOS) {
      // iOS 用 static lib, .dylib 不适用; Mac 优先尝试
      try {
        return ffi.DynamicLibrary.open('libquickjs.dylib');
      } catch (_) {
        return ffi.DynamicLibrary.process();
      }
    }
  } catch (_) {
    // 任何预编译库加载失败, fallback 到进程符号表(让 native assets 接管)
  }
  return ffi.DynamicLibrary.process();
}

final ffi.DynamicLibrary _lib = _loadLib();

/// 强制触发 _lib 的初始化 (Dart 顶层变量是惰性的, 只有被读取时才会执行 _loadLib)。
/// 必须在调用任何 external 函数 (如 JS_NewRuntime) 之前调用一次,
/// 确保预编译的 quickjs 库 (Android: libquickjs.so) 已通过 DynamicLibrary.open 加载进进程,
/// 这样 external 函数的 native-assets 回退 (process lookup) 才能找到符号。
/// 否则 Android 上 dlopen(NULL) 搜不到未加载的 .so, 会抛
/// "Couldn't resolve native function 'JS_NewRuntime'..." 异常 (斗鱼/抖音签名失败)。
ffi.DynamicLibrary ensureQuickjsLoaded() => _lib;

// Opaque types for QuickJS structures
final class JSRuntime extends ffi.Opaque {}

final class JSContext extends ffi.Opaque {}

/// JSValue structure for non-NaN-boxing mode (64-bit systems and ARM32 with JS_NAN_BOXING=0)
/// Layout: 8 bytes union + 8 bytes tag = 16 bytes total
///
/// The union contains:
/// - int32 (4 bytes, for integers)
/// - double (8 bytes, for float64)
/// - ptr (4 or 8 bytes depending on platform)
///
/// We access it as a single 64-bit value and extract what we need.
final class JSValue extends ffi.Struct {
  /// The union value - stores int32, float64, or ptr depending on tag
  /// For int32 values: only lower 32 bits are valid
  /// For float64 values: all 64 bits represent the double
  @ffi.Int64()
  external int u;

  /// The tag indicating the type of value stored
  @ffi.Int64()
  external int tag;
}

// ============================================================
// Runtime functions
// ============================================================

late final ffi.Pointer<JSRuntime> Function() JS_NewRuntime = _lib.lookupFunction<
    ffi.Pointer<JSRuntime> Function(),
    ffi.Pointer<JSRuntime> Function()
  >('JS_NewRuntime');

late final void Function(ffi.Pointer<JSRuntime>) JS_FreeRuntime = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<JSRuntime>),
    void Function(ffi.Pointer<JSRuntime>)
  >('JS_FreeRuntime');

late final void Function(ffi.Pointer<JSRuntime>, int) JS_SetMemoryLimit = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<JSRuntime>, ffi.Size),
    void Function(ffi.Pointer<JSRuntime>, int)
  >('JS_SetMemoryLimit');

late final void Function(ffi.Pointer<JSRuntime>, int) JS_SetMaxStackSize = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<JSRuntime>, ffi.Size),
    void Function(ffi.Pointer<JSRuntime>, int)
  >('JS_SetMaxStackSize');

late final void Function(ffi.Pointer<JSRuntime>) JS_RunGC = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<JSRuntime>),
    void Function(ffi.Pointer<JSRuntime>)
  >('JS_RunGC');

// ============================================================
// Context functions
// ============================================================

late final ffi.Pointer<JSContext> Function(ffi.Pointer<JSRuntime>) JS_NewContext = _lib.lookupFunction<
    ffi.Pointer<JSContext> Function(ffi.Pointer<JSRuntime>),
    ffi.Pointer<JSContext> Function(ffi.Pointer<JSRuntime>)
  >('JS_NewContext');

late final void Function(ffi.Pointer<JSContext>) JS_FreeContext = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<JSContext>),
    void Function(ffi.Pointer<JSContext>)
  >('JS_FreeContext');

late final ffi.Pointer<JSRuntime> Function(ffi.Pointer<JSContext>) JS_GetRuntime = _lib.lookupFunction<
    ffi.Pointer<JSRuntime> Function(ffi.Pointer<JSContext>),
    ffi.Pointer<JSRuntime> Function(ffi.Pointer<JSContext>)
  >('JS_GetRuntime');

late final JSValue Function(ffi.Pointer<JSContext>) JS_GetGlobalObject = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>),
    JSValue Function(ffi.Pointer<JSContext>)
  >('JS_GetGlobalObject');

// ============================================================
// Evaluation functions
// ============================================================

late final JSValue Function( ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>, int, ) JS_Eval = _lib.lookupFunction<
    JSValue Function( ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, ffi.Size, ffi.Pointer<Utf8>, ffi.Int32, ),
    JSValue Function( ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>, int, )
  >('JS_Eval');

// ============================================================
// Value functions
// ============================================================

late final void Function(ffi.Pointer<JSContext>, JSValue) JS_FreeValue = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<JSContext>, JSValue),
    void Function(ffi.Pointer<JSContext>, JSValue)
  >('JS_FreeValue');

late final JSValue Function(ffi.Pointer<JSContext>, JSValue) JS_DupValue = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>, JSValue),
    JSValue Function(ffi.Pointer<JSContext>, JSValue)
  >('JS_DupValue');

// ============================================================
// Type conversion functions
// ============================================================

late final ffi.Pointer<Utf8> Function( ffi.Pointer<JSContext>, ffi.Pointer<ffi.Size>, JSValue, bool, ) JS_ToCStringLen2 = _lib.lookupFunction<
    ffi.Pointer<Utf8> Function( ffi.Pointer<JSContext>, ffi.Pointer<ffi.Size>, JSValue, ffi.Bool, ),
    ffi.Pointer<Utf8> Function( ffi.Pointer<JSContext>, ffi.Pointer<ffi.Size>, JSValue, bool, )
  >('JS_ToCStringLen2');

late final void Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>) JS_FreeCString = _lib.lookupFunction<
    ffi.Void Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>),
    void Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>)
  >('JS_FreeCString');

late final int Function(ffi.Pointer<JSContext>, JSValue) JS_ToBool = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue),
    int Function(ffi.Pointer<JSContext>, JSValue)
  >('JS_ToBool');

late final int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int32>, JSValue) JS_ToInt32 = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int32>, JSValue),
    int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int32>, JSValue)
  >('JS_ToInt32');

late final int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue) JS_ToInt64 = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue),
    int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue)
  >('JS_ToInt64');

late final int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Double>, JSValue) JS_ToFloat64 = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Double>, JSValue),
    int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Double>, JSValue)
  >('JS_ToFloat64');

late final int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue) JS_ToBigInt64 = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue),
    int Function(ffi.Pointer<JSContext>, ffi.Pointer<ffi.Int64>, JSValue)
  >('JS_ToBigInt64');

// ============================================================
// Value creation functions
// ============================================================

late final JSValue Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, int) JS_NewStringLen = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, ffi.Size),
    JSValue Function(ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, int)
  >('JS_NewStringLen');

late final JSValue Function(ffi.Pointer<JSContext>, int) JS_NewBigInt64 = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>, ffi.Int64),
    JSValue Function(ffi.Pointer<JSContext>, int)
  >('JS_NewBigInt64');

late final JSValue Function(ffi.Pointer<JSContext>, JSValue) JS_ToString = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>, JSValue),
    JSValue Function(ffi.Pointer<JSContext>, JSValue)
  >('JS_ToString');

// ============================================================
// Object functions
// ============================================================

late final JSValue Function(ffi.Pointer<JSContext>) JS_NewObject = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>),
    JSValue Function(ffi.Pointer<JSContext>)
  >('JS_NewObject');

late final JSValue Function(ffi.Pointer<JSContext>) JS_NewArray = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>),
    JSValue Function(ffi.Pointer<JSContext>)
  >('JS_NewArray');

late final JSValue Function(ffi.Pointer<JSContext>, JSValue, ffi.Pointer<Utf8>) JS_GetPropertyStr = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>, JSValue, ffi.Pointer<Utf8>),
    JSValue Function(ffi.Pointer<JSContext>, JSValue, ffi.Pointer<Utf8>)
  >('JS_GetPropertyStr');

late final JSValue Function(ffi.Pointer<JSContext>, JSValue, int) JS_GetPropertyUint32 = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>, JSValue, ffi.Uint32),
    JSValue Function(ffi.Pointer<JSContext>, JSValue, int)
  >('JS_GetPropertyUint32');

late final int Function( ffi.Pointer<JSContext>, JSValue, ffi.Pointer<Utf8>, JSValue, ) JS_SetPropertyStr = _lib.lookupFunction<
    ffi.Int32 Function( ffi.Pointer<JSContext>, JSValue, ffi.Pointer<Utf8>, JSValue, ),
    int Function( ffi.Pointer<JSContext>, JSValue, ffi.Pointer<Utf8>, JSValue, )
  >('JS_SetPropertyStr');

late final int Function(ffi.Pointer<JSContext>, JSValue, int, JSValue) JS_SetPropertyUint32 = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue, ffi.Uint32, JSValue),
    int Function(ffi.Pointer<JSContext>, JSValue, int, JSValue)
  >('JS_SetPropertyUint32');

late final int Function(ffi.Pointer<JSContext>, JSValue, ffi.Pointer<ffi.Int64>) JS_GetLength = _lib.lookupFunction<
    ffi.Int32 Function(ffi.Pointer<JSContext>, JSValue, ffi.Pointer<ffi.Int64>),
    int Function(ffi.Pointer<JSContext>, JSValue, ffi.Pointer<ffi.Int64>)
  >('JS_GetLength');

// ============================================================
// Function calling
// ============================================================

late final JSValue Function( ffi.Pointer<JSContext>, JSValue, JSValue, int, ffi.Pointer<JSValue>, ) JS_Call = _lib.lookupFunction<
    JSValue Function( ffi.Pointer<JSContext>, JSValue, JSValue, ffi.Int32, ffi.Pointer<JSValue>, ),
    JSValue Function( ffi.Pointer<JSContext>, JSValue, JSValue, int, ffi.Pointer<JSValue>, )
  >('JS_Call');

// ============================================================
// Exception handling
// ============================================================

late final JSValue Function(ffi.Pointer<JSContext>) JS_GetException = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>),
    JSValue Function(ffi.Pointer<JSContext>)
  >('JS_GetException');

late final bool Function(ffi.Pointer<JSContext>) JS_HasException = _lib.lookupFunction<
    ffi.Bool Function(ffi.Pointer<JSContext>),
    bool Function(ffi.Pointer<JSContext>)
  >('JS_HasException');

late final bool Function(ffi.Pointer<JSContext>, JSValue) JS_IsError = _lib.lookupFunction<
    ffi.Bool Function(ffi.Pointer<JSContext>, JSValue),
    bool Function(ffi.Pointer<JSContext>, JSValue)
  >('JS_IsError');

// ============================================================
// Type checking functions
// ============================================================

late final bool Function(ffi.Pointer<JSContext>, JSValue) JS_IsFunction = _lib.lookupFunction<
    ffi.Bool Function(ffi.Pointer<JSContext>, JSValue),
    bool Function(ffi.Pointer<JSContext>, JSValue)
  >('JS_IsFunction');

late final bool Function(JSValue) JS_IsArray = _lib.lookupFunction<
    ffi.Bool Function(JSValue),
    bool Function(JSValue)
  >('JS_IsArray');

// ============================================================
// JSON functions
// ============================================================

late final JSValue Function( ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>, ) JS_ParseJSON = _lib.lookupFunction<
    JSValue Function( ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, ffi.Size, ffi.Pointer<Utf8>, ),
    JSValue Function( ffi.Pointer<JSContext>, ffi.Pointer<Utf8>, int, ffi.Pointer<Utf8>, )
  >('JS_ParseJSON');

late final JSValue Function(ffi.Pointer<JSContext>, JSValue, JSValue, JSValue) JS_JSONStringify = _lib.lookupFunction<
    JSValue Function(ffi.Pointer<JSContext>, JSValue, JSValue, JSValue),
    JSValue Function(ffi.Pointer<JSContext>, JSValue, JSValue, JSValue)
  >('JS_JSONStringify');

// ============================================================
// Promise/Job functions
// ============================================================

late final bool Function(ffi.Pointer<JSRuntime>) JS_IsJobPending = _lib.lookupFunction<
    ffi.Bool Function(ffi.Pointer<JSRuntime>),
    bool Function(ffi.Pointer<JSRuntime>)
  >('JS_IsJobPending');

late final int Function( ffi.Pointer<JSRuntime>, ffi.Pointer<ffi.Pointer<JSContext>>, ) JS_ExecutePendingJob = _lib.lookupFunction<
    ffi.Int32 Function( ffi.Pointer<JSRuntime>, ffi.Pointer<ffi.Pointer<JSContext>>, ),
    int Function( ffi.Pointer<JSRuntime>, ffi.Pointer<ffi.Pointer<JSContext>>, )
  >('JS_ExecutePendingJob');

// ============================================================
// JS Tag constants
// ============================================================

/// JS_TAG values for checking value types
class JsTag {
  // Tags with reference count (negative values)
  static const int bigInt = -9;
  static const int symbol = -8;
  static const int string = -7;
  static const int module = -3;
  static const int functionBytecode = -2;
  static const int object = -1;

  // Tags without reference count (non-negative values)
  static const int int_ = 0;
  static const int bool_ = 1;
  static const int null_ = 2;
  static const int undefined = 3;
  static const int uninitialized = 4;
  static const int catchOffset = 5;
  static const int exception = 6;
  static const int shortBigInt = 7;
  static const int float64 = 8;
}

/// JS_EVAL flags
class JsEvalFlags {
  static const int typeGlobal = 0;
  static const int typeModule = 1;
}

/// Extension methods for JSValue
extension JSValueExtension on JSValue {
  /// Checks if this value is an exception
  bool get isException => tag == JsTag.exception;

  /// Checks if this value is undefined
  bool get isUndefined => tag == JsTag.undefined;

  /// Checks if this value is null
  bool get isNull => tag == JsTag.null_;

  /// Checks if this value is a number
  bool get isNumber => tag == JsTag.int_ || tag == JsTag.float64;

  /// Checks if this value is a string
  bool get isString => tag == JsTag.string;

  /// Checks if this value is a boolean
  bool get isBool => tag == JsTag.bool_;

  /// Checks if this value is an object
  bool get isObject => tag == JsTag.object;

  /// Checks if this value is a BigInt
  bool get isBigInt => tag == JsTag.bigInt;

  /// Checks if this value has reference count (needs to be freed)
  bool get hasRefCount => tag < 0;

  /// Gets the integer value (for int tag)
  /// In non-NaN-boxing mode, int32 is stored in the lower 32 bits of the union
  int get intValue {
    // Extract lower 32 bits as signed int32
    return (u & 0xFFFFFFFF).toSigned(32);
  }

  /// Gets the boolean value (for bool tag)
  bool get boolValue => (u & 0xFFFFFFFF) != 0;

  /// Gets the float value (for float64 tag)
  double get floatValue {
    // The float64 value is stored as bits in u
    final bytes = u.toUnsigned(64);
    final byteData = ffi.sizeOf<ffi.Double>() == 8
        ? (calloc<ffi.Uint64>()..value = bytes)
        : null;
    if (byteData != null) {
      final result = byteData.cast<ffi.Double>().value;
      calloc.free(byteData);
      return result;
    }
    return u.toDouble();
  }
}
