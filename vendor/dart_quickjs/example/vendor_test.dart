import 'package:dart_quickjs/dart_quickjs.dart';
void main() {
  try {
    final rt = JsRuntime();
    final r = rt.eval('6 * 7');
    print('Dart3.5: JsRuntime OK, eval(6*7) = $r');
    rt.dispose();
  } catch (e) {
    print('Dart3.5: 失败: ${e.toString().split('\n').first}');
  }
}
