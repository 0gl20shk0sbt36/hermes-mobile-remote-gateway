import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/store.dart';

import 'attachment_delivery_test.dart' show RecordingGateway;

/// 回归：一次回复只能渲染一遍。
/// 症状（桌面版与手机都遇到过）：流式的那份留在屏幕上，message.complete 又追加一整份，
/// 于是同一段文字出现两次。
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

  void ev(String type, [Map<String, dynamic> payload = const {}]) {
    gw.events.add({'type': type, 'session_id': 'session-a', 'payload': payload});
  }

  test('streamed reply is settled by message.complete, not appended twice', () async {
    store.items.add(ChatItem.user('run it'));
    ev('message.start');
    ev('message.delta', {'text': 'Hello'});
    ev('message.complete', {'text': 'Hello world'});
    await Future<void>.delayed(Duration.zero);

    final replies = store.items.where((i) => i.kind == 'assistant').toList();
    expect(replies.length, 1, reason: '同一段流式文字不能被收尾再追加一份');
    expect(replies.single.text, 'Hello world');
  });

  // 回归（2026-10-16）：Hermes 一轮里可以"先说一句 → 调工具 → 再说一句"。
  // 旧实现把工具之后的文字塞回工具行**上面**那条气泡，于是顺序全乱、
  // 中间那段旁白直接消失（表现：工具调用全堆在一起）。
  test('text after a tool row opens its own bubble in order', () async {
    store.items.add(ChatItem.user('run it'));
    ev('message.start');
    ev('message.delta', {'text': 'Let me check'});
    ev('tool.start', {'name': 'execute_code', 'tool_id': 't1'});
    ev('tool.complete', {'tool_id': 't1', 'summary': 'ok'});
    ev('message.delta', {'text': 'All done.'});
    ev('message.complete', {'text': 'All done.'});
    await Future<void>.delayed(Duration.zero);

    expect(store.items.map((i) => i.kind).toList(),
        ['user', 'assistant', 'tool', 'assistant']);
    expect(store.items[1].text, 'Let me check');
    expect(store.items[3].text, 'All done.');
  });

  test('message.interim seals the segment before the tool row', () async {
    store.items.add(ChatItem.user('run it'));
    ev('message.start');
    ev('tool.start', {'name': 'terminal', 'tool_id': 't1'});
    ev('tool.complete', {'tool_id': 't1'});
    // 工具前后旁白：already_streamed=false → 服务端把这段封成自己一条。
    ev('message.interim', {'text': 'Now the second step', 'already_streamed': false});
    ev('message.delta', {'text': 'Done.'});
    ev('message.complete', {'text': 'Done.'});
    await Future<void>.delayed(Duration.zero);

    expect(store.items.map((i) => i.kind).toList(),
        ['user', 'tool', 'assistant', 'assistant']);
    expect(store.items[2].text, 'Now the second step');
    expect(store.items[3].text, 'Done.');
  });

  test('tool rows carry full args and the return value', () async {
    store.items.add(ChatItem.user('run it'));
    ev('tool.start', {
      'name': 'terminal',
      'tool_id': 't1',
      'context': 'ls -la',
      'args_text': '{"command":"ls -la"}',
    });
    ev('tool.complete', {
      'tool_id': 't1',
      'summary': 'ok',
      'result_text': 'total 8\ndrwxr-xr-x 2 yyx yyx 4096 .',
    });
    await Future<void>.delayed(Duration.zero);

    final row = store.items.singleWhere((i) => i.kind == 'tool');
    expect(row.argsText, contains('ls -la'));
    expect(row.resultText, contains('drwxr-xr-x'));
    expect(row.done, isTrue);
  });


  // 回归（2026-10-16，用户报"两次输出的问题好像还在"）：
  // 三种已知的"同一段文字出现两遍"来源，各钉一条。
  test('a replayed delta chunk is not appended twice', () async {
    store.items.add(ChatItem.user('go'));
    ev('message.start');
    const chunk = '这是一段会被重放的长文本，长度超过去重阈值。';
    ev('message.delta', {'text': chunk});
    ev('message.delta', {'text': chunk}); // 重连/重放：同一段又发一遍
    ev('message.complete', {'text': chunk});
    await Future<void>.delayed(Duration.zero);

    final replies = store.items.where((i) => i.kind == 'assistant').toList();
    expect(replies.length, 1);
    expect(replies.single.text, chunk, reason: '重放的 chunk 不许追加成两遍');
  });

  test('message.complete does not re-add text an interim already delivered', () async {
    store.items.add(ChatItem.user('go'));
    ev('message.start');
    ev('message.interim', {'text': '结论：一切正常。', 'already_streamed': false});
    ev('message.complete', {'text': '结论：一切正常。'}); // 同一个答案又来一遍
    await Future<void>.delayed(Duration.zero);

    final replies = store.items.where((i) => i.kind == 'assistant').toList();
    expect(replies.length, 1, reason: 'interim 交付过的文字，complete 不许再写一条');
    expect(replies.single.text, '结论：一切正常。');
  });

  test('appendInflight does not duplicate the bubble the transcript already has', () async {
    final items = chatItemsFromResume([
      {'role': 'user', 'text': 'hi'},
      {'role': 'assistant', 'text': '正在处理这件事，先读一下文件。'},
    ]);
    // 恢复时服务端的 inflight 尾巴常常就是刚落盘的那一段
    appendInflight(items, {'assistant': '正在处理这件事，先读一下文件。'});
    expect(items.where((i) => i.kind == 'assistant').length, 1);

    // 真的是新的一段时才该新增
    appendInflight(items, {'assistant': '好了，做完了。'});
    expect(items.where((i) => i.kind == 'assistant').length, 2);
  });

  test('a second turn still gets its own bubble', () async {
    store.items.add(ChatItem.user('one'));
    ev('message.start');
    ev('message.delta', {'text': 'first'});
    ev('message.complete', {'text': 'first'});
    await Future<void>.delayed(Duration.zero);
    store.items.add(ChatItem.user('two'));
    ev('message.start');
    ev('message.delta', {'text': 'second'});
    ev('message.complete', {'text': 'second'});
    await Future<void>.delayed(Duration.zero);

    final replies = store.items.where((i) => i.kind == 'assistant').toList();
    expect(replies.map((r) => r.text).toList(), ['first', 'second']);
  });
}
