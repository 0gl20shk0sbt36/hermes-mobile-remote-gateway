import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';
import 'package:hermes_mobile/store.dart';

import 'attachment_delivery_test.dart' show RecordingGateway;

/// 回归：用户往上翻看历史时，底部的新输出不许把视线顶走；贴底时要能跟着最新。
///
/// 列表是**倒序**（reverse: true，坐标从底部量）：最新气泡在底部，它变长会把上面的内容
/// 推着走。所以 ChatView 只在"没在滚动（拖动/惯性都不算 = isScrollingNotifier 为 false）、
/// 且不在底部"时，把增长量补回滚动位置。
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

  /// 多帧推进：补偿是"逐帧收敛"的（Sliver 的 maxScrollExtent 晚一帧才算进新内容），
  /// 只 pump 两三帧看不到效果。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  ScrollPosition posOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).last).position;

  /// 用 `ObjectKey(ChatItem)` 定位"用户正在看的那一条"：与它在列表里的索引无关
  /// （新增一条会让索引整体偏移，按 index 取就会量到别的气泡）。
  Finder tileFinder(ChatItem item) =>
      find.byWidgetPredicate((w) => w is MessageTile && identical(w.item, item));

  /// 取"最靠近屏幕中心"的可见气泡：它一定在视口里，稍许偏移也不会被回收。
  /// （ListView.builder 只构建可见项，取第一个可见项在偏移后可能已经被回收。）
  ChatItem centeredItem(WidgetTester tester) {
    final size = tester.getSize(find.byType(ListView));
    final mid = size.height / 2;
    ChatItem? best;
    var bestDist = double.infinity;
    for (final it in store.items) {
      final finder = tileFinder(it);
      if (finder.evaluate().isEmpty) continue;
      final rect = tester.getRect(finder);
      final dist = (rect.center.dy - mid).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = it;
      }
    }
    if (best == null) throw StateError('没有任何可见的 MessageTile');
    return best;
  }

  Rect tileOf(WidgetTester tester, ChatItem item) {
    // 按 item 身份找（列表里用的是每项一个 GlobalKey，不是 ObjectKey）。
    final finder = find.byWidgetPredicate((w) => w is MessageTile && identical(w.item, item));
    return tester.getRect(finder);
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    store.items.add(ChatItem.user('开始'));
    for (var i = 0; i < 30; i++) {
      store.items.add(ChatItem.assistant('第 $i 条消息，内容够长就能把列表撑起来。' * 2));
    }
    // 真机上 ChatView 挂在 HomePage 的 ListenableBuilder 里；测试照这个结构，
    // 否则 store 通知不会触发重建，也就量不到"内容变长"。
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(listenable: store, builder: (_, _) => ChatView(store: store)))));

    await settle(tester);
    // 往上翻，离开底部（反列表里 offset 越大越靠上）
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await settle(tester);
  }

  testWidgets('a new item does not move the reader who is scrolled up', (tester) async {
    await mount(tester);
    final reading = centeredItem(tester);
    final before = tileOf(tester, reading);

    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't1', 'context': 'df -h /'},
    });
    await settle(tester);

    // 容差 16px：屏幕外的部分按估算布局，补偿量与真实增长量会有一行内的残差。
    expect((tileOf(tester, reading).top - before.top).abs(), lessThan(16.0),
        reason: '底部新增内容时，正在看的那条消息不能被顶走');
    expect(posOf(tester).pixels, greaterThan(40), reason: '补的是偏移，不该把用户拽回底部');
  });

  testWidgets('streaming text does not move the reader either', (tester) async {
    await mount(tester);
    final reading = centeredItem(tester);
    final before = tileOf(tester, reading);

    for (var i = 0; i < 3; i++) {
      gw.events.add({
        'type': 'message.delta',
        'session_id': 'session-a',
        'payload': {'text': '流式追加的第 $i 段文字，会把最后一条气泡撑高。' * 2},
      });
      await settle(tester);
    }

    expect(tileOf(tester, reading).top, closeTo(before.top, 2.0),
        reason: '流式输出同样不许顶走正在看历史的人');
  });

  testWidgets('a reader parked at the bottom keeps following the newest output', (tester) async {
    await mount(tester);
    // 回到底部：反列表里 offset 0 就是最新
    await tester.drag(find.byType(ListView), const Offset(0, -6000));
    await settle(tester);
    expect(posOf(tester).pixels, lessThan(40));

    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't2', 'context': 'ls'},
    });
    await settle(tester);

    expect(posOf(tester).pixels, lessThan(40), reason: '在底部就应该自然跟随最新');
  });
}
