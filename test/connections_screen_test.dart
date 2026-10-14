import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/api.dart';
import 'package:hermes_mobile/connections.dart';
import 'package:hermes_mobile/main.dart';
import 'package:tabler_icons_next/tabler_icons_next.dart' as tb;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Connections store;

  setUp(() {
    store = Connections(MemoryConnKv());
    Connections.instance = store;
  });

  Conn mk(String id, String name, String url) => Conn(id: id, name: name, url: url, user: 'karem', pass: 'pw');

  Future<void> pumpList(
    WidgetTester tester, {
    List<Conn> conns = const [],
    String? active,
  }) async {
    for (final c in conns) {
      await store.upsert(c);
    }
    if (active != null) await store.setActive(active);
    await tester.pumpWidget(MaterialApp(
      home: ConnectionsPage(
        api: HermesApi('http://x:9131', 'karem', 'pw'),
        onSwitched: (_) {},
        onLoggedOut: () {},
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('list renders saved gateways with the active one checked', (tester) async {
    await pumpList(
      tester,
      conns: [
        mk('a', '本地设备', 'http://10.0.0.5:9131'),
        mk('b', '远程网关', 'https://gateway.example.com'),
      ],
      active: 'a',
    );
    expect(find.text('网关与连接'), findsOneWidget);
    expect(find.text('本地设备'), findsOneWidget);
    expect(find.text('远程网关'), findsOneWidget);
    expect(find.text('https://gateway.example.com'), findsOneWidget);
    expect(find.text('添加网关'), findsOneWidget);
    // Exactly one active checkmark, on the active row.
    expect(find.byType(tb.CircleCheck), findsOneWidget);
  });

  testWidgets('without saved gateways the card still offers the add row', (tester) async {
    await pumpList(tester);
    expect(find.text('添加网关'), findsOneWidget);
    expect(find.byType(tb.CircleCheck), findsNothing);
  });

  testWidgets('tapping an inactive row attempts a connection and surfaces the failure', (tester) async {
    await pumpList(
      tester,
      conns: [mk('a', 'A', 'http://10.9.9.9:9131'), mk('b', 'B', 'http://10.9.9.8:9131')],
      active: 'a',
    );
    await tester.tap(find.text('B'));
    // Bounded pumps: the busy row keeps an indeterminate spinner on screen.
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 120));
    }
    expect(find.textContaining('无法连接到「B」'), findsOneWidget);
  });

  testWidgets('editor validates the three fields before saving', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: ConnectionEditorPage()));
    await tester.pumpAndSettle();
    await tester.tap(find.text('添加并连接'));
    await tester.pumpAndSettle();
    expect(find.text('请输入服务器地址。'), findsOneWidget);
  });

  testWidgets('deleting from the editor confirms, removes the entry and pops deleted', (tester) async {
    final c = mk('a', '旧网关', 'http://10.1.1.1:9131');
    await store.upsert(c);
    Object? popped;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              popped = await Navigator.of(ctx).push<Object>(
                  MaterialPageRoute(builder: (_) => ConnectionEditorPage(existing: c)));
            },
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('编辑网关'), findsOneWidget);

    await tester.tap(find.text('删除网关'));
    await tester.pumpAndSettle();
    expect(find.textContaining('「旧网关」'), findsOneWidget);

    await tester.tap(find.text('删除'));
    await tester.pumpAndSettle();
    expect(popped, 'deleted');
    expect(await store.list(), isEmpty);
  });

  testWidgets('editing an existing gateway prefills its fields', (tester) async {
    final c = mk('a', '远程', 'https://gateway.example.com');
    await tester.pumpWidget(MaterialApp(home: ConnectionEditorPage(existing: c)));
    await tester.pumpAndSettle();
    expect(find.text('远程'), findsOneWidget);
    expect(find.text('https://gateway.example.com'), findsOneWidget);
    expect(find.text('karem'), findsOneWidget);
    expect(find.text('删除网关'), findsOneWidget);
  });
}
