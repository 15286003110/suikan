// P0-6 等价性验证：复用 JsRuntime 与「每次新建 runtime」的输出是否一致。
// 跑法：dart run tool/verify_sign_reuse.dart
import 'package:dart_quickjs/dart_quickjs.dart';
import 'package:simple_live_core/src/scripts/douyin_sign.dart';

const ua =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/125.0.0.0 Safari/537.36';
const query =
    'device_platform=webapp&aid=6383&channel=channel_pc_web&pc_client_type=1&version_code=180800&webcast_sdk_version=1.3.0&room_id=7361234567890&sub_room_id=&sub_channel_id=&did_rule=3&user_unique_id=1234567890&device_type=&ac=&identity=audience';

/// 每次新建 runtime（改动前的行为）
String freshABogus() {
  final rt = JsRuntime(memoryLimit: 32 * 1024 * 1024, maxStackSize: 512 * 1024);
  try {
    rt.eval(DouyinSign.kABogus);
    return rt.eval("getABogus('$query', '$ua')").toString();
  } finally {
    rt.dispose();
  }
}

String freshMsStub() {
  final rt = JsRuntime(memoryLimit: 4 * 1024 * 1024, maxStackSize: 128 * 1024);
  try {
    rt.eval(DouyinSign.kWebMsSDK);
    return rt.eval("getMSSDKSignature('$stub','$ua')").toString();
  } finally {
    rt.dispose();
  }
}

// 复用 runtime（改动后的行为）
JsRuntime? rtA;
JsRuntime? rtM;

String reusedABogus() {
  final rt = rtA ??= (JsRuntime(
        memoryLimit: 32 * 1024 * 1024,
        maxStackSize: 512 * 1024,
      )..eval(DouyinSign.kABogus));
  final r = rt.eval("getABogus('$query', '$ua')").toString();
  rt.runGC();
  return r;
}

String reusedMsStub() {
  final rt = rtM ??= (JsRuntime(
        memoryLimit: 4 * 1024 * 1024,
        maxStackSize: 128 * 1024,
      )..eval(DouyinSign.kWebMsSDK));
  final r = rt.eval("getMSSDKSignature('$stub','$ua')").toString();
  rt.runGC();
  return r;
}

const stub = 'd3b07384d113edec49eaa6238ad5ff00';

void report(String name, List<String> fresh, List<String> reused) {
  final freshUnique = fresh.toSet();
  final reusedUnique = reused.toSet();
  final deterministic = freshUnique.length == 1 && reusedUnique.length == 1;
  print('--- $name ---');
  print('  fresh  : ${fresh.map((s) => s.length).toList()} 条, '
      '去重后 ${freshUnique.length} 种');
  print('  reused : ${reused.map((s) => s.length).toList()} 条, '
      '去重后 ${reusedUnique.length} 种');
  if (deterministic) {
    final same = freshUnique.single == reusedUnique.single;
    print('  ${same ? "✅ 完全一致" : "❌ 不一致"}（函数确定，可做精确比对）');
    if (!same) {
      print('    fresh =${freshUnique.single}');
      print('    reused=${reusedUnique.single}');
    }
  } else {
    // 不确定（含时间/随机分量）：比对长度与字符集是否落在同一分布
    final all = {...fresh, ...reused};
    final lens = all.map((s) => s.length).toSet();
    print('  函数含随机/时间分量，改为比对形态：长度集合=$lens');
    print('  ${lens.length == 1 ? "✅ 两种模式长度一致" : "⚠️ 长度有差异"}');
  }
  print('  样例 fresh[0]=${fresh.first}');
  print('  样例 reused[0]=${reused.first}');
}

void main() {
  const n = 5;
  final freshA = <String>[for (var i = 0; i < n; i++) freshABogus()];
  final reusedA = <String>[for (var i = 0; i < n; i++) reusedABogus()];
  report('a_bogus (getABogus)', freshA, reusedA);

  final freshM = <String>[for (var i = 0; i < n; i++) freshMsStub()];
  final reusedM = <String>[for (var i = 0; i < n; i++) reusedMsStub()];
  report('X-MS-STUB (getMSSDKSignature)', freshM, reusedM);

  print('');
  // 4MB 的那个 runtime 长期持有，最怕攒垃圾撞上 memoryLimit，
  // 所以这里跑 200 次看会不会中途失败。
  print('--- 交错调用（复用 runtime 上连续 200 次）---');
  var ok = 0;
  Object? firstError;
  for (var i = 0; i < 200; i++) {
    try {
      final a = reusedABogus();
      final m = reusedMsStub();
      if (a.length == 164 && m.length == 16) ok++;
    } catch (e) {
      firstError ??= e;
    }
  }
  print('  ${ok == 200 ? "✅" : "❌"} 200/200 次均返回合法长度（实际 $ok）'
      '${firstError == null ? "" : " 首个错误=$firstError"}');

  // 走真实入口再验一次，确认接线没写错
  final viaApi = DouyinSign.getSignatureForParams(
    DouyinSign.getDefaultSignatureParams('7361234567890', '1234567890'),
  );
  final viaApi2 = DouyinSign.getSignatureForParams(
    DouyinSign.getDefaultSignatureParams('7361234567890', '1234567890'),
  );
  print('  真实入口 getSignatureForParams 两次: '
      'len=${viaApi.length}/${viaApi2.length} '
      '${viaApi.isNotEmpty && viaApi2.isNotEmpty ? "✅" : "❌"}');
  final signedUrl = DouyinSign.getAbogusUrl(
    'https://live.douyin.com/webcast/im/fetch/?aid=6383&room_id=123',
    ua,
  );
  print('  真实入口 getAbogusUrl 含 a_bogus: '
      '${signedUrl.contains("a_bogus=") ? "✅" : "❌"}');

  rtA?.dispose();
  rtM?.dispose();
}
