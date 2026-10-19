import 'dart:convert';

import 'package:flutter/foundation.dart' show kDebugMode;


/// 调试追踪（`--dart-define=HERMES_TRACE=true` 才生效，正式包零开销）。
///
/// 输出走 `print`（→ `adb logcat` 里是 `I/flutter: HTRACE {...}`；debugPrint 会被节流丢行，必须用 print），
/// 方便 `adb logcat | grep HTRACE` 后用脚本解析。字段名固定，见各调用点。
const bool kTrace = kDebugMode || bool.fromEnvironment('HERMES_TRACE');

/// 记录一条追踪。
void htrace(String kind, [Map<String, Object?> data = const {}]) {
  if (!kTrace) return;
  // ignore: avoid_print
  print('HTRACE ${jsonEncode({'k': kind, 'ms': DateTime.now().millisecondsSinceEpoch, ...data})}');
}

/// 断点：命中时大声打一条（日志里可 grep HBREAK 定位关键时序）。
void hbreak(String name, [Map<String, Object?> data = const {}]) {
  if (!kTrace) return;
  // ignore: avoid_print
  print('HBREAK ${jsonEncode({'b': name, 'ms': DateTime.now().millisecondsSinceEpoch, ...data})}');
}
