import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/main.dart';

/// 媒体与链接的行为：媒体留在原位置、只认独占一行的 `MEDIA:`、链接只放行安全 scheme。
void main() {
  group('splitMediaParts', () {
    test('MEDIA 行留在原位，前后文本分开且顺序不变', () {
      const raw = '先看这个：\nMEDIA:/home/yyx/share/inbox/a.png\n这是后面的说明';
      final parts = splitMediaParts(raw);
      expect(parts.length, 3);
      expect(parts[0].media, isNull);
      expect(parts[0].text.trim(), '先看这个：');
      expect(parts[1].media, '/home/yyx/share/inbox/a.png');
      expect(parts[2].media, isNull);
      expect(parts[2].text.trim(), '这是后面的说明');
    });

    test('句子里/行内代码里提到 MEDIA: 不算媒体（不会凭空冒出卡片）', () {
      const raw = '写法是 `MEDIA:<绝对路径>`，注意它不是真的指令。';
      final parts = splitMediaParts(raw);
      expect(parts.length, 1);
      expect(parts.single.media, isNull);
    });

    test('只有媒体行时，只有一段媒体', () {
      final parts = splitMediaParts('MEDIA:/tmp/x.pdf\n');
      expect(parts.length, 1);
      expect(parts.single.media, '/tmp/x.pdf');
    });

    test('多张图按出现顺序保留', () {
      const raw = 'MEDIA:/a.png\n中间\nMEDIA:/b.png';
      final parts = splitMediaParts(raw);
      expect(parts.map((p) => p.media).whereType<String>().toList(), ['/a.png', '/b.png']);
      expect(parts.length, 3);
    });

    test('前导空格/Tab 的 MEDIA 行也认', () {
      final parts = splitMediaParts('   MEDIA:/home/yyx/share/inbox/x.txt');
      expect(parts.single.media, '/home/yyx/share/inbox/x.txt');
    });

    test('普通文本原样返回一段', () {
      final parts = splitMediaParts('就是一段话');
      expect(parts.length, 1);
      expect(parts.single.text, '就是一段话');
    });
  });

  group('allowedLinkUri', () {
    test('http/https/mailto/tel 放行', () {
      expect(allowedLinkUri('https://example.com/a?b=1'), isNotNull);
      expect(allowedLinkUri('http://127.0.0.1:9119/api/status'), isNotNull);
      expect(allowedLinkUri('mailto:a@b.c'), isNotNull);
      expect(allowedLinkUri('tel:+8613800000000'), isNotNull);
    });

    test('危险/本地 scheme 拒绝', () {
      expect(allowedLinkUri('javascript:alert(1)'), isNull);
      expect(allowedLinkUri('file:///etc/passwd'), isNull);
      expect(allowedLinkUri('intent://scan/#Intent;scheme=zxing;end'), isNull);
      expect(allowedLinkUri('not a url'), isNull);
    });
  });
}
