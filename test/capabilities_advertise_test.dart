import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hermes_mobile/api.dart';

import 'gateway_connection_test.dart' show LocalGateway, eventually;

/// 回归：服务端→客户端请求（clarify / 审批 / sudo）的**能力广告**。
///
/// 2026-10-19 线上事故：手机端重连后的新连接没有上报 `client.capabilities`，
/// 服务端按连接判定“客户端太旧”，于是**不发**提问卡（日志
/// `not sent: the attached client predates server→client requests`），
/// agent 拿到 undelivered 就说“用户没回答”，用户只看到一个空的工具调用行。
///
/// 另外当天 12:23 的包把 `stream` 塞进了同一帧，撞上后端 extra="forbid" 的契约，
/// 整条广告被 4000 拒绝 → 所有提问/审批静默失效。所以下面既盯时机，也盯载荷形状。
void main() {
  late LocalGateway server;
  late Gateway gateway;

  setUp(() async {
    server = LocalGateway();
    await server.start();
    gateway = Gateway(server.api);
  });

  tearDown(() async {
    gateway.close();
    await server.stop();
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  List<Map<String, dynamic>> caps() =>
      server.messages.where((m) => m['method'] == 'client.capabilities').toList();

  test('socket 一建立就广告能力，不等 gateway.ready', () async {
    server.autoReady = false; // 服务端永远不发 gateway.ready
    unawaited(gateway.connect());
    await eventually(() => caps().isNotEmpty);
    // 还没 ready，模型侧连接状态仍是 connecting —— 广告却已经发出去了。
    expect(gateway.state, LinkState.connecting);
  });

  test('载荷只含 server_requests（后端 extra=forbid，多一个键整条被拒）', () async {
    await gateway.connect();
    await eventually(() => caps().isNotEmpty);
    expect(caps().first['params'], {'server_requests': true});
  });

  test('每条新连接各广告一次，同一条连接不重复', () async {
    await gateway.connect();
    await eventually(() => caps().isNotEmpty);
    final before = caps().length;

    // 服务端踢掉连接 → 客户端按退避重连 → 新连接必须重新广告。
    await server.sockets.first.close();
    await eventually(() => caps().length > before, timeout: const Duration(seconds: 8));

    expect(caps().length, before + 1, reason: '新连接应当只补一条；多的是 ready 兜底重复发');
    expect(caps().map((m) => m['id']).toSet(), hasLength(caps().length), reason: 'id 不能复用');
  });
}
