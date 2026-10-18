import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/store.dart';

/// 回归：REST 历史行用 `content`（不是 `text`）。
///
/// 之前 `chatItemsFromResume` 只读 `text`，分页抓回的一整页在真机上变成
/// 50 个空气泡（100 行 → 50 个空 item），到顶部后整屏空白。
void main() {
  test('REST 行（content 字段）能解析出有内容的 item', () {
    final rows = [
      {'role': 'user', 'content': '最早的一句话', 'id': 1},
      {'role': 'assistant', 'content': '最早的回复', 'id': 2},
      {'role': 'user', 'content': '第二句', 'id': 3},
      {'role': 'assistant', 'content': '第二句的回复', 'id': 4},
    ];
    final items = chatItemsFromResume(rows);
    expect(items.length, 4);
    expect(items[0].kind, 'user');
    expect(items[0].text, '最早的一句话');
    expect(items[1].kind, 'assistant');
    expect(items[1].text, '最早的回复');
    for (final it in items) {
      expect(it.text.trim(), isNotEmpty);
    }
  });

  test('只有 text 字段时也能解析（session.resume 兼容）', () {
    final items = chatItemsFromResume([
      {'role': 'user', 'text': '来自 text 字段'},
    ]);
    expect(items.single.text, '来自 text 字段');
  });

  test('content 与 text 同时存在时以 content 为准（REST 行）', () {
    final items = chatItemsFromResume([
      {'role': 'user', 'content': '权威内容', 'text': '过期副本'},
    ]);
    expect(items.single.text, '权威内容');
  });

  test('tool 行仍然带完整入参与返回值', () {
    final items = chatItemsFromResume([
      {
        'role': 'tool',
        'name': 'terminal',
        'args': {'command': 'ls'},
        'result': 'file-a\nfile-b',
      },
    ]);
    expect(items.single.kind, 'tool');
    expect(items.single.text, 'terminal');
    expect(items.single.argsText, contains('"command"'));
    expect(items.single.resultText, contains('file-a'));
  });

  // 用户报的问题：历史里看不到"我问过什么" —— clarify 行必须带题目文本。
  test('clarify 历史行显示题目，并带上回答', () {
    final items = chatItemsFromResume([
      {
        'role': 'assistant',
        'content': '',
        'tool_calls': [
          {
            'id': 'call_c1',
            'type': 'function',
            'function': {
              'name': 'clarify',
              'arguments': '{"questions":[{"qid":"q0","question":"清不清缓存？","choices":["先别清","现在就清"]}]}',
            },
          },
        ],
      },
      {
        'role': 'tool',
        'tool_name': 'clarify',
        'tool_call_id': 'call_c1',
        'content': '{"answers":{"q0":"先别清"}}',
      },
    ]);
    expect(items.length, 1);
    expect(items.single.kind, 'tool');
    expect(items.single.text, 'clarify');
    expect(items.single.detail, '清不清缓存？');
    expect(items.single.argsText, contains('先别清'));
    expect(items.single.resultText, contains('"q0"'));
  });
}
