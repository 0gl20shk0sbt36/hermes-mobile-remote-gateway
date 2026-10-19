import 'dart:convert';
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import 'api.dart';
import 'trace.dart';
import 'background.dart';
import 'design.dart';
import 'notify.dart';
import 'l10n.dart';

export 'background.dart';

class ChatItem {
  ChatItem.user(this.text) : kind = 'user', detail = '', done = true;
  ChatItem.assistant(this.text) : kind = 'assistant', detail = '', done = true;
  ChatItem.tool(this.text,
      {this.toolId, this.detail = '', this.done = true, this.argsText = '', this.resultText = ''})
      : kind = 'tool';
  ChatItem.notice(this.text) : kind = 'notice', detail = '', done = true;
  ChatItem.thinking(this.text) : kind = 'thinking', detail = '', done = false;

  final String kind;
  String text;
  List<String> files = const []; // attachment paths shown as cards under the text
  String? toolId;
  String detail;
  bool done;
  double? duration;

  /// 工具调用的完整入参（live: ``tool.start`` 的 ``args_text``／``args``；
  /// 历史：assistant 行 ``tool_calls`` 里的 arguments，格式化后的 JSON）。
  String argsText = '';

  /// 工具返回值（live: ``tool.complete`` 的 ``result_text``／``result``／``inline_diff``；
  /// 历史：tool 行的 ``content``）。旧版本从不存它，于是只看得见一行入参摘要。
  String resultText = '';

  /// 展开后有没有正文可看（决定工具行是否可点）。
  bool get expandable =>
      argsText.trim().isNotEmpty || resultText.trim().isNotEmpty || detail.trim().isNotEmpty;

  /// 这段文字已经"封口"（后面来了工具行/思考块/旁白）：后续 message.delta 属于新的一段，
  /// 必须新开气泡，不能再往这条里追加。
  bool sealed = false;

  /// When the item appeared locally: drives the live timer on a running tool
  /// and the "thought for Ns" label once a thinking block closes.
  final DateTime started = DateTime.now();

  /// Seconds a live thinking block ran; null for history, where the server
  /// does not report it.
  int? seconds;
}

/// A send refused because another device holds the session (``SESSION_NOT_OWNED``):
/// the UI offers to pull it here, then resends exactly this draft.
class PullOffer {
  PullOffer(this.text, this.sessionId);
  final String text;
  final String sessionId;
}

/// Arabic label for a lease ``surface`` value (desktop | mobile | tui | gateway ...).
String _surfaceAr(String? surface) {
  switch ((surface ?? '').trim().toLowerCase()) {
    case 'desktop':
      return L10n.t('سطح المكتب');
    case 'mobile':
      return L10n.t('الجوال');
    case 'tui':
    case 'cli':
      return L10n.t('الطرفية');
    case 'gateway':
    case 'bot':
      return L10n.t('البوت');
    default:
      return L10n.t('جهاز آخر');
  }
}

class ActiveSession {
  ActiveSession(this.id, this.key, this.title, this.status, this.model, this.lastActive);
  final String id; // live runtime id
  final String key; // durable id (matches SessionRow.id)
  final String title;
  final String status; // idle|starting|waiting|working|streaming|resuming
  final String model;
  final double lastActive;
  bool get busy => status != 'idle';
}

class SessionRow {
  SessionRow(this.id, this.title, this.source, this.startedAt, this.count);
  final String id;
  final String title;
  final String source;
  final double startedAt;
  final int count;
}

class CommandEntry {
  CommandEntry(this.name, this.description, this.group);
  final String name;
  final String description;
  final String group;
}

class ModelOption {
  ModelOption(this.provider, this.providerName, this.model);
  final String provider;
  final String providerName;
  final String model;
}

class Attachment {
  Attachment(this.name, this.isImage, {this.ref = '', this.path = '', this.sessionId, this.bytes = const []});
  final String? sessionId;
  List<int> bytes;
  String? error;
  final String name;
  final bool isImage;
  String ref; // explicit @image: or @file: reference
  String path; // absolute server path, also used by visible cards
  bool uploading = true;
}

class QueuedTurn {
  QueuedTurn(this.sessionId, this.text, List<Attachment> files) : files = List.unmodifiable(files);
  final String sessionId;
  final String text;
  final List<Attachment> files;
}

class PendingRequest {
  PendingRequest(this.id, this.method, this.params);
  final Object id;
  final String method;
  final Map<String, dynamic> params;

  /// ``questions`` for a clarify card (empty for approval); each entry carries
  /// ``qid`` / ``question`` / ``choices`` / ``multi_select``.
  List<Map<String, dynamic>> get questions => [
        for (final q in (params['questions'] as List? ?? const []))
          if (q is Map) Map<String, dynamic>.from(q),
      ];
}

/// App state: session list, the one open chat, catalog, model options.
class HermesStore extends ChangeNotifier {
  HermesStore(this.gw) {
    _evSub = gw.events.stream.listen(_onEvent);
    _rqSub = gw.requests.stream.listen(_onRequest);
    gw.addListener(_onLink);
  }

  // ------------------------------------------------------------- debug trace
  // 现场取证用：把收到的 WS 事件/服务端请求与发出去的回执按时间顺序记在内存里，
  // 由调试面板（长按顶栏状态点）展示。敏感键（password/secret/token/code…）一律打码。
  final List<String> debugLines = <String>[];
  static const int debugLimit = 400;

  /// 演示/取证模式用的子代理 transcript（见 lib/demo.dart）；生产路径永远为空。
  final Map<String, String> demoTails = <String, String>{};

  void _trace(String line) {
    final stamp = DateTime.now().toIso8601String().substring(11, 19);
    debugLines.add('$stamp  $line');
    if (debugLines.length > debugLimit) debugLines.removeRange(0, debugLines.length - debugLimit);
  }

  /// 公开给 UI 用（比如把一次失败的手动动作记进调试面板）。
  void trace(String line) {
    _trace(line);
    notifyListeners();
  }

  void clearTrace() {
    debugLines.clear();
    notifyListeners();
  }

  final Gateway gw;
  late final StreamSubscription _evSub;
  late final StreamSubscription _rqSub;

  List<SessionRow> sessions = [];
  List<ActiveSession> active = [];
  Timer? _activeTimer;

  ActiveSession? activeFor(String storedKey) {
    for (final a in active) {
      if (a.key == storedKey || a.id == storedKey) return a;
    }
    return null;
  }

  Future<void> refreshActive() async {
    if (!connected) return;
    try {
      final r = await gw.call('session.active_list', {if (sid != null) 'current_session_id': sid});
      active = [
        for (final a in (r['sessions'] as List? ?? const []))
          ActiveSession('${a['id']}', '${a['session_key'] ?? ''}', '${a['title'] ?? ''}', '${a['status'] ?? 'idle'}',
              '${a['model'] ?? ''}', (a['last_active'] as num?)?.toDouble() ?? 0)
      ]..sort((x, y) {
          if (x.busy != y.busy) return x.busy ? -1 : 1;
          return y.lastActive.compareTo(x.lastActive);
        });
      final mine = sid == null ? null : active.where((a) => a.id == sid).firstOrNull;
      if (sid != null && !_loading && !opening) _reconcileRunning(mine);
      notifyListeners();
    } catch (_) {}
  }
  bool loadingSessions = false;
  List<CommandEntry> commands = [];
  List<ModelOption> models = [];
  String currentModel = '';
  String currentProvider = '';

  String? _sid; // live runtime id
  String? get sid => _sid;
  set sid(String? value) {
    if (_sid == value) return;
    _sid = value;
    // Background rows belong to the session that owned them: a switch or a
    // close must never leave last session's processes hanging in the composer.
    clearBackground();
  }
  String? storedId; // durable id from session.list
  String title = '';
  final items = <ChatItem>[];
  bool running = false;
  bool opening = false;
  // 状态行不要缓存"已翻译"的文本（切语言后会变成旧语言残影）：
  // 存 key + 参数，渲染时用当前语言现场翻译；服务端/工具原样文本走 _statusRaw。
  String _statusKey = '';
  String _statusArg = '';
  String _statusRaw = '';

  String get statusText => _statusKey.isNotEmpty
      ? L10n.t(_statusKey, _statusArg.isEmpty ? null : <Object?>[_statusArg])
      : _statusRaw;

  set statusText(String value) {
    _statusKey = '';
    _statusArg = '';
    _statusRaw = value;
  }

  void _status(String key, [String arg = '']) {
    _statusKey = key;
    _statusArg = arg;
    _statusRaw = '';
  }

  void _statusClear() {
    _statusKey = '';
    _statusArg = '';
    _statusRaw = '';
  }
  Map<String, dynamic> info = {};
  PendingRequest? pending;
  String? toast;

  /// A refused draft waiting behind the "pull from the other device" offer.
  PullOffer? pendingPull;
  bool pulling = false;
  String? _pullKey;
  List<Object?> _pullArgs = const [];
  String? _pullRaw;

  String? get pullError => _pullKey != null
      ? L10n.t(_pullKey!, _pullArgs.isEmpty ? null : _pullArgs)
      : _pullRaw;

  /// 兼容旧写法：直接给成品文本（原样显示，不参与翻译）。
  set pullError(String? value) {
    _pullKey = null;
    _pullArgs = const [];
    _pullRaw = value;
  }

  void _pullSet(String key, [List<Object?> args = const []]) {
    _pullKey = key;
    _pullArgs = args;
    _pullRaw = null;
  }

  void _pullClear() {
    _pullKey = null;
    _pullArgs = const [];
    _pullRaw = null;
  }

  bool submitting = false;
  final queued = <QueuedTurn>[];
  final attachments = <Attachment>[]; // current composer draft

  bool get connected => gw.state == LinkState.connected;

