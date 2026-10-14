import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/l10n.dart';

void main() {
  tearDown(() => L10n.locale.value = 'ar');

  test('Arabic is the default and returns the source string unchanged', () {
    expect(L10n.lang, 'ar');
    expect(L10n.isRtl, isTrue);
    expect(L10n.t('إرسال'), 'إرسال');
  });

  test('Chinese and English tables resolve the same keys', () {
    L10n.locale.value = 'zh';
    expect(L10n.isRtl, isFalse);
    expect(L10n.t('إرسال'), '发送');
    expect(L10n.t('اسم المستخدم'), '用户名');

    L10n.locale.value = 'en';
    expect(L10n.t('إرسال'), 'Send');
    expect(L10n.t('اسم المستخدم'), 'Username');
  });

  test('placeholders are substituted per locale', () {
    L10n.locale.value = 'zh';
    expect(L10n.t('النموذج المختار: {0}\n\n', ['gpt-4o']), '所选模型: gpt-4o\n\n');
    L10n.locale.value = 'en';
    expect(L10n.t('/{0}: تم', ['help']), '/help: done');
  });

  test('unknown keys fall back to the key itself', () {
    expect(L10n.t('no-such-key-xyz'), 'no-such-key-xyz');
  });

  test('language names and supported list cover the three shipped locales', () {
    expect(L10n.supported, ['ar', 'zh', 'en']);
    expect(L10n.names['zh'], '简体中文');
    expect(L10n.isSupported('de'), isFalse);
  });
}
