// 演示/取证模式（``--dart-define=HERMES_DEMO=true``）：不连服务器，直接往 store 里灌一份
// 覆盖全部渲染路径的假数据 —— 排错时用模拟器看真实渲染，不碰任何凭据。
// 刻意复刻 2026-10-16 用户报的那几个场景：
// ① 一轮里"文字 → 工具 → 文字 → 工具 → 文字"（顺序渲染）；
// ② 一张两题、其中一题多选的提问卡（提交按钮 / answers 回执）；
// ③ 入参 + 返回值都很长的工具行（展开 / 全屏）；
// ④ 12 条后台活动（面板高度封顶 + 可滚 + 行可点开）。
import 'l10n.dart';
import 'store.dart';

bool get demoMode => const bool.fromEnvironment('HERMES_DEMO');

void seedDemo(HermesStore store) {
  // 演示模式固定中文：截屏/读屏核对时看得懂。
  L10n.locale.value = 'zh';
  store.sid = 'demo-session';
  store.storedId = 'demo-session';
  store.title = '演示会话（离线假数据）';
  store.opening = false;

  store.items
    ..add(ChatItem.user('帮我看看 CT100 的磁盘和内存，然后跑一遍评测'))
    ..add(ChatItem.thinking('先看磁盘占用，再决定要不要清缓存……'))
    ..add(ChatItem.assistant('先看一下磁盘和内存。'))
    ..add(ChatItem.tool('terminal',
        toolId: 't1',
        detail: 'df -h /',
        argsText: '{\n  "command": "df -h / && free -h",\n  "timeout": 60\n}',
        resultText: 'Filesystem      Size  Used Avail Use% Mounted on\n'
            '/dev/rbd0       200G  121G   69G  64% /\n'
            '\n'
            '               total        used        free      shared  buff/cache   available\n'
            'Mem:           8.0Gi       3.1Gi       0.4Gi       1.1Gi       4.5Gi       4.6Gi\n'
            'Swap:          2.0Gi       0.6Gi       1.4Gi'))
    ..add(ChatItem.assistant('磁盘 64%，内存还剩 4.6G。接着跑评测。'))
    ..add(ChatItem.tool('execute_code',
        toolId: 't2',
        detail: 'python3 run_suites.py --all',
        argsText: "{\n  \"code\": \"import subprocess\\nfor suite in ('models', 'tools', 'sessions'):\\n    subprocess.run(['python3', 'run_one.py', suite], check=True)\\nprint('ALL DONE')\"\n}",
        resultText: '{"status": "success", "output": "models OK\\ntools OK\\nsessions OK\\nALL DONE\\n", "exit_code": 0}'))
    ..add(ChatItem.assistant(
        '评测全绿：models / tools / sessions 三个套件都通过。磁盘 64%、内存剩 4.6G，不用清缓存。'))
    ..add(ChatItem.notice('（演示数据：本条对话不来自任何真实会话。）'));

  // 提问卡：两题、第二题多选，第一题第一个选项带服务端的 (Recommended) 后缀。
  store.pending = PendingRequest('demo-rq-1', 'clarify', <String, dynamic>{
    'session_id': 'demo-session',
    'questions': [
      {
        'qid': 'q0',
        'question': '磁盘缓存要不要现在清掉？（会顺带停掉两个后台任务）',
        'choices': ['先别清，我手动确认 (Recommended)', '现在就清'],
        'multi_select': false,
      },
      {
        'qid': 'q1',
        'question': '接下来优先看哪些套件？',
        'choices': ['models', 'tools', 'sessions', 'subagents'],
        'multi_select': true,
      },
    ],
  });

  store.background
    ..add(BackgroundActivity(
        id: 'demo-sub-1',
        kind: 'subagent',
        title: '审计支付服务的并发问题',
        subtitle: 'read_file',
        model: 'deepseek-flash',
        toolCount: 12))
    ..add(BackgroundActivity(
        id: 'demo-sub-2',
        kind: 'subagent',
        title: '把评测日志按套件分类汇总',
        subtitle: 'execute_code',
        model: 'deepseek-flash',
        toolCount: 5,
        state: BackgroundState.done,
        detail: '已完成：models/tools/sessions 三组日志都已汇总到 ~/tmp/summary.md'))
    ..add(BackgroundActivity(
        id: 'demo-p-1',
        kind: 'process',
        title: 'python3 -m http.server 8000 --directory ~/share',
        detail: 'Serving HTTP on 0.0.0.0 port 8000 ...\n'
            '192.168.1.10 - - [16/Oct/2026 10:12:31] "GET /README.md HTTP/1.1" 200 -\n'
            '192.168.1.10 - - [16/Oct/2026 10:12:33] "GET /reports/ HTTP/1.1" 200 -'))
    ..add(BackgroundActivity(
        id: 'demo-p-2',
        kind: 'process',
        title: 'npm run watch --port 3000 --verbose',
        detail: 'watching for file changes...'))
    ..add(BackgroundActivity(
        id: 'demo-p-3',
        kind: 'process',
        title: 'pytest -q tests/e2e',
        state: BackgroundState.failed,
        exitCode: 1,
        detail: 'AssertionError: expected 200 got 500\nFAILED tests/e2e/test_api.py::test_health'));
  for (var i = 4; i <= 12; i++) {
    store.background.add(BackgroundActivity(
      id: 'demo-p-$i',
      kind: 'process',
      title: 'sleep 60 && echo job-$i',
      detail: 'job-$i started\njob-$i still running',
    ));
  }

  // 子代理的 transcript 尾巴（模拟器上没连服务器，用假数据把详情页也演示出来）。
  store.demoTails['demo-sub-1'] = '[tool] read_file {"path": "src/pay/api.py"}\n'
      '已读 src/pay/api.py（412 行），并发入口在 charge()：\n'
      '  第 88 行用 self._lock 保护，但 settle() 走的是同一个连接池……\n'
      '[tool] grep {"pattern": "asyncio.gather"}\n'
      '命中 3 处，其中 webhooks.py:44 没有加超时。\n'
      '结论：先补 webhooks 的超时，再压测 200 并发。';

  store.debugLines
    ..add('10:12:01  ← message.start {}')
    ..add('10:12:03  ← tool.start {tool_id: t1, name: terminal, context: df -h /}')
    ..add('10:12:04  ← tool.complete {tool_id: t1, duration_s: 1.2, summary: ok}')
    ..add('10:12:09  ← clarify {session_id: demo-session, questions: [{"qid":"q0",'
        '"question":"磁盘缓存要不要现在清掉？","choices":["先别清… (Recommended)","现在就清"],"multi_select":false}]}')
    ..add('10:12:20  → clarify {"answers":{"q0":"先别清","q1":["models","tools"]}}');

  // trace() 内部会 notifyListeners，收尾顺带把界面刷出来。
  store.trace('demo 模式：已灌入假数据（未连接服务器）');
}
