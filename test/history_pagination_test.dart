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

  test('text 字段优先（session.resume 兼容）', () {
    final items = chatItemsFromResume([
      {'role': 'user', 'text': '来自 text 字段', 'content': '旧字段'},
    ]);
    expect(items.single.text, '来自 text 字段');
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
}
