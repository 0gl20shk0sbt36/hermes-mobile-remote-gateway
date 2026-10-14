import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/design.dart';

void main() {
  testWidgets('long RTL popup keeps decision buttons on screen at 320px', (tester) async {
    tester.view.physicalSize = const Size(320, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(MaterialApp(home: MediaQuery(
      data: const MediaQueryData(size: Size(320, 560), textScaler: TextScaler.linear(1.3)),
      child: Directionality(textDirection: TextDirection.rtl,
        child: Scaffold(body: DDialog(title: '确认切换模型',
          body: List.filled(30, '这是一条很长的警告信息，关于上下文容量与切换模型的成本。').join('\n'),
          actions: [DBtn(label: '取消', onPressed: () {}), DBtn(label: '切换模型', onPressed: () {})],
        )),
      ),
    )));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.text('切换模型')).bottom, lessThan(560));
    expect(find.byType(SingleChildScrollView), findsOneWidget);
  });
}
