import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';
import 'package:hermes_mobile/store.dart';

import 'attachment_delivery_test.dart' show RecordingGateway;

/// 滚动模型回归（照 use-stick-to-bottom / RN maintainVisibleContentPosition 的语义）：
///
/// * 列表**正序**（顶部坐标）⇒ 末尾追加内容物理上不会移动上方内容；
/// * 只有"距底 ≤ 70px（贴底）"时才跟随最新；
/// * 打开会话时落在最新一条。
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

  /// 多帧推进：跟随是逐帧收敛的（Sliver 的 maxScrollExtent 晚一帧才算进新内容）。
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.pump(const Duration(milliseconds: 16));
    }
  }

  ScrollPosition posOf(WidgetTester tester) =>
      tester.state<ScrollableState>(find.byType(Scrollable).last).position;

  /// 距底部还有多少像素（正序列表：maxScrollExtent - pixels）。
  double fromBottom(WidgetTester tester) {
    final pos = posOf(tester);
    return pos.maxScrollExtent - pos.pixels;
  }

  Finder tileFinder(ChatItem item) =>
      find.byWidgetPredicate((w) => w is MessageTile && identical(w.item, item));

  /// 取"最靠近视口中心"的可见气泡（偏移后它不会被回收）。
  ChatItem centeredItem(WidgetTester tester) {
    final mid = tester.getSize(find.byType(ListView)).height / 2;
    ChatItem? best;
    var bestDist = double.infinity;
    for (final it in store.items) {
      final finder = tileFinder(it);
      if (finder.evaluate().isEmpty) continue;
      final dist = (tester.getRect(finder).center.dy - mid).abs();
      if (dist < bestDist) {
        bestDist = dist;
        best = it;
      }
    }
    if (best == null) throw StateError('没有任何可见的 MessageTile');
    return best;
  }

  Future<void> mount(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    store.items.add(ChatItem.user('开始'));
    for (var i = 0; i < 30; i++) {
      store.items.add(ChatItem.assistant('第 $i 条消息，内容够长就能把列表撑起来。' * 2));
    }
    await tester.pumpWidget(MaterialApp(
        home: Scaffold(
            body: ListenableBuilder(listenable: store, builder: (_, _) => ChatView(store: store)))));
    await settle(tester);
  }

  testWidgets('打开会话时停在最新一条（底部）', (tester) async {
    await mount(tester);
    expect(fromBottom(tester), lessThan(1.0), reason: '一进来就该在最后一条消息处');
  });

  testWidgets('看历史时新到的内容不移动视线（也不跳）', (tester) async {
    await mount(tester);
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await settle(tester);
    expect(fromBottom(tester), greaterThan(200), reason: '前置条件：确实离开了底部');

    final reading = centeredItem(tester);
    final beforeRect = tester.getRect(tileFinder(reading));
    final beforePixels = posOf(tester).pixels;

    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't1', 'context': 'df -h /'},
    });
    await settle(tester);
    debugPrint('DBG items=${store.items.length} idx=${store.items.indexOf(reading)} kinds=${store.items.map((e) => e.kind).toList().sublist(store.items.length - 3)}');

    expect((posOf(tester).pixels - beforePixels).abs(), lessThan(1.0),
        reason: '顶部坐标下追加内容不该改变滚动偏移');
    expect((tester.getRect(tileFinder(reading)).top - beforeRect.top).abs(), lessThan(2.0),
        reason: '正在看的那条不能移动');
  });

  testWidgets('流式输出同样不移动看历史的人', (tester) async {
    await mount(tester);
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await settle(tester);

    final reading = centeredItem(tester);
    final beforeRect = tester.getRect(tileFinder(reading));

    for (var i = 0; i < 3; i++) {
      gw.events.add({
        'type': 'message.delta',
        'session_id': 'session-a',
        'payload': {'text': '流式追加的第 $i 段文字，会把最后一条气泡撑高。' * 2},
      });
      await settle(tester);
    }

    expect((tester.getRect(tileFinder(reading)).top - beforeRect.top).abs(), lessThan(2.0),
        reason: '流式输出不许移动正在看历史的人');
  });

  testWidgets('贴着底部时跟随最新输出', (tester) async {
    await mount(tester);
    expect(fromBottom(tester), lessThan(1.0));

    gw.events.add({
      'type': 'tool.start',
      'session_id': 'session-a',
      'payload': {'name': 'terminal', 'tool_id': 't2', 'context': 'ls'},
    });
    await settle(tester);

    expect(fromBottom(tester), lessThan(40), reason: '贴底就该一直跟着最新');
  });
}
