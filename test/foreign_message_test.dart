import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/store.dart';

/// 多客户端场景：Windows 上发出的用户消息不在服务端的 assistant 事件流里，
/// App 必须主动从 transcript 尾巴补进来（且不能和自己发的重复）。
void main() {
  group('lastUserText', () {
    test('取最后一条 user 行的文本（跳过 assistant/tool 行）', () {
      final rows = <Map<String, dynamic>>[
        {'role': 'user', 'content': '第一条'},
        {'role': 'assistant', 'content': '回复'},
        {'role': 'user', 'content': '第二条'},
        {'role': 'assistant', 'content': '再回复'},
      ];
      expect(lastUserText(rows), '第二条');
    });

    test('content 是分片列表时把文本拼起来', () {
      final rows = <Map<String, dynamic>>[
        {
          'role': 'user',
          'content': [
            {'type': 'text', 'text': '看图 '},
            {'type': 'image_url', 'image_url': 'x'},
            {'type': 'text', 'text': '这是什么'},
          ],
        },
      ];
      expect(lastUserText(rows), '看图 这是什么');
    });

    test('没有 user 行 → null', () {
      expect(lastUserText([<String, dynamic>{'role': 'assistant', 'content': 'hi'}]), isNull);
    });

    test('全是空文本 → null', () {
      expect(lastUserText([<String, dynamic>{'role': 'user', 'content': '   '}]), isNull);
    });
  });

  group('needsForeignUser', () {
    test('本地已有同文本的 user 行 → 不重复插', () {
      final items = <ChatItem>[ChatItem.user('同一句'), ChatItem.assistant('答')];
      expect(needsForeignUser(items, '同一句'), isFalse);
      expect(needsForeignUser(items, ' 同一句 '), isFalse, reason: '两端空白不应影响判重');
    });

    test('本地没有 → 需要补', () {
      final items = <ChatItem>[ChatItem.assistant('答')];
      expect(needsForeignUser(items, '别处发来的'), isTrue);
    });

    test('空文本不补', () {
      expect(needsForeignUser(<ChatItem>[], '  '), isFalse);
    });
  });
}
