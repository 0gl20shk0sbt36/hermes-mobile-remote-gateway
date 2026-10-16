import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';
import 'package:hermes_mobile/store.dart';

import 'attachment_delivery_test.dart' show RecordingGateway;

/// 回归（2026-10-16）：用户往上翻看历史时，底部的新输出不许把视线顶走。
///
/// 反列表里正文越长，现有内容的偏移就越大 —— 视口不动就等于"被顶上去"。
/// 修法是：内容变长时把同样的像素补回滚动位置（ChatView._onStore）。
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

  Future<void> settle(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
  }

  ScrollPosition posOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).last).position;

  /// 取当前屏幕上"居中"那条消息的矩形：它就是用户眼睛盯着的地方。
  Rect midTile(WidgetTester tester) {
    final n = find.byType(MessageTile).evaluate().length;
    return tester.getRect(find.byType(MessageTile).at(n ~/ 2));
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    store.items.add(ChatItem.user('开始'));
    for (var i = 0; i < 30; i++) {
      store.items.add(ChatItem.assistant('第 $i 条消息，内容够长就能把列表撑起来。' * 2));
    }
    // 真机上 ChatView 挂在 HomePage 的 ListenableBuilder 里；测试也要照这个结构，
    // 否则 store 通知不会触发重建，量不到"内容变长"。
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(listenable: store, builder: (_, _) => ChatView(store: store)))));

    await settle(tester);
    // 往上翻，离开底部
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await settle(tester);
  }

  testWidgets('a new item does not move the reader who is scrolled up', (tester) async {
    await mount(tester);
    final before = midTile(tester);

    // 新的工具行（= 底部多了一块内容）
    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't1', 'context': 'df -h /'},
    });
    await settle(tester);

    // 容差 16px：列表对"屏幕外"的部分是**估算**布局，补偿量与真实增长量会有约一行的残差；
    // 关键是别整块跳（修前会跳一整个新内容的量，几十像素起）。
    expect((midTile(tester).top - before.top).abs(), lessThan(16.0),
        reason: '底部新增内容时，正在看的那条消息不能整块被顶走');
    expect(posOf(tester).pixels, greaterThan(40), reason: '补偿只改偏移，不该把用户拽回底部');
  });

  testWidgets('streaming text does not move the reader either', (tester) async {
    await mount(tester);
    final before = midTile(tester);

    for (var i = 0; i < 3; i++) {
      gw.events.add({
        'type': 'message.delta',
        'session_id': 'session-a',
        'payload': {'text': '流式追加的第 $i 段文字，会把最后一条气泡撑高。' * 2},
      });
      await settle(tester);
    }

    expect(midTile(tester).top, closeTo(before.top, 2.0), reason: '流式输出同样不许顶走正在看历史的人');
  });

  testWidgets('a reader parked at the bottom keeps following the newest output', (tester) async {
    await mount(tester);
    // 回到底部：offset 0 就是最新
    await tester.drag(find.byType(ListView), const Offset(0, -4000));
    await settle(tester);
    expect(posOf(tester).pixels, lessThan(40));

    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't2', 'context': 'ls'},
    });
    await settle(tester);
    expect(posOf(tester).pixels, lessThan(40), reason: '在底部就应该自然跟随，不做补偿');
  });
}