  /// App 在后台时停止轮询：常驻服务只保连接，UI 侧不再定时打 RPC。
  /// （公网/蜂窝下这是最大的一块无谓流量：原来 active_list 4s 一次 + 背景面板 6s 一次，全是常开。）
  bool paused = false;
  int _activeTick = 0;
  /// 背景面板是否打开：只有打开时才轮询 process/subagent 列表。
  bool watchBackground = false;

  void _onLink() {
    if (gw.state == LinkState.connected) {
      refreshSessions();
      refreshActive();
      _activeTimer ??= Timer.periodic(const Duration(seconds: 4), (_) {
        if (paused) return;
        // 空闲时降到 12s（每 3 拍一次）；有任务在跑/正在打开时才 4s。
        _activeTick++;
        final busy = running || opening || submitting;
        if (!busy && _activeTick % 3 != 0) return;
        unawaited(refreshActive());
      });
      _bgTimer ??= Timer.periodic(const Duration(seconds: 6), (_) {
        if (paused || sid == null || opening) return;
        // 只有面板开着或确实有任务在跑时才拉进程/子代理列表。
        if (!watchBackground && !running && background.isEmpty) return;
        unawaited(refreshBackground());
      });
      if (commands.isEmpty) loadCatalog();
    }
    notifyListeners();
  }

  void _flash(String msg) {
    toast = msg;
    notifyListeners();
  }

  Future<void> refreshSessions() async {
    loadingSessions = true;
    notifyListeners();
    try {
      final r = await gw.call('session.list', {'limit': 200});
      sessions = [
        for (final s in (r['sessions'] as List))
          SessionRow(
            '${s['id']}',
            ((s['title'] as String?)?.trim().isNotEmpty ?? false)
                ? s['title'] as String
                : ((s['preview'] as String?)?.trim().isNotEmpty ?? false)
                    ? (s['preview'] as String).trim()
                    // 留空，交给渲染时用当前语言补默认标题（就地本地化会在切语言后变成旧语言的残影）
                    : '',
            '${s['source'] ?? ''}',
            (s['started_at'] as num?)?.toDouble() ?? 0,
            (s['message_count'] as num?)?.toInt() ?? 0,
          )
      ];
    } catch (e) {
      if (kTrace) htrace('sessions.err', {'e': '$e'});
      _flash(L10n.t('تعذر جلب الجلسات: {0}', [e]));
    }
    if (kTrace) htrace('sessions.n', {'n': sessions.length, 'loading': loadingSessions});
    loadingSessions = false;
    notifyListeners();
  }

