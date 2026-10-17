import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';
import 'package:hermes_mobile/store.dart';

import 'attachment_delivery_test.dart' show RecordingGateway;

/// 回归：用户往上翻看历史时，底部的新输出不许把视线顶走、也不许跳。
///
/// 现在的模型是**正序列表**（reverse: false，坐标从顶部量）：往末尾追加内容
/// 从结构上就不会移动已有内容；只有"贴着底部"时才跟随最新。
/// 注意：正序里 `pixels == maxScrollExtent` 才是底部（旧的反列表里是 0）。
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

  /// 离底部还有多少像素（正序列表）。
  double fromBottom(WidgetTester tester) {
    final pos = posOf(tester);
    return pos.maxScrollExtent - pos.pixels;
  }

  /// 用户正在看的地方 = 滚动偏移。正序列表里"末尾追加内容"不该改变它。
  /// （不再按 MessageTile 的中间 index 取矩形：新增一项会让 index 漂移，量的就是别的气泡了。）

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
    final beforePixels = posOf(tester).pixels;

    // 新的工具行（= 底部多了一块内容）
    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't1', 'context': 'df -h /'},
    });
    await settle(tester);

    expect((posOf(tester).pixels - beforePixels).abs(), lessThan(1.0),
        reason: '末尾追加内容时，看历史的人的滚动位置不能变');
    expect(fromBottom(tester), greaterThan(40), reason: '不该把用户拽回底部');
  });

  testWidgets('streaming text does not move the reader either', (tester) async {
    await mount(tester);
    final beforePixels = posOf(tester).pixels;

    for (var i = 0; i < 3; i++) {
      gw.events.add({
        'type': 'message.delta',
        'session_id': 'session-a',
        'payload': {'text': '流式追加的第 $i 段文字，会把最后一条气泡撑高。' * 2},
      });
      await settle(tester);
    }

    expect(posOf(tester).pixels, closeTo(beforePixels, 1.0),
        reason: '流式输出同样不许移动正在看历史的人');
  });

  testWidgets('a reader parked at the bottom keeps following the newest output', (tester) async {
    await mount(tester);
    // 回到底部：正序列表里 maxScrollExtent 就是最新
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await settle(tester);
    expect(fromBottom(tester), lessThan(40));

    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't2', 'context': 'ls'},
    });
    await settle(tester);
    expect(fromBottom(tester), lessThan(40), reason: '在底部就应该跟到最新');
  });
}
