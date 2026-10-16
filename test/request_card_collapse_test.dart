import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/l10n.dart';
import 'package:hermes_mobile/main.dart';
import 'package:hermes_mobile/store.dart';

import 'clarify_card_test.dart' show FrameGateway, pushRequest, settle;

/// 提问面板（RequestCard）的收起/展开：面板最大占半屏，收起后只留标题行 +
/// 一行摘要，挡住对话的问题就没了。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FrameGateway gw;
  late HermesStore store;

  setUp(() {
    L10n.locale.value = 'zh';
    RequestCard.preferCollapsed = false;
    gw = FrameGateway();
    store = HermesStore(gw)..sid = 'session-a';
  });
  tearDown(() {
    store.dispose();
    gw.close();
  });

  Widget host() => MaterialApp(
        home: Scaffold(
          body: ListenableBuilder(
            listenable: store,
            builder: (context, _) =>
                store.pending == null ? const SizedBox.shrink() : RequestCard(store: store),
          ),
        ),
      );

  void pushTwoQuestions() => pushRequest(gw, {
        'session_id': 'session-a',
        'questions': [
          {
            'qid': 'q0',
            'question': '要跑哪个套件？',
            'choices': ['全量套件', '快速套件'],
            'multi_select': false,
          },
          {
            'qid': 'q1',
            'question': '跑多久？',
            'choices': ['1 小时', '6 小时'],
            'multi_select': false,
          },
        ],
      });

  testWidgets('点标题行可以收起：选项隐藏、摘要保留、面板变矮', (tester) async {
    pushTwoQuestions();
    await tester.pumpWidget(host());
    await settle(tester);

    final expanded = tester.getSize(find.byType(RequestCard)).height;
    expect(find.text('全量套件'), findsOneWidget);
    expect(find.text(L10n.t('اطوِ')), findsOneWidget); // 「收起」

    await tester.tap(find.text(L10n.t('سؤال من Hermes')));
    await settle(tester);

    expect(find.text('全量套件'), findsNothing, reason: '收起后选项要藏起来');
    expect(find.text(L10n.t('وسّع')), findsOneWidget); // 「展开」
    final collapsed = tester.getSize(find.byType(RequestCard)).height;
    expect(collapsed, lessThan(expanded));
    expect(collapsed, lessThan(120), reason: '收起后应当只剩标题行 + 一行摘要');
    expect(find.textContaining('要跑哪个套件'), findsOneWidget, reason: '摘要显示还没答的那题');

    await tester.tap(find.text(L10n.t('وسّع')));
    await settle(tester);
    expect(find.text('全量套件'), findsOneWidget, reason: '展开后选项要回来');
  });

  testWidgets('收起时标题行显示已答题数，且收起状态跨请求记住', (tester) async {
    pushTwoQuestions();
    await tester.pumpWidget(host());
    await settle(tester);

    await tester.tap(find.text(L10n.t('سؤال من Hermes')));
    await settle(tester);
    // 摘要里那题没答，先展开答掉第一题
    await tester.tap(find.text(L10n.t('وسّع')));
    await settle(tester);
    await tester.tap(find.text('全量套件'));
    await settle(tester);
    await tester.tap(find.text(L10n.t('اطوِ')));
    await settle(tester);

    expect(find.text(L10n.t('{0} من {1} مُجاب', [1, 2])), findsOneWidget);
    expect(find.textContaining('跑多久'), findsOneWidget, reason: '摘要切到下一道还没答的题');
  });

  testWidgets('审批卡（approval）也能收起，收起后执行命令不可见但仍在待答', (tester) async {
    pushRequest(
      gw,
      {
        'session_id': 'session-a',
        'request_id': 'a1',
        'description': '要删除临时目录',
        'command': 'rm -rf /home/yyx/tmp/build-stale',
        'choices': ['once', 'session'],
      },
      method: 'approval',
    );
    await tester.pumpWidget(host());
    await settle(tester);

    expect(find.textContaining('rm -rf'), findsOneWidget);
    await tester.tap(find.text(L10n.t('مطلوب إذن بالتنفيذ')));
    await settle(tester);
    expect(find.textContaining('rm -rf'), findsNothing);
    expect(find.text(L10n.t('وسّع')), findsOneWidget);
    expect(store.pending, isNotNull, reason: '收起只是视觉变化，请求仍在等待');
  });
}
