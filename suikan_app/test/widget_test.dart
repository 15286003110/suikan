import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('basic widget harness renders', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: Text('随看'))),
    );

    expect(find.text('随看'), findsOneWidget);
  });
}
