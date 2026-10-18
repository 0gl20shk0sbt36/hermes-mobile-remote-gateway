import 'package:flutter/services.dart';

import 'l10n.dart';

/// The native service keeps this Flutter process alive while the UI is hidden.
/// No second socket or credentials are created in Android.
class BackgroundConnection {
  static const _channel = MethodChannel('hermes/background');
  bool _started = false;
  String? _status;
  String? lastError;
  Future<bool>? _starting;
  void Function()? onNetworkAvailable;

  void listen() {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'networkAvailable') onNetworkAvailable?.call();
      if (call.method == 'stopped') _started = false;
    });
  }

  Future<bool> start() {
    if (_started) return Future.value(true);
    return _starting ??= _start().whenComplete(() => _starting = null);
  }

  Future<bool> _start() async {
    try {
      // 常驻通知的文案由 Dart 按当前语言传下去：Kotlin 那边原来是硬编码阿拉伯语，
      // 中文界面里通知标题就变成「Hermes + 一串阿拉伯字母」。
      await _channel.invokeMethod<void>('start', <String, String>{
        'title': L10n.t('Hermes يعمل في الخلفية'),
        'channelName': L10n.t('اتصال Hermes في الخلفية'),
        'channelDesc': L10n.t('يحافظ على اتصال المحادثة أثناء استخدام تطبيقات أخرى'),
        'action': L10n.t('إيقاف الخلفية'),
        'status': L10n.t('جارٍ الاتصال بالخادم...'),
        'connected': L10n.t('متصل'),
      });
      _started = true;
      lastError = null;
      return true;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
      return false;
    } on MissingPluginException {
      return false;
    }
  }

  Future<void> update(String status) async {
    if (!_started || status == _status) return;
    try {
      await _channel.invokeMethod<void>('update', {'status': status});
      _status = status;
    } on PlatformException catch (e) {
      lastError = e.message ?? e.code;
    }
  }

  Future<void> stop() async {
    _started = false;
    _status = null;
    try {
      await _channel.invokeMethod<void>('stop');
    } on MissingPluginException {
      // Unit/widget tests and non-Android platforms have no native service.
    }
  }

  Future<Map<String, dynamic>> status() async {
    final result = await _channel.invokeMapMethod<String, dynamic>('status');
    return result ?? {};
  }

  Future<void> openBatterySettings() => _channel.invokeMethod<void>('batterySettings');

  void dispose() {
    onNetworkAvailable = null;
    _channel.setMethodCallHandler(null);
  }
}