  Future<void> loadCatalog() async {
    try {
      final r = await gw.call('commands.catalog', {if (sid != null) 'session_id': sid});
      final out = <CommandEntry>[];
      for (final cat in (r['categories'] as List)) {
        for (final p in (cat['pairs'] as List)) {
          out.add(CommandEntry('${p[0]}', '${p[1]}', '${cat['name']}'));
        }
      }
      final skills = (r['skills'] as Map?) ?? {};
      final seen = out.map((e) => e.name).toSet();
      final skillNames = skills.keys.map((k) => '$k').toList()..sort();
      for (final k in skillNames) {
        if (!seen.contains(k)) out.add(CommandEntry(k, L10n.t('مهارة'), L10n.t('المهارات')));
      }
      commands = out;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> loadModels() async {
    try {
      final r = await gw.call('model.options', {if (sid != null) 'session_id': sid});
      currentModel = '${r['model'] ?? ''}';
      currentProvider = '${r['provider'] ?? ''}';
      final out = <ModelOption>[];
      for (final p in (r['providers'] as List)) {
        if (p['authenticated'] == false) continue;
        for (final m in (p['models'] as List? ?? [])) {
          out.add(ModelOption('${p['slug']}', '${p['name'] ?? p['slug']}', '$m'));
        }
      }
      models = out;
      notifyListeners();
    } catch (e) {
      _flash(L10n.t('تعذر جلب النماذج: {0}', [e]));
    }
  }

  void _applyInfo(Map<String, dynamic>? i) {
    if (i == null) return;
    info = {...info, ...i};
    if (i['model'] != null) currentModel = '${i['model']}';
    if (i['provider'] != null) currentProvider = '${i['provider']}';
    if (i['running'] is bool) running = i['running'] as bool;
    if ((i['title'] as String?)?.isNotEmpty ?? false) title = i['title'] as String;
  }

  // --- Session switching -----------------------------------------------------
  //
  // Each opened session keeps its rendered view, so switching back paints
  // instantly and then reconciles quietly. The transcript comes from the REST
  // page (like the desktop) and `session.resume` is called with
  // `omit_messages`, which on a long session is ~20 ms instead of seconds of
  // serialising the whole compression lineage over the socket.

  final _views = <String, _SessionView>{};
  int _openGen = 0;
  bool _loading = false;
  final _held = <Map<String, dynamic>>[];
  Future<void>? _openFuture;

  /// Whether the chat shown is being reconciled with the server in the background.
  bool get refreshing => _loading && !opening;

  void _stash() {
    final key = storedId, id = sid;
    if (key == null || id == null || opening) return;
    _views.remove(key);
    _views[key] = _SessionView(id, title, List.of(items), running, _statusKey, _statusArg, _statusRaw);
    while (_views.length > 12) {
      _views.remove(_views.keys.first);
    }
  }

  Future<void> openSession(SessionRow row) {
    final f = _open(row);
    _openFuture = f;
    f.whenComplete(() {
      if (identical(_openFuture, f)) _openFuture = null;
    });
    return f;
  }

  Future<void> _open(SessionRow row) async {
    final gen = ++_openGen;
    _stash();
    final cached = _views.remove(row.id);
    if (cached != null) _views[row.id] = cached;
    storedId = row.id;
    pending = null;
    _loading = true;
    _held.clear();
    if (cached != null) {
      sid = cached.sid;
      title = row.title.isNotEmpty ? row.title : cached.title;
      items
        ..clear()
        ..addAll(cached.items);
      running = cached.running;
      _statusKey = cached.statusKey;
      _statusArg = cached.statusArg;
      _statusRaw = cached.statusRaw;
      opening = false;
    } else {
      title = row.title;
      items.clear();
      running = false;
      statusText = '';
      opening = true;
    }
    notifyListeners();
    try {
      final transcript = gw.api
          .sessionMessages(row.id)
          .then<List<Map<String, dynamic>>?>((v) => v, onError: (Object _) => null);
      final r = await gw.call('session.resume', {'session_id': row.id, 'source': 'mobile', 'omit_messages': true},
          const Duration(seconds: 60));
      if (gen != _openGen) return;
      // Live frames from before this snapshot are already in it.
      _held.clear();
      final rows = await transcript;
      if (gen != _openGen) return;
      final List<ChatItem> next;
      if (rows != null) {
        next = chatItemsFromRest(rows);
        _noteHistoryRows(rows.length);
      } else {
        // A serve without the REST transcript route: the old full resume.
        final full = await gw.call('session.resume', {'session_id': row.id, 'source': 'mobile'}, const Duration(seconds: 120));
        if (gen != _openGen) return;
        next = chatItemsFromResume(full['messages'] as List?);
        _noteHistoryRows((full['messages'] as List?)?.length ?? 0);
      }
      final isRunning = r['running'] == true;
      if (isRunning) appendInflight(next, r['inflight']);
      sid = '${r['session_id']}';
      items
        ..clear()
        ..addAll(next);
      _applyInfo((r['info'] as Map?)?.cast<String, dynamic>());
      running = isRunning;
      if (!isRunning) {
        _statusClear();
      } else if (_statusKey.isEmpty && _statusRaw.isEmpty) {
        _status('يعمل...');
      }
      unawaited(_applyReasoningFlag());
      _lastEventAt = clock();
      _idleStreak = 0;
      _busyStreak = 0;
      for (final q in (r['open_requests'] as List? ?? const [])) {
        pending = PendingRequest(q['id'] as Object, '${q['method']}', Map<String, dynamic>.from(q['params'] as Map));
      }
      opening = false;
      _loading = false;
      final held = List.of(_held);
      _held.clear();
      for (final e in held) {
        _onEvent(e);
      }
      loadCatalog();
      unawaited(refreshBackground());
    } catch (e) {
      if (gen == _openGen) _flash(L10n.t('تعذر فتح الجلسة: {0}', [e]));
    } finally {
      if (gen == _openGen) {
        opening = false;
        _loading = false;
        _held.clear();
        notifyListeners();
      }
    }
  }

  Future<void> newSession() async {
    _stash();
    ++_openGen;
    _loading = false;
    _held.clear();
    opening = true;
    items.clear();
    // 新会话没有任何历史：分页状态必须一起重置，否则会沿用上一个会话的
    // hasMoreOlder=true（顶部常驻"加载更早"），并反复触发 loadOlder → 画面抽动。
    hasMoreOlder = false;
    _olderOffset = 0;
    loadingOlder = false;
    olderEpoch = 0;
    pending = null;
    running = false;
    // 同上：不把本地化文案固化进数据，渲染处按当前语言兜底
    title = '';
    notifyListeners();
    try {
      final r = await gw.call('session.create', {'source': 'mobile'});
      sid = '${r['session_id']}';
      storedId = r['stored_session_id'] as String?;
      _applyInfo((r['info'] as Map?)?.cast<String, dynamic>());
      unawaited(_applyReasoningFlag());
      unawaited(refreshBackground());
    } catch (e) {
      _flash(L10n.t('تعذر إنشاء جلسة: {0}', [e]));
    }
    opening = false;
    notifyListeners();
  }

  Future<bool> send(String text) async {
    final t = text.trim();
    final inFlight = _openFuture;
    if (inFlight != null) await inFlight;
    if (sid == null || (t.isEmpty && attachments.isEmpty)) return false;
    if (t.startsWith('/') && attachments.isEmpty) {
      await _slash(t);
      return true;
    }
    return _sendDraft(t, steer: false);
  }

  Future<bool> _sendDraft(String text, {required bool steer, bool queue = false}) async {
    final sessionId = sid;
    if (submitting || sessionId == null || (text.isEmpty && attachments.isEmpty)) return false;
    final selected = List<Attachment>.of(attachments);
    if (selected.any((a) => a.uploading)) {
      _flash(L10n.t('انتظر اكتمال رفع المرفقات'));
      return false;
    }
    if (selected.any((a) => a.sessionId != sessionId)) {
      _flash(L10n.t('المرفقات تخص جلسة أخرى؛ احذفها وأرفقها هنا مجددًا'));
      return false;
    }
    submitting = true;
    notifyListeners();
    var accepted = false;
    try {
      for (final a in selected.where((a) => a.error != null || a.ref.isEmpty)) {
        await _upload(a);
        if (a.error != null || a.ref.isEmpty) return false;
      }
      if (sid != sessionId || selected.any((a) => !attachments.contains(a))) return false;
      if (queue) {
        queued.add(QueuedTurn(sessionId, text, selected));
        accepted = true;
        _flash(L10n.t('في الطابور: ستُرسل بعد انتهاء الدور الحالي'));
      } else {
        accepted = await _deliver(sessionId, text, selected, steer: steer);
      }
      if (accepted) attachments.removeWhere(selected.contains);
      return accepted;
    } finally {
      submitting = false;
      notifyListeners();
      if (accepted && !running) _drainQueue();
    }
  }

  Future<bool> _deliver(String sessionId, String text, List<Attachment> files, {bool steer = false}) async {
    final payload = [
      text,
      for (final a in files) a.ref,
      if (files.any((a) => a.isImage)) _imageHint,
      if (steer && files.any((a) => !a.isImage)) _fileHint,
    ].where((s) => s.isNotEmpty).join('\n\n');
    final item = ChatItem.user(text)..files = files.map((a) => a.path).toList();
    items.add(item);
    if (!steer) {
      running = true;
      _status('يفكر...');
      _submittedAt = clock();
    }
    notifyListeners();
    try {
      final result = await gw.call(steer ? 'session.steer' : 'prompt.submit',
          {'session_id': sessionId, 'text': payload});
      if (steer && (result is! Map || result['status'] != 'queued')) throw L10n.t('لم يُقبل التوجيه');
      if (steer && sid == sessionId) _flash(L10n.t('تم التوجيه'));
      return true;
    } catch (e) {
      items.remove(item);
      if (sid == sessionId) {
        if (!steer) running = false;
        // Owned elsewhere: offer the pull (reason travels as machine-readable data;
        // the message check keeps older serves without the reason field working).
        final ownedElsewhere = !steer &&
            e is RpcError &&
            (e.reason == 'SESSION_NOT_OWNED' || e.message.contains('another Hermes window'));
        if (ownedElsewhere) {
          pendingPull = PullOffer(text, sessionId);
          notifyListeners();
        } else {
          _flash(steer ? L10n.t('تعذر التوجيه: {0}', [e]) : L10n.t('تعذر الإرسال: {0}', [e]));
        }
      }
      return false;
    }
  }

  /// Pull the session from the device that owns it, then resend the refused draft.
  Future<void> acceptPull() async {
    final offer = pendingPull;
    if (offer == null || pulling) return;
    pulling = true;
    _pullClear();
    notifyListeners();
    try {
      final r = await gw.call('session.takeover', {'session_id': offer.sessionId}, const Duration(seconds: 45));
      final surface = r is Map ? '${r['holder_surface'] ?? ''}' : '';
      pendingPull = null;
      pulling = false;
      notifyListeners();
      _flash(surface.isEmpty ? L10n.t('تم سحب الجلسة إلى الجوال') : L10n.t('تم سحب الجلسة من {0} إلى الجوال', [_surfaceAr(surface)]));
      if (sid == offer.sessionId && !running) await _sendDraft(offer.text, steer: false);
    } on RpcError catch (e) {
      pulling = false;
      final holder = e.data is Map ? (e.data as Map)['holder_surface'] as String? : null;
      switch (e.reason) {
        case 'TAKEOVER_BUSY':
          _pullSet('الجلسة تعمل الآن على {0} ولم ينتهِ دورها بعد؛ أوقف الدور من هناك ثم حاول السحب مرة أخرى.', [_surfaceAr(holder)]);
        case 'TAKEOVER_RACED':
          _pullSet('بدأت الجلسة دورًا جديدًا على الجهاز الآخر؛ انتظر قليلًا ثم حاول مرة أخرى.');
        case 'SESSION_CAP':
          _pullSet('لا يمكن سحب الجلسة الآن: بلغت حد الجلسات المتزامنة.');
        default:
          _pullSet('تعذر سحب الجلسة: {0}', ['$e']);
      }
      notifyListeners();
    } catch (e) {
      pulling = false;
      _pullSet('تعذر سحب الجلسة: {0}', ['$e']);
      notifyListeners();
    }
  }

  void dismissPull() {
    if (pendingPull == null && pullError == null) return;
    pendingPull = null;
    _pullClear();
    notifyListeners();
  }

  Future<void> _slash(String cmd) async {
    items.add(ChatItem.user(cmd));
    notifyListeners();
    final body = cmd.substring(1);
    final name = body.split(RegExp(r'\s+')).first;
    final arg = body.substring(name.length).trim();
    Map? r;
    try {
      r = await gw.call('slash.exec', {'session_id': sid, 'command': body}, const Duration(seconds: 120)) as Map?;
    } catch (_) {
      try {
        r = await gw.call('command.dispatch', {'session_id': sid, 'name': name, 'arg': arg}) as Map?;
      } catch (e) {
        items.add(ChatItem.notice(L10n.t('تعذر تنفيذ /{0}: {1}', [name, e])));
        notifyListeners();
        return;
      }
    }
    final type = r?['type'];
    if ((type == 'send' || type == 'skill') && (r?['message'] as String?)?.isNotEmpty == true) {
      running = true;
      notifyListeners();
      await gw.call('prompt.submit', {
        'session_id': sid,
        'text': r!['message'],
        if (r['display'] != null) 'display_kind': null,
      }).catchError((_) => null);
    } else if (type == 'alias' && r?['target'] != null) {
      items.removeLast();
      notifyListeners();
      await _slash('/${r!['target']}');
      return;
    } else {
      final out = '${r?['output'] ?? r?['notice'] ?? ''}'.trim();
      items.add(ChatItem.notice(out.isEmpty ? L10n.t('/{0}: تم', [name]) : out));
    }
    if (name == 'model' || name == 'reasoning' || name == 'fast' || name == 'yolo') refreshInfo();
    notifyListeners();
  }

  Future<void> refreshInfo() async {
    if (sid == null) return;
    try {
      final r = await gw.call('session.status', {'session_id': sid});
      if (r is Map && r['info'] is Map) _applyInfo((r['info'] as Map).cast<String, dynamic>());
    } catch (_) {}
    notifyListeners();
  }

  Future<bool> setConfig(String key, String value, {
    Future<bool> Function(String message)? confirm,
  }) async {
    final target = sid;
    if (target == null) return false;
    try {
      final params = <String, dynamic>{'session_id': target, 'key': key, 'value': value};
      var r = await gw.call('config.set', params);
      if (sid != target) return false;
      if (r is Map && r['confirm_required'] == true) {
        final message = '${r['confirm_message'] ?? r['warning'] ?? L10n.t('يتطلب تغيير النموذج تأكيدًا.')}';
        if (confirm == null) {
          _flash(message);
          return false;
        }
        final accepted = await confirm(message);
        if (!accepted || sid != target) return false;
        r = await gw.call('config.set', {...params, 'confirm_expensive_model': true});
        if (sid != target) return false;
        if (r is Map && r['confirm_required'] == true) {
          _flash(L10n.t('لم يقبل الخادم تأكيد التغيير. لم يتم تغيير النموذج.'));
          return false;
        }
      }
      if (r is Map && r['info'] is Map) _applyInfo((r['info'] as Map).cast<String, dynamic>());
      if (key == 'model') {
        final parts = value.split(' --provider ');
        currentModel = parts.first;
        if (parts.length > 1) currentProvider = parts[1].trim();
      }
      if (key == 'fast') info['fast'] = value == 'fast';
      if (key == 'yolo') info['yolo'] = value == 'on';
      if (key == 'reasoning') info['reasoning_effort'] = value;
      if (r is Map && r['warning'] != null) _flash('${r['warning']}');
      notifyListeners();
      return true;
    } catch (e) {
      _flash(L10n.t('تعذر التغيير: {0}', [e]));
      return false;
    }
  }

  Future<bool> enqueue(String text) => _sendDraft(text.trim(), steer: false, queue: true);

  void unqueue(int i) {
    if (i < 0 || i >= queued.length) return;
    queued.removeAt(i);
    notifyListeners();
  }

  /// Steer is text-only on the gateway. Explicit paths and reading instructions
  /// travel with it; accepted corrections render as user cards, not thinking.
  Future<bool> steer(String text) => _sendDraft(text.trim(), steer: true);

  Future<void> retryQueue() => _drainQueue();

  QueuedTurn? _draining;

  Future<void> _drainQueue() async {
    if (queued.isEmpty || sid == null || running || submitting || _draining != null) return;
    final next = queued.first;
    if (next.sessionId != sid) return;
    _draining = next;
    var accepted = false;
    try {
      if (next.files.isEmpty && next.text.startsWith('/')) {
        await _slash(next.text);
        accepted = true;
      } else {
        accepted = await _deliver(next.sessionId, next.text, next.files);
      }
      if (accepted) queued.remove(next);
    } finally {
      _draining = null;
      notifyListeners();
    }
    // A completion can arrive before the submit acknowledgement. Only now may
    // the next frozen turn drain; never re-submit the still-pending first one.
    if (accepted && !running) _drainQueue();
  }

  /// Stage bytes only; never arm the gateway's shared attached_images queue.
  /// Each outgoing turn carries its own explicit references instead.
  Future<void> attach(String name, List<int> bytes) async {
    final sessionId = sid;
    if (sessionId == null) return;
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    final isImage = const {'png', 'jpg', 'jpeg', 'webp', 'gif', 'heic', 'bmp'}.contains(ext);
    final a = Attachment(name, isImage, sessionId: sessionId, bytes: List.of(bytes));
    attachments.add(a);
    await _upload(a);
  }

  Future<void> _upload(Attachment a) async {
    a.uploading = true;
    a.error = null;
    notifyListeners();
    try {
      final ext = a.name.split('.').last.toLowerCase();
      final r = await gw.call('file.attach', {
        'session_id': a.sessionId,
        'data_url': 'data:${_mimeOf(ext)};base64,${base64Encode(a.bytes)}',
        'name': a.name,
      }, const Duration(seconds: 120));
      if (r is! Map || r['attached'] == false) throw L10n.t('رُفض الملف');
      a.path = '${r['path'] ?? ''}';
      if (a.path.isEmpty) throw L10n.t('لم يُرجع الخادم مسار الملف');
      a.ref = '@${a.isImage ? 'image' : 'file'}:${_quoteRef(a.path)}';
      a.bytes = const [];
    } catch (e) {
      a.error = '$e';
      _flash(L10n.t('تعذر إرفاق {0}: {1} — أعد الإرسال للمحاولة', [a.name, e]));
    } finally {
      a.uploading = false;
      notifyListeners();
    }
  }

  Future<void> detach(Attachment a) async {
    attachments.remove(a);
    notifyListeners();
  }

  /// Release this client's hold on the session so another window (the
  /// desktop) can take it over; the stored conversation stays resumable.
  Future<void> closeSession() async {
    final id = sid;
    if (id == null) return;
    try {
      await gw.call('session.close', {'session_id': id});
      _flash(L10n.t('أُغلقت الجلسة على الجوال، ويمكن فتحها الآن من سطح المكتب'));
    } catch (e) {
      _flash(L10n.t('تعذر إغلاق الجلسة: {0}', [e]));
      return;
    }
    if (storedId != null) _views.remove(storedId);
    sid = null;
    storedId = null;
    items.clear();
    attachments.clear();
    queued.clear();
    pending = null;
    running = false;
    refreshActive();
    notifyListeners();
  }

  Future<void> interrupt() async {
    if (sid == null) return;
    await gw.call('session.interrupt', {'session_id': sid}).catchError((_) => null);
  }

  /// 审批卡的回执（``{"choice": once|session|always|deny}``）。
  void answer(Object? result) {
    final p = pending;
    if (p == null) return;
    _trace('→ ${p.method} ${_brief(result)}');
    gw.respond(p.id, result);
    pending = null;
    notifyListeners();
  }

  /// 提问卡（``clarify``）的回执。协议见 tui_gateway/contracts/server_requests.py：
  /// 结果必须是 ``{"answers": {qid: value}}``；**没有 answers 的响应 = 全部取消**。
  /// 单选 = 字符串，多选 = 字符串数组（或 JSON 数组字符串），跳过的 qid 不要放进 map。
  void answerClarify(Map<String, Object?> answers) {
    final p = pending;
    if (p == null) return;
    final frame = <String, Object?>{'answers': answers};
    _trace('→ clarify ${_brief(frame)}');
    gw.respond(p.id, frame);
    pending = null;
    notifyListeners();
  }

  /// 明确取消当前提问/审批（空结果 = cancel-all / 拒绝）。
  void cancelPending() {
    final p = pending;
    if (p == null) return;
    _trace('→ ${p.method} (cancel)');
    gw.respond(p.id, const <String, Object?>{});
    pending = null;
    notifyListeners();
  }

  void _onRequest(Map<String, dynamic> msg) {
    final method = '${msg['method']}';
    final params = Map<String, dynamic>.from(msg['params'] as Map? ?? {});
    if (method != 'approval' && method != 'clarify') {
      gw.respondError(msg['id'] as Object, L10n.t('غير مدعوم في تطبيق الجوال'));
      return;
    }
    if (params['session_id'] != null && params['session_id'] != sid) return;
    pending = PendingRequest(msg['id'] as Object, method, params);
    _trace('← $method ${_brief(params)}');
    H.attention();
    Notify.i.ask(
      title: title.isEmpty ? L10n.t('جلسة') : title,
      body: method.contains('approval') ? L10n.t('يحتاج إلى موافقتك لتنفيذ أمر') : L10n.t('لديه سؤال ينتظر إجابتك'),
      session: storedId,
    );
    notifyListeners();
  }

  /// 本回合正在流式输出的那条助手气泡：**只认 items.last**。
  ///
  /// 这里刻意不往前找：工具行/思考块一旦插在回复后面，就说明上一段话已经封口，
  /// 后续 delta 属于新的一段（Hermes 的一轮里可以有"先说一句 → 调工具 → 再说一句"），
  /// 必须新开气泡。以前往前找，于是工具行之后的文字全被塞回工具行上面 —— 顺序全乱。
  ChatItem? _streamTarget() {
    if (items.isEmpty) return null;
    final last = items.last;
    return (last.kind == 'assistant' && !last.sealed) ? last : null;
  }

  /// 把还在流的助手气泡封口（工具行/思考块/结束符插进来之前调用）。
  void _sealStream() {
    for (var i = items.length - 1; i >= 0; i--) {
      final it = items[i];
      if (it.kind != 'assistant') break;
      it.done = true;
      it.sealed = true;
      if (it.text.trim().isEmpty) {
        items.removeAt(i);
        continue;
      }
      break;
    }
  }

  /// Whether the current turn (items after the last user message) already
  /// shows a thinking block.
  bool _turnHasThinking() {
    for (final it in items.reversed) {
      if (it.kind == 'user') return false;
      if (it.kind == 'thinking') return true;
    }
    return false;
  }

  /// 本回合（最后一条 user 之后）是否已经有内容完全相同的助手气泡。
  /// 用来挡住"同一段文字被投递两次"（interim + complete、重连重放等）。
  bool _turnHasAssistantText(String text) {
    final want = text.trim();
    if (want.isEmpty) return false;
    for (final it in items.reversed) {
      if (it.kind == 'user') return false;
      if (it.kind == 'assistant' && it.text.trim() == want) return true;
    }
    return false;
  }

  // ---------------------------------------------------------------- background
  // Live background work for the open session (desktop parity): the gateway's
  // process registry plus delegated subagents, merged into one strip above the
  // composer so a long-running job is visible while the turn itself is idle.

  final background = <BackgroundActivity>[];
  Duration backgroundLingerSuccess = const Duration(seconds: 6);
  Duration backgroundLingerFailure = const Duration(seconds: 20);

  final _dismissed = <String>{};
  final _linger = <String, Timer>{};

  /// 上一轮轮询里服务端仍然在报的 id（进程/子代理）。
  ///
  /// 服务端的 `process.list` 语义是"运行中 **+ 刚结束**的进程"。旧实现让"结束 6 秒后自动消失"
  /// 和轮询直接打架：删掉 → 下一轮又被服务端报回来 → 再删掉，于是面板 6 秒一个来回地闪。
  /// 现在行跟着服务端走：还在报就留着，服务端不再报了才删。
  final _serverRows = <String>{};
  Timer? _bgTimer;
  bool _bgBusy = false;

  int get runningBackground => background.where((b) => b.running).length;

  BackgroundActivity? _bgRow(String id) {
    for (final row in background) {
      if (row.id == id) return row;
    }
    return null;
  }

  BackgroundActivity _bgUpsert(String id, String kind, String title) {
    final existing = _bgRow(id);
    if (existing != null) return existing;
    final created = BackgroundActivity(id: id, kind: kind, title: title);
    background.add(created);
    return created;
  }

  void clearBackground() {
    for (final t in _linger.values) {
      t.cancel();
    }
    _linger.clear();
    _dismissed.clear();
    _serverRows.clear();
    background.clear();
    notifyListeners();
  }

  /// Finished rows clear themselves so the strip only ever holds live work.
  /// Failures linger longer so the exit code stays readable; a row that goes
  /// back to running cancels its pending clear.
  ///
  /// 2026-10-16 修正：**服务端还在报的行不许定时删**。`process.list` 会一直带着刚结束的进程，
  /// 定时删 + 下一轮又报回来 = 面板 6 秒一闪。服务端不再报了（或事件型行）才走 linger。
  void _armLinger(BackgroundActivity row) {
    if (row.running || _serverRows.contains(row.id)) {
      _linger.remove(row.id)?.cancel();
      return;
    }
    if (_linger.containsKey(row.id)) return;
    final delay = row.state == BackgroundState.failed ? backgroundLingerFailure : backgroundLingerSuccess;
    _linger[row.id] = Timer(delay, () {
      _linger.remove(row.id);
      background.removeWhere((b) => b.id == row.id);
      notifyListeners();
    });
  }

  void _appendOutput(String processId, String chunk) {
    if (processId.isEmpty || chunk.isEmpty || _dismissed.contains(processId)) return;
    final row = _bgUpsert(processId, 'process', L10n.t('عملية في الخلفية'));
    row.state = BackgroundState.running;
    _linger.remove(processId)?.cancel();
    row.detail = '${row.detail}$chunk';
    if (row.detail.length > backgroundDetailLimit) {
      row.detail = row.detail.substring(row.detail.length - backgroundDetailLimit);
    }
  }

  /// Poll the session's process registry and subagent list. Single-flight: a
  /// slow poll must never stack behind the next timer tick.
  Future<void> refreshBackground() async {
    final id = _sid;
    if (id == null || _bgBusy) return;
    _bgBusy = true;
    try {
      final results = await Future.wait([
        gw.call('process.list', {'session_id': id}),
        gw.call('subagent.list', {'session_id': id}),
      ]);
      if (_sid != id) return;
      final processes = (results[0] as Map?)?['processes'] as List? ?? const [];
      final subagents = (results[1] as Map?)?['subagents'] as List? ?? const [];
      _serverRows
        ..clear()
        ..addAll(_reportedIds(processes, 'session_id'))
        ..addAll(_reportedIds(subagents, 'subagent_id'));
      _reconcileProcesses(processes);
      _reconcileSubagents(subagents);
      // 服务端已经不再报、且不是"运行中"的行 = 真的结束了 → 删掉。
      // 反过来：**服务端还在报的（含刚结束的）保持可见**，这是面板不闪的关键。
      background.removeWhere((b) =>
          (b.kind == 'process' || b.kind == 'subagent') &&
          !b.running &&
          !_serverRows.contains(b.id));
    } catch (_) {
      // Transient socket loss, or a backend without these RPCs: keep the
      // event-fed rows and let the next poll retry.
    } finally {
      _bgBusy = false;
    }
    notifyListeners();
  }

  Set<String> _reportedIds(List rows, String key) => {
        for (final raw in rows)
          if (raw is Map && '${raw[key] ?? ''}'.isNotEmpty) '${raw[key]}',
      };

  void _reconcileProcesses(List rows) {
    final reported = <String>{};
    for (final raw in rows) {
      if (raw is! Map) continue;
      final p = raw.cast<String, dynamic>();
      final id = '${p['session_id'] ?? ''}';
      if (id.isEmpty) continue;
      reported.add(id);
      if (_dismissed.contains(id)) continue;
      final status = '${p['status'] ?? 'running'}';
      final exit = (p['exit_code'] as num?)?.toInt();
      final row = _bgUpsert(id, 'process', BackgroundActivity.firstLine('${p['command'] ?? ''}'));
      final title = BackgroundActivity.firstLine('${p['command'] ?? ''}');
      if (title.isNotEmpty) row.title = title;
      row.exitCode = exit;
      row.state = BackgroundActivity.stateForProcess(status, exit);
      final tail = '${p['output_tail'] ?? ''}';
      if (row.detail.isEmpty && tail.isNotEmpty) row.detail = tail;
      _armLinger(row);
    }
    // Dismissals only need remembering while the registry still reports the id.
    _dismissed.removeWhere((id) => !reported.contains(id));
  }

  void _reconcileSubagents(List rows) {
    for (final raw in rows) {
      if (raw is! Map) continue;
      final s = raw.cast<String, dynamic>();
      final id = '${s['subagent_id'] ?? ''}';
      if (id.isEmpty || _dismissed.contains(id)) continue;
      final goal = '${s['goal'] ?? ''}'.trim();
      final row = _bgUpsert(id, 'subagent', goal.isEmpty ? L10n.t('مهمة فرعية') : goal);
      if (goal.isNotEmpty) row.title = goal;
      final model = '${s['model'] ?? ''}';
      if (model.isNotEmpty) row.model = model;
      final tools = (s['tool_count'] as num?)?.toInt();
      if (tools != null) row.toolCount = tools;
      final last = '${s['last_tool'] ?? ''}'.trim();
      if (last.isNotEmpty) row.subtitle = last;
      row.state = BackgroundActivity.stateForSubagent('${s['status'] ?? ''}', fallback: row.state);
      _armLinger(row);
    }
  }

  /// 子代理的实时 transcript 尾巴（``subagent.tail``：最多 16KB）。
  /// 背景活动面板点开一个子代理时轮询它 —— 以前子代理行根本点不开。
  Future<String> subagentTail(String subagentId) async {
    // 演示/取证模式：没连服务器时用预置文本（见 demo.dart）。
    if (demoTails.containsKey(subagentId)) return demoTails[subagentId]!;
    final id = _sid;
    if (id == null || subagentId.isEmpty) return '';
    try {
      final r = await gw.call('subagent.tail', {'session_id': id, 'subagent_id': subagentId},
          const Duration(seconds: 25));
      final text = '${r['text'] ?? ''}';
      if (text.trim().isEmpty) return '';
      return r['truncated'] == true ? '…\n$text' : text;
    } catch (_) {
      return '';
    }
  }

  void _onSubagentEvent(String type, Map<String, dynamic> p) {
    final id = '${p['subagent_id'] ?? p['delegation_id'] ?? 'sub-${p['task_index'] ?? 0}'}';
    final goal = '${p['goal'] ?? ''}'.trim();
    final row = _bgUpsert(id, 'subagent', goal.isEmpty ? L10n.t('مهمة فرعية') : goal);
    if (goal.isNotEmpty) row.title = goal;
    final model = '${p['model'] ?? ''}';
    if (model.isNotEmpty) row.model = model;
    final tools = (p['tool_count'] as num?)?.toInt();
    if (tools != null) row.toolCount = tools;
    final tool = '${p['tool_name'] ?? ''}'.trim();
    if (tool.isNotEmpty) row.subtitle = tool;
    final preview = '${p['tool_preview'] ?? p['text'] ?? ''}'.trim();
    if (type == 'subagent.thinking' && preview.isNotEmpty) row.subtitle = preview;
    row.state = type == 'subagent.complete'
        ? BackgroundActivity.stateForSubagent('${p['status'] ?? 'completed'}', fallback: BackgroundState.done)
        : BackgroundState.running;
    final summary = '${p['summary'] ?? ''}'.trim();
    if (row.detail.isEmpty && summary.isNotEmpty) row.detail = summary;
    _armLinger(row);
  }

  /// Stop live background work: kill the process, or interrupt the child agent.
  /// The row is dropped only after the server confirms.
  Future<void> stopBackground(String id) async {
    final session = _sid;
    final row = _bgRow(id);
    if (row == null || session == null) return;
    final subagent = row.kind == 'subagent';
    try {
      await gw.call(subagent ? 'subagent.interrupt' : 'process.kill', {
        'session_id': session,
        if (subagent) 'subagent_id': id else 'process_id': id,
      });
    } catch (e) {
      _flash(subagent ? L10n.t('تعذر إيقاف المهمة الفرعية: {0}', [e]) : L10n.t('تعذر إيقاف العملية: {0}', [e]));
      return;
    }
    dismissBackground(id);
  }

  /// Hide a finished row. The dismissal is remembered until the registry stops
  /// reporting the id, so a poll in flight cannot resurrect it.
  void dismissBackground(String id) {
    _linger.remove(id)?.cancel();
    _dismissed.add(id);
    background.removeWhere((b) => b.id == id);
    notifyListeners();
  }

  // --- Running state ---------------------------------------------------------
  //
  // Events drive `running`; the 4 s active-list poll only corrects it, and only
  // when it is clearly wrong. The server keeps `running` true for a moment after
  // `message.complete` (and reports `starting` while it builds an agent on a
  /// ── 历史分页（上滑加载更早的消息）────────────────────────────────
  /// 服务端 `GET /api/sessions/<sid>/messages?limit&offset&order=latest`
  /// 的 offset 以"数据库消息行"计（不是 chat item 数），所以这里单独记 `_olderOffset`。
  bool loadingOlder = false;
  bool hasMoreOlder = true;
  /// 是否显示模型思考内容（默认关）。开启后用 `/reasoning show` 让网关**本会话**开始推送
  /// reasoning.delta；关闭则 hide。服务端 display.show_reasoning 默认 false，所以不开就一个字节都没有。
  bool showReasoning = false;
  static const _reasoningKey = 'hermes.showReasoning';
  int _olderOffset = 0;
  /// 每成功插入一页"更早的消息"就 +1；UI 用它区分"头顶增长"（需要补偿）和"末尾增长"（不用管）。
  int olderEpoch = 0;

  /// 打开会话时记下已经载入了多少行（后续 offset 从这里接着翻）。
  void _noteHistoryRows(int rows) {
    _olderOffset = rows;
    hasMoreOlder = rows >= 20;
  }

  /// 读上次的选择（默认关）。
  Future<void> restoreShowReasoning() async {
    try {
      final v = await const FlutterSecureStorage().read(key: _reasoningKey);
      showReasoning = v == '1';
      notifyListeners();
    } catch (_) {}
  }

  /// 切换思考内容显示。写本地偏好 + 立刻对本会话生效（不改全局 config.yaml）。
  Future<void> setShowReasoning(bool on) async {
    showReasoning = on;
    notifyListeners();
    try {
      await const FlutterSecureStorage().write(key: _reasoningKey, value: on ? '1' : '0');
    } catch (_) {}
    await _applyReasoningFlag();
  }

  /// 把当前开关同步给网关（会话级）。会话还没起来时跳过，open/new 之后会再同步。
  Future<void> _applyReasoningFlag() async {
    final s = sid;
    if (s == null || s.isEmpty) return;
    try {
      await gw.call('command.dispatch', {
        'session_id': s,
        'name': 'reasoning',
        'arg': showReasoning ? 'show' : 'hide',
      }, const Duration(seconds: 10));
    } catch (_) {
      // 老网关没有这个命令就静默降级：只是看不到思考内容，不影响对话。
    }
  }

  Future<void> loadOlder({int page = 100}) async {
    if (loadingOlder || !hasMoreOlder) return;
    if (kTrace) htrace('loadOlder.call', {'page': page, 'offset': _olderOffset, 'items': items.length});
    final api = currentApi;
    final id = sid;
    if (api == null || id == null || id.isEmpty) return;
    loadingOlder = true;
    notifyListeners();
    try {
      final rows = await api.sessionMessages(id, limit: page, offset: _olderOffset);
      if (rows.length < page) hasMoreOlder = false;
      _olderOffset += rows.length;
      final older = chatItemsFromResume(rows);
      if (kTrace) {
        htrace('older', {
          'rows': rows.length,
          'items_before': items.length,
          'parsed': older.length,
          'first_parsed': older.isNotEmpty ? older.first.text.replaceAll('\n', ' ').substring(0, older.first.text.length.clamp(0, 24)) : '',
          'roles': rows.take(6).map((r) => '${r['role']}').join(','),
        });
      }
      if (older.isNotEmpty) {
        // 新页是更早的内容：插到列表头部（列表本身是"旧 → 新"的顺序）。
        final boundary = items.isNotEmpty ? items.first : null;
        var merged = older;
        if (boundary != null) {
          // 去掉分页边界上的重复项（同角色同文本）。
          while (merged.isNotEmpty &&
              merged.last.kind == boundary.kind &&
              merged.last.text.trim() == boundary.text.trim()) {
            merged = merged.sublist(0, merged.length - 1);
          }
        }
        items.insertAll(0, merged);
        olderEpoch++;
        if (kTrace) {
          htrace('older.merged', {
            'merged': merged.length,
            'items_after': items.length,
            'epoch': olderEpoch,
            'head_empty': items.isEmpty ? -1 : items.first.text.trim().length,
            'tail_empty': items.isEmpty ? -1 : items.last.text.trim().length,
          });
        }
      }
    } catch (_) {
      // 失败就保持原样，下次滑动再试
    } finally {
      loadingOlder = false;
      notifyListeners();
    }
  }

  /// 补进"别处发来的用户消息"：服务端只广播 assistant 的 message.* ，用户行不广播，
  /// 所以换设备/多客户端时，另一头发的话在本机要主动拉一页 transcript 合并进来。
  DateTime? _lastForeignSync;

  Future<void> syncForeignMessages() async {
    final api = currentApi;
    final id = sid;
    if (api == null || id == null || id.isEmpty) return;
    final now = clock();
    if (_lastForeignSync != null && now.difference(_lastForeignSync!) < const Duration(seconds: 2)) return;
    _lastForeignSync = now;
    try {
      final rows = await api.sessionMessages(id, limit: 8);
      final text = lastUserText(rows);
      if (text == null || text.isEmpty) return;
      if (!needsForeignUser(items, text)) return;
      // 只追加到末尾：此时上一轮已经结束，新的一轮 assistant 内容会接在它后面。
      items.add(ChatItem.user(text));
      notifyListeners();
    } catch (_) {
      // 拉不到就算了，不打断当前流
    }
  }

  // plain resume), so trusting a single poll pinned the chat as running forever.

  /// Clock for the running-state guards (tests move it).
  @visibleForTesting
  DateTime Function() clock = DateTime.now;

  DateTime _lastEventAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _turnEndedAt = DateTime.fromMillisecondsSinceEpoch(0);
  DateTime _submittedAt = DateTime.fromMillisecondsSinceEpoch(0);
  int _idleStreak = 0;
  int _busyStreak = 0;

  void _reconcileRunning(ActiveSession? mine) {
    final now = clock();
    final status = mine?.status ?? '';
    final busy = status == 'working' || status == 'waiting' || status == 'streaming';
    final idle = mine != null && status == 'idle';
    if (busy && !running) {
      _idleStreak = 0;
      if (now.difference(_turnEndedAt) > const Duration(seconds: 8) && ++_busyStreak >= 2) {
        _busyStreak = 0;
        running = true;
        if (statusText.isEmpty) _status('يعمل...');
      }
    } else if (idle && running) {
      _busyStreak = 0;
      if (now.difference(_lastEventAt) > const Duration(seconds: 6) &&
          now.difference(_submittedAt) > const Duration(seconds: 10) &&
          ++_idleStreak >= 2) {
        _idleStreak = 0;
        _closeThinking();
        running = false;
        statusText = '';
        _turnEndedAt = now;
        final last = items.isNotEmpty ? items.last : null;
        if (last != null && last.kind == 'assistant' && last.text.trim().isEmpty) items.removeLast();
        unawaited(_drainQueue());
      }
    } else {
      _idleStreak = 0;
      _busyStreak = 0;
    }
  }

  void _onEvent(Map<String, dynamic> e) {
    final type = '${e['type']}';
    if (kTrace) {
      final pl = (e['payload'] is Map) ? Map<String, dynamic>.from(e['payload'] as Map) : const <String, dynamic>{};
      htrace('event', {
        'type': type,
        'items': items.length,
        'dlen': '${pl['text'] ?? ''}'.length,
        'sid': '${pl['session_id'] ?? e['session_id'] ?? ''}',
      });
    }
    // Off by default; a diagnostic build passes --dart-define=HERMES_TRACE_EVENTS=true.
    // Logs the event type only, never the payload.
    if (const bool.fromEnvironment('HERMES_TRACE_EVENTS')) debugPrint('EVT $type');
    final payload = (e['payload'] is Map) ? Map<String, dynamic>.from(e['payload'] as Map) : <String, dynamic>{};
    // 调试面板留痕：高频的 delta / 终端输出不进（会淹掉关键帧）。
    if (type != 'message.delta' && type != 'reasoning.delta' && type != 'thinking.delta' &&
        type != 'agent.terminal.output' && type != 'status.update') {
      _trace('← $type ${_brief(e['payload'])}');
    }
    if (type == 'sessions.changed') {
      final changed = '${payload['session_id'] ?? ''}';
      if (changed.isEmpty || changed == sid) unawaited(syncForeignMessages());
      _debounceSessions();
      return;
    }
    if (type == 'client.reconnected') {
      final row = storedId;
      if (row != null) {
        openSession(SessionRow(row, title, '', 0, 0));
      }
      return;
    }
    if (type == 'request.cancel') {
      if (pending != null && '${payload['id']}' == '${pending!.id}') {
        pending = null;
        notifyListeners();
      }
      return;
    }
    if (_loading) {
      if (_held.length < 4000) _held.add(e);
      return;
    }
    if (sid == null || e['session_id'] != sid) {
      // A session left running in the background finished: its cached view
      // must not come back as running.
      if (type == 'message.complete' || type == 'error') {
        for (final v in _views.values) {
          if (v.sid == e['session_id']) {
            v.running = false;
            v.clearStatus();
          }
        }
      }
      return;
    }
    _lastEventAt = clock();
    switch (type) {
      case 'agent.terminal.output':
        _appendOutput('${payload['process_id'] ?? ''}', '${payload['chunk'] ?? ''}');
      case 'terminal.close':
        final row = _bgRow('${payload['process_id'] ?? ''}');
        if (row != null && row.running) {
          row.state = BackgroundState.done;
          _armLinger(row);
        }
      case 'subagent.start' || 'subagent.progress' || 'subagent.tool' || 'subagent.thinking' || 'subagent.complete':
        _onSubagentEvent(type, payload);
      case 'background.complete':
        final id = '${payload['task_id'] ?? ''}';
        if (id.isNotEmpty) {
          final row = _bgUpsert(id, 'agent', L10n.t('مهمة خلفية'));
          row.state = BackgroundState.done;
          final text = '${payload['text'] ?? ''}'.trim();
          if (text.isNotEmpty) row.detail = text;
          _armLinger(row);
        }
      case 'message.start':
        // 刻意不在这里插占位气泡：Hermes 一轮里"先说一句 → 调工具 → 再说一句"，
        // 占位符排在最前面会把后面所有工具行顶到回复上方（用户看到的"工具全堆在前面"）。
        // 气泡改由第一条 message.delta 现场创建，位置就是它真正该在的时间点。
        running = true;
        _status('يفكر...');
        unawaited(syncForeignMessages());
      case 'thinking.delta':
        // Spinner rewrites ("(◔_◔) ruminating...") and provider-wait notices,
        // not reasoning: status line only (desktop does the same). Treating
        // them as transcript thinking split a streaming reply in two.
        running = true;
        final t = '${payload['text'] ?? ''}'.trim();
        if (t.isNotEmpty) statusText = t;
      case 'reasoning.delta':
        running = true;
        _status('يفكر...');
        final t = '${payload['text'] ?? ''}';
        final last = items.isNotEmpty ? items.last : null;
        if (last != null && last.kind == 'thinking' && !last.done) {
          last.text += t;
        } else {
          // 思考块要插在当前流式气泡之前：先给还在流的那段封口。
          _sealStream();
          items.add(ChatItem.thinking(t));
        }
      case 'reasoning.available':
        // The full reasoning can arrive after the reply started streaming. It
        // belongs to this turn: skip it when the turn already streamed its
        // thinking, and never append it after the reply (that orphaned the
        // reply, so message.complete then added a second copy).
        final t = '${payload['text'] ?? ''}';
        if (t.isEmpty || _turnHasThinking()) break;
        final block = ChatItem.thinking(t)..done = true;
        if (items.isNotEmpty && items.last.kind == 'assistant') {
          items.insert(items.length - 1, block);
        } else {
          items.add(block);
        }
      case 'message.interim':
        // 工具调用前后的旁白（agent.interim_assistant_callback）：服务端把它封成自己的一段。
        // already_streamed=true 表示这段文字已经通过 message.delta 流出来了，别再塞一遍。
        final t = '${payload['text'] ?? ''}';
        final already = payload['already_streamed'] == true;
        if (already) {
          _sealStream();
        } else if (t.trim().isNotEmpty) {
          _sealStream();
          // 这段旁白整段到达（没走流式）：直接封口，后续 delta 属于新的一段。
          items.add(ChatItem.assistant(t)..sealed = true);
        }
        if (!running) {
          running = true;
          _status('يكتب الرد...');
        }
      case 'message.delta':
        _closeThinking();
        _status('يكتب الرد...');
        final t = '${payload['text'] ?? ''}';
        final target = _streamTarget();
        if (target == null) {
          items.add(ChatItem.assistant(t)..done = false);
        } else if (t.length >= 8 && target.text.endsWith(t)) {
          // 重连/重放会把同一段 delta 再发一遍（"两次输出"的常见来源之一）：
          // 尾巴已经带了这段，就别再追加。短于 8 字符的不做这个判断，
          // 免得把模型真的重复写的短片段（如连续两个"。"）吃掉。
          target.done = false;
        } else {
          target.text += t;
          target.done = false;
        }
      case 'message.complete':
        _closeThinking();
        running = false;
        _turnEndedAt = clock();
        statusText = '';
        final text = '${payload['text'] ?? ''}';
        // response_previewed: 这段最终文字已经作为 interim 交付过，别再写一遍。
        final previewed = payload['response_previewed'] == true;
        final target = _streamTarget();
        if (target != null) {
          if (text.isNotEmpty && !previewed) target.text = text;
          target.done = true;
          if (target.text.trim().isEmpty) {
            items.removeLast();
          }
        } else if (text.isNotEmpty && !previewed) {
          // 没有正在流的气泡：本回合任何一条助手文字跟它一样就不再写一遍
          // （interim 已交付过的那段、或收尾重复投递，都会走到这里）。
          if (!_turnHasAssistantText(text)) items.add(ChatItem.assistant(text));
        }
        _debounceSessions();
        if (queued.isEmpty) {
          H.success();
          final last = items.lastWhere((i) => i.kind == 'assistant', orElse: () => ChatItem.assistant(''));
          Notify.i.done(title: title.isEmpty ? L10n.t('جلسة') : title, body: last.text, session: storedId);
        }
        _drainQueue();
      case 'tool.start':
        _closeThinking();
        _status('ينفّذ {0}...', '${payload['name'] ?? L10n.t('أداة')}');
        final ctx = '${payload['context'] ?? payload['preview'] ?? ''}';
        _sealStream();
        items.add(ChatItem.tool('${payload['name']}',
            toolId: '${payload['tool_id']}',
            detail: ctx,
            argsText: _argsText(payload),
            done: false));
      case 'tool.complete':
        // A background spawn usually appears right after its tool returns.
        unawaited(refreshBackground());
        final id = '${payload['tool_id']}';
        for (final it in items.reversed) {
          if (it.kind == 'tool' && it.toolId == id) {
            it.done = true;
            it.duration = (payload['duration_s'] as num?)?.toDouble();
            final s = '${payload['summary'] ?? ''}';
            if (s.isNotEmpty && it.detail.isEmpty) it.detail = s;
            if (it.argsText.isEmpty) it.argsText = _argsText(payload);
            final res = _resultText(payload);
            if (res.isNotEmpty) it.resultText = res;
            break;
          }
        }
      case 'status.update':
        statusText = '${payload['text'] ?? ''}';
      case 'session.info':
        _applyInfo(payload);
      case 'session.title':
        final t = '${payload['title'] ?? ''}';
        if (t.isNotEmpty) title = t;
      case 'session.taken_over':
        // Another surface pulled this session: any turn here was interrupted and the
        // slot is no longer ours — a new send will offer to pull it back.
        if (storedId != null && '${payload['session_id'] ?? ''}' == storedId) {
          _closeThinking();
          running = false;
          statusText = '';
          items.add(ChatItem.notice(
              L10n.t(
                  'سُحبت هذه الجلسة إلى {0}؛ لإكمال العمل من الجوال اسحبها من جديد عند الإرسال.',
                  [_surfaceAr('${payload['by'] ?? ''}')])));
        } else {
          return;
        }
      case 'error':
        _closeThinking();
        running = false;
        _turnEndedAt = clock();
        _drainQueue();
        final msg = '${payload['message'] ?? L10n.t('خطأ')}';
        items.add(ChatItem.notice(msg));
        H.error();
        Notify.i.done(title: title.isEmpty ? L10n.t('جلسة') : title, body: msg, session: storedId, failed: true);
      default:
        return;
    }
    notifyListeners();
  }

  void _closeThinking() {
    for (final it in items.reversed) {
      if (it.kind == 'thinking' && !it.done) {
        it.done = true;
        it.seconds = DateTime.now().difference(it.started).inSeconds;
      }
    }
  }

  /// A prompt the UI asked to place in the composer (suggestion chips). The
  /// composer consumes it once; nothing is sent until the user presses send.
  String? draftRequest;

  void requestDraft(String text) {
    draftRequest = text;
    notifyListeners();
  }

  String? takeDraft() {
    final d = draftRequest;
    draftRequest = null;
    return d;
  }

  Timer? _sessTimer;
  void _debounceSessions() {
    _sessTimer?.cancel();
    _sessTimer = Timer(const Duration(seconds: 2), refreshSessions);
  }

  @override
  void dispose() {
    _activeTimer?.cancel();
    _bgTimer?.cancel();
    _sessTimer?.cancel();
    for (final t in _linger.values) {
      t.cancel();
    }
    _linger.clear();
    _evSub.cancel();
    _rqSub.cancel();
    gw.removeListener(_onLink);
    super.dispose();
  }
}


const _imageHint = '[Examine the attached @image paths with vision_analyze using each path as image_url.]';
const _fileHint = '[Read the attached @file paths with read_file or the appropriate document tool.]';

String _quoteRef(String path) {
  if (!RegExp(r'''[\s\[\]`"']''').hasMatch(path)) return path;
  for (final quote in ['`', '"', "'"]) {
    if (!path.contains(quote)) return '$quote$path$quote';
  }
  throw L10n.t('اسم الملف يحتوي على علامات اقتباس غير مدعومة');
}

String _mimeOf(String ext) => switch (ext) {
      'pdf' => 'application/pdf',
      'txt' || 'md' || 'log' => 'text/plain',
      'csv' => 'text/csv',
      'json' => 'application/json',
      'docx' => 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'xlsx' => 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'pptx' => 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'zip' => 'application/zip',
      'mp3' => 'audio/mpeg',
      'm4a' => 'audio/mp4',
      'mp4' => 'video/mp4',
      _ => 'application/octet-stream',
    };


final _attachToken = RegExp(r'''@(?:image|file):(?:`([^`\n]+)`|"([^"\n]+)"|'([^'\n]+)'|(\S+))''');

/// `"look\n@image:/p/a.jpg"` -> `("look", ["/p/a.jpg"])`.
(String, List<String>) splitAttachments(String text) {
  final files = _attachToken.allMatches(text).map((m) => m[1] ?? m[2] ?? m[3] ?? m[4]!).toList();
  final body = text.replaceAll(_attachToken, '').replaceAll(_imageHint, '').replaceAll(_fileHint, '')
      .replaceAll(RegExp(r'\n{3,}'), '\n\n').trim();
  return (body, files);
}


/// A session's rendered chat kept across switches.
class _SessionView {
  _SessionView(this.sid, this.title, this.items, this.running, this.statusKey, this.statusArg, this.statusRaw);

  String get statusText => statusKey.isNotEmpty
      ? L10n.t(statusKey, statusArg.isEmpty ? null : <Object?>[statusArg])
      : statusRaw;

  void clearStatus() {
    statusKey = '';
    statusArg = '';
    statusRaw = '';
  }
  final String sid;
  final String title;
  final List<ChatItem> items;
  bool running;
  String statusKey;
  String statusArg;
  String statusRaw;
}

/// Chat items from `session.resume`'s server-projected `messages`.
/// `session.resume` 的 messages 与 REST 历史行共用这套解析：
/// 认 `text`/`content`，认 `tool_calls`（带 id）与配对的 `role=tool` 行（拿返回值）。
List<ChatItem> chatItemsFromResume(List? msgs) =>
    chatItemsFromRest((msgs ?? const []).whereType<Map>().map((e) => e.cast<String, dynamic>()).toList());

/// JSON 美化（工具入参/返回值都往里走）；解析失败就原样返回。
String prettyJson(Object? value) {
  if (value == null) return '';
  if (value is String) {
    final t = value.trim();
    if (t.isEmpty) return '';
    try {
      return const JsonEncoder.withIndent('  ').convert(jsonDecode(t));
    } catch (_) {
      return t;
    }
  }
  try {
    return const JsonEncoder.withIndent('  ').convert(value);
  } catch (_) {
    return '$value';
  }
}

/// ``tool.start`` / ``tool.complete`` 里能拿到的完整入参。
String _argsText(Map<String, dynamic> payload) {
  final raw = payload['args_text'];
  if (raw is String && raw.trim().isNotEmpty) return raw.trim();
  final args = payload['args'];
  if (args is Map && args.isNotEmpty) return prettyJson(args);
  if (args is String && args.trim().isNotEmpty) return prettyJson(args);
  return '';
}

/// ``tool.complete`` 里能拿到的返回值（result_text 优先，其次 result，再合并 inline_diff）。
String _resultText(Map<String, dynamic> payload) {
  final out = <String>[];
  final text = payload['result_text'];
  if (text is String && text.trim().isNotEmpty) {
    out.add(text.trim());
  } else if (payload['result'] != null) {
    final r = prettyJson(payload['result']);
    if (r.trim().isNotEmpty) out.add(r.trim());
  }
  final diff = payload['inline_diff'];
  if (diff is String && diff.trim().isNotEmpty) out.add(diff.trim());
  return out.join('\n\n');
}

/// 调试面板用的一行摘要：只留关键字段，敏感值打码，长度截断。
String _brief(Object? payload) {
  if (payload == null) return '';
  try {
    if (payload is Map) {
      final keep = <String>[];
      for (final entry in payload.entries.take(8)) {
        final k = '${entry.key}';
        final v = entry.value;
        if (v == null) continue;
        if (v is Map || v is List) {
          keep.add('$k=${_redactJson(v)}');
        } else {
          keep.add('$k=${_redact(k, '$v')}');
        }
      }
      return '{${keep.join(', ')}}';
    }
    return _redact('', '$payload');
  } catch (_) {
    return '<?>';
  }
}

String _redactJson(Object? value) {
  try {
    final text = jsonEncode(value);
    final masked = text.replaceAllMapped(
        RegExp(r'"(password|pass|secret|token|api_key|apikey|code|otp|cookie|credential)[^"]*"\s*:\s*"[^"]*"',
            caseSensitive: false),
        (m) => '${m[0]!.split(':').first}:"***"');
    return masked.length > 220 ? '${masked.substring(0, 220)}…' : masked;
  } catch (_) {
    return '<?>';
  }
}

String _redact(String key, String value) {
  final sensitive = RegExp(r'password|pass|secret|token|api_key|apikey|otp|cookie|credential',
      caseSensitive: false).hasMatch(key);
  final v = sensitive ? '***' : value;
  return v.length > 200 ? '${v.substring(0, 200)}…' : v;
}

String _contentText(Object? content) {
  if (content is String) return content;
  if (content is List) {
    return [
      for (final p in content)
        if (p is Map && p['type'] == 'text') '${p['text'] ?? ''}'
    ].join('\n');
  }
  return content == null ? '' : '$content';
}

const _skillPrefix = '[IMPORTANT: The user has invoked the ';

/// `/skill instruction` for a slash-skill-expanded user turn, as the user typed it.
String? _skillInvocation(String text) {
  if (!text.startsWith(_skillPrefix)) return null;
  final name = RegExp(r'"([^"]*)"').firstMatch(text.substring(_skillPrefix.length - 1))?.group(1)?.trim() ?? '';
  final label = name.startsWith('/') ? name : '/$name';
  String? instruction;
  if (text.contains(' skill bundle,')) {
    final i = text.indexOf('\nUser instruction: ');
    if (i >= 0) {
      final rest = text.substring(i + '\nUser instruction: '.length);
      final j = rest.indexOf('\n\n[Loaded as part of the ');
      instruction = (j >= 0 ? rest.substring(0, j) : rest).trim();
    }
  } else {
    const marker = 'The user has provided the following instruction alongside the skill invocation: ';
    final i = text.lastIndexOf(marker);
    if (i >= 0) {
      final rest = text.substring(i + marker.length);
      final j = rest.indexOf('\n\n[Runtime note:');
      instruction = (j >= 0 ? rest.substring(0, j) : rest).trim();
    }
  }
  if (name.isEmpty) return instruction;
  return (instruction == null || instruction.isEmpty) ? label : '$label $instruction';
}

String _steerText(String text) {
  final lines = text.split('\n').where((l) {
    final t = l.trim();
    return !(t.startsWith('[OUT-OF-BAND') || t.startsWith('[/OUT-OF-BAND'));
  });
  return lines.join('\n').trim();
}

String _toolPreview(Map args) {
  // clarify：把问题本身当摘要 —— 否则历史里只剩一个 "clarify"，用户看不到问的是什么。
  final qs = args['questions'];
  if (qs is List && qs.isNotEmpty && qs.first is Map) {
    final q = '${(qs.first as Map)['question'] ?? ''}'.trim();
    if (q.isNotEmpty) return q.length > 80 ? '${q.substring(0, 79)}…' : q;
  }
  final single = '${args['question'] ?? ''}'.trim();
  if (single.isNotEmpty && (args['choices'] != null || args['options'] != null)) {
    return single.length > 80 ? '${single.substring(0, 79)}…' : single;
  }
  for (final k in const ['command', 'path', 'file_path', 'query', 'url', 'pattern', 'goal', 'name', 'action', 'image_url', 'urls']) {
    final v = args[k];
    if (v == null) continue;
    final t = (v is List ? v.join(', ') : '$v').split('\n').first.trim();
    if (t.isNotEmpty) return t.length > 80 ? '${t.substring(0, 79)}…' : t;
  }
  final code = args['code'];
  if (code is String && code.trim().isNotEmpty) {
    final t = code.trim().split('\n').first;
    return t.length > 80 ? '${t.substring(0, 79)}…' : t;
  }
  return '';
}

/// Chat items from the REST transcript page (`/api/sessions/{id}/messages`):
/// raw stored rows, filtered the way the server's resume projection does.
List<ChatItem> chatItemsFromRest(List<Map<String, dynamic>> rows) {
  final out = <ChatItem>[];
  final calls = <String, (String, Map)>{};
  for (final m in rows) {
    final role = '${m['role'] ?? ''}';
    final kind = m['display_kind'] as String?;
    if (kind == 'hidden' || kind == 'model_switch' || kind == 'auto_continue') continue;
    if (m['display_content'] != null) continue; // compaction summary
    final text = _contentText(m['content'] ?? m['text']);
    if (role == 'user') {
      if (kind == 'process_complete' || kind == 'async_delegation_complete') {
        final meta = m['display_metadata'];
        final shown = meta is Map ? '${meta['display_text'] ?? ''}'.split('\n').first.trim() : '';
        if (shown.isNotEmpty) out.add(ChatItem.notice(shown));
        continue;
      }
      if (text.trimLeft().startsWith('[System:') || text.trimLeft().startsWith('[System note:')) continue;
      final shown = kind == 'steer' ? _steerText(text) : (_skillInvocation(text) ?? text);
      final (body, files) = splitAttachments(shown);
      out.add(ChatItem.user(body)..files = files);
    } else if (role == 'assistant') {
      for (final tc in (m['tool_calls'] as List? ?? const [])) {
        if (tc is! Map) continue;
        final fn = tc['function'];
        final id = '${tc['id'] ?? ''}';
        if (fn is! Map || id.isEmpty) continue;
        Map args = const {};
        try {
          final a = fn['arguments'];
          args = a is Map ? a : (jsonDecode('${a ?? '{}'}') as Map? ?? const {});
        } catch (_) {}
        calls[id] = ('${fn['name'] ?? 'tool'}', args);
      }
      if (kind == 'failed_turn') {
        if (text.trim().isNotEmpty) out.add(ChatItem.notice(text.trim()));
        continue;
      }
      if (text.trim().isNotEmpty) out.add(ChatItem.assistant(text));
    } else if (role == 'tool') {
      final call = calls['${m['tool_call_id'] ?? ''}'];
      final name = call?.$1 ?? '${m['tool_name'] ?? m['name'] ?? 'tool'}';
      // 入参优先取 assistant.tool_calls 里的完整 arguments；单行也能靠行内的 args 自洽。
      final args = call?.$2 ??
          (m['args'] is Map ? (m['args'] as Map) : const <String, dynamic>{});
      final argsText = '${m['args_text'] ?? ''}'.trim();
      // content 就是工具返回值原文（旧版本直接丢掉了，只留一行入参摘要）。
      out.add(ChatItem.tool(
        name,
        detail: args.isEmpty ? '${m['context'] ?? ''}' : _toolPreview(args),
        argsText: argsText.isNotEmpty ? argsText : (args.isEmpty ? '' : prettyJson(args)),
        resultText: _contentText(m['content'] ?? m['result_text'] ?? m['result'] ?? m['output']).trim(),
      ));
    }
  }
  return out;
}

/// The in-flight turn from `session.resume` (`inflight`): the prompt that
/// started it and the reply streamed so far, so live deltas continue it.
void appendInflight(List<ChatItem> items, Object? inflight) {
  if (inflight is! Map) return;
  final user = '${inflight['user'] ?? ''}'.trim();
  if (user.isNotEmpty) {
    final lastUser = items.lastWhere((i) => i.kind == 'user', orElse: () => ChatItem.notice(''));
    final (body, _) = splitAttachments(_skillInvocation(user) ?? user);
    if (lastUser.text.trim() != body.trim()) {
      final (b, files) = splitAttachments(_skillInvocation(user) ?? user);
      items.add(ChatItem.user(b)..files = files);
    }
  }
  final assistant = '${inflight['assistant'] ?? ''}';
  if (assistant.trim().isNotEmpty) {
    // 别跟已有的最后一条助手气泡重复（重连/恢复时服务端的 inflight 尾巴
    // 常常就是刚落盘的那一段 —— 旧实现无条件新增，于是同一段话出现两遍）。
    final lastAssistant = items.lastWhere((i) => i.kind == 'assistant', orElse: () => ChatItem.notice(''));
    if (lastAssistant.text.trim() != assistant.trim()) {
      items.add(ChatItem.assistant(assistant));
    }
  }
}


/// transcript 行里最后一条 user 消息的文本（没有则 null）。纯函数，便于单测。
String? lastUserText(List<Map<String, dynamic>> rows) {
  for (final row in rows.reversed) {
    if ('${row['role']}' != 'user') continue;
    final content = row['content'];
    final text = content is String
        ? content
        : content is List
            ? content
                .map((part) => part is Map
                    ? '${part['text'] ?? ''}'
                    : part is String
                        ? part
                        : '')
                .join()
            : '${row['text'] ?? ''}';
    final trimmed = text.trim();
    if (trimmed.isNotEmpty) return trimmed;
  }
  return null;
}

/// 这条 user 消息是否还需要补进本地列表（已有同文本就不补）。
bool needsForeignUser(List<ChatItem> items, String text) {
  final want = text.trim();
  if (want.isEmpty) return false;
  return !items.any((it) => it.kind == 'user' && it.text.trim() == want);
}
