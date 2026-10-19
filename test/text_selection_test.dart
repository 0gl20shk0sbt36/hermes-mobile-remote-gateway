import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';
import 'package:hermes_mobile/l10n.dart';
import 'package:hermes_mobile/store.dart';

import 'attachment_delivery_test.dart' show RecordingGateway;

/// 设计要求：长按 = 原生文本选择（能选一部分），而不是把整条消息一次性复制走。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late RecordingGateway gw;
  late HermesStore store;

  setUp(() {
    gw = RecordingGateway();
    store = HermesStore(gw)..sid = 'session-a';
  });
  tearDown(() {
    store.dispose();
    gw.close();
  });

  Future<void> pumpChat(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: ChatView(store: store),
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('the transcript is wrapped in a SelectionArea', (tester) async {
    store.items.add(ChatItem.assistant('hello world'));
    await pumpChat(tester);
    expect(find.byType(SelectionArea), findsWidgets, reason: '正文必须可自由选择');
  });

  testWidgets('message bubbles no longer hijack long-press to copy everything', (tester) async {
    store.items.add(ChatItem.user('copy me'));
    store.items.add(ChatItem.assistant('**bold** answer'));
    await pumpChat(tester);
    for (final tile in find.byType(MessageTile).evaluate()) {
      final hijack = find.descendant(
        of: find.byWidget(tile.widget),
        matching: find.byWidgetPredicate((w) => w is GestureDetector && w.onLongPress != null),
      );
      expect(hijack, findsNothing, reason: '长按不应再被"复制全部"吃掉');
    }
  });

  testWidgets('user bubbles keep a one-tap copy-all action', (tester) async {
    store.items.add(ChatItem.user('copy me'));
    await pumpChat(tester);
    expect(find.byTooltip(L10n.t('نسخ')), findsWidgets, reason: '一键复制整条仍应可用');
  });
}
