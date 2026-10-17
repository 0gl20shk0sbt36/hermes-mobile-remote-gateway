import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/l10n.dart';
import 'package:hermes_mobile/main.dart';
import 'package:hermes_mobile/store.dart';

import 'attachment_delivery_test.dart' show RecordingGateway;

/// 记录本机发回去的 JSON-RPC 结果帧（``respond``）。
class FrameGateway extends RecordingGateway {
  final frames = <Map<String, dynamic>>[];

  @override
  void respond(Object id, Object? result) => frames.add({'id': id, 'result': result});

  @override
  void respondError(Object id, String message) => frames.add({'id': id, 'error': message});
}

/// 一次真实 clarify 请求的线格式（tui_gateway/contracts/server_requests.py）。
/// 把一条服务端请求塞进 store（widget 测试里要靠 pump 推进，不能 await Future.delayed）。
void pushRequest(FrameGateway gw, Map<String, dynamic> params, {String method = 'clarify'}) {
  gw.requests.add({'id': 'rq-1', 'method': method, 'params': params});
}

/// pumpAndSettle 会等所有动画静止；玻璃组件里有常驻动画，所以固定 pump 几步。
Future<void> settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late FrameGateway gw;
  late HermesStore store;

  setUp(() {
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

  test('clarify answers go back as {"answers": {qid: value}} — not as a cancel', () async {
    pushRequest(gw, {
      'session_id': 'session-a',
      'questions': [
        {
          'qid': 'q0',
          'question': 'Deploy now?',
          'choices': ['Yes (Recommended)', 'No'],
          'multi_select': false,
        },
      ],
    });
    await Future<void>.delayed(Duration.zero);
    expect(store.pending?.method, 'clarify');
    store.answerClarify({'q0': 'Yes'});
    expect(gw.frames.single['result'], {
      'answers': {'q0': 'Yes'},
    });
  });

  test('a response without answers is the cancel path', () async {
    pushRequest(gw, {
      'questions': [
        {'qid': 'q0', 'question': 'Deploy now?', 'choices': ['Yes'], 'multi_select': false},
      ],
    });
    await Future<void>.delayed(Duration.zero);
    store.cancelPending();
    expect(gw.frames.single['result'], isEmpty);
  });

  test('approval keeps sending {"choice": ...}', () async {
    pushRequest(gw, {
      'session_id': 'session-a',
      'request_id': 'a1',
      'command': 'rm -rf /tmp/x',
      'choices': ['once', 'session', 'deny'],
    }, method: 'approval');
    await Future<void>.delayed(Duration.zero);
    store.answer({'choice': 'once'});
    expect(gw.frames.single['result'], {'choice': 'once'});
  });

  testWidgets('the card renders every question and needs a submit tap', (tester) async {
    await tester.binding.setSurfaceSize(const Size(520, 1600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    pushRequest(gw, {
      'session_id': 'session-a',
      'questions': [
        {'qid': 'q0', 'question': 'Which branch?', 'choices': ['main (Recommended)', 'dev'], 'multi_select': false},
        {'qid': 'q1', 'question': 'Which targets?', 'choices': ['api', 'web'], 'multi_select': true},
      ],
    });
    await tester.pumpWidget(host());
    await settle(tester);

    // 两道题都渲染出来（旧版只显示第一题）。推荐后缀被剥掉、改角标。
    expect(find.text('Which branch?'), findsOneWidget);
    expect(find.text('Which targets?'), findsOneWidget);
    expect(find.text('main'), findsOneWidget);
    expect(find.text('main (Recommended)'), findsNothing);

    // 没有提交按钮之前什么都不会发出去（旧版点一下就直接答了）。
    await tester.ensureVisible(find.text('main'));
    await tester.tap(find.text('main'));
    await settle(tester);
    expect(gw.frames, isEmpty, reason: '点选项只是选中，不发帧');

    // 多选：勾两个。
    await tester.ensureVisible(find.text('api'));
    await tester.tap(find.text('api'));
    await tester.ensureVisible(find.text('web'));
    await tester.tap(find.text('web'));
    await settle(tester);

    await tester.tap(find.text(submitLabel));
    await settle(tester);

    expect(gw.frames.single['result'], {
      'answers': {
        'q0': 'main',
        'q1': ['api', 'web'],
      },
    });
    expect(store.pending, isNull);
  });

  testWidgets('an unanswered question is left out of the frame', (tester) async {
    pushRequest(gw, {
      'session_id': 'session-a',
      'questions': [
        {'qid': 'q0', 'question': 'A?', 'choices': ['x', 'y'], 'multi_select': false},
        {'qid': 'q1', 'question': 'B?', 'choices': ['z', 'w'], 'multi_select': false},
      ],
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await tester.ensureVisible(find.text('x'));
    await tester.tap(find.text('x'));
    await settle(tester);
    await tester.tap(find.text(submitLabel));
    await settle(tester);

    expect(gw.frames.single['result'], {
      'answers': {'q0': 'x'},
    });
  });

  testWidgets('a free-text answer overrides the picked choice', (tester) async {
    pushRequest(gw, {
      'session_id': 'session-a',
      'questions': [
        {'qid': 'q0', 'question': 'Which host?', 'choices': ['nas', 'pve'], 'multi_select': false},
      ],
    });
    await tester.pumpWidget(host());
    await settle(tester);
    await tester.ensureVisible(find.text('nas'));
    await tester.tap(find.text('nas'));
    await tester.enterText(find.byType(TextField).first, 'vm201');
    await settle(tester);
    await tester.tap(find.text(submitLabel));
    await settle(tester);

    expect(gw.frames.single['result'], {
      'answers': {'q0': 'vm201'},
    });
  });

  testWidgets('chat keeps a always-visible scrollbar', (tester) async {
    store.items
      ..add(ChatItem.user('hello'))
      ..add(ChatItem.assistant('world'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: ChatView(store: store)),
    ));
    await settle(tester);

    final bars = find.byType(Scrollbar);
    expect(bars, findsOneWidget);
    expect(tester.widget<Scrollbar>(bars).thumbVisibility, isTrue,
        reason: '滚动条必须常显，否则滑到哪儿完全没数');
  });
}

/// 提交按钮文案（取当前语言下的值，避免测试里散落阿语字面量）。
final submitLabel = L10n.t('إرسال الإجابة');
