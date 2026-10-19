import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// 聊天图片的磁盘缓存。
///
/// 一张手机照片原图 3 MB，聊天里只需要 720px 的缩略图（约 20–60 KB）；而且卡片随列表
/// 滚出屏幕会被回收，重建时如果不缓存就会**再次下载**。这里按 `path|宽度` 落盘，
/// 重新进入列表是零网络请求。原图不进缓存（点开时才拉，直接交给系统查看器）。
class ImageDiskCache {
  ImageDiskCache._();

  static Directory? _dir;
  static final Map<String, Uint8List> _mem = <String, Uint8List>{};
  static const int _memLimit = 24; // 约 1–2 MB

  static String keyFor(String path, int width) =>
      base64Url.encode(utf8.encode('$path|$width')).replaceAll('=', '');

  static Future<Directory> _ensure() async {
    if (_dir != null && _dir!.existsSync()) return _dir!;
    final base = await getApplicationSupportDirectory();
    final d = Directory('${base.path}/media_cache');
    if (!d.existsSync()) d.createSync(recursive: true);
    _dir = d;
    return d;
  }

  static Future<Uint8List?> read(String key) async {
    final mem = _mem[key];
    if (mem != null) return mem;
    try {
      final f = File('${(await _ensure()).path}/$key.bin');
      if (!f.existsSync()) return null;
      final b = await f.readAsBytes();
      if (b.isEmpty) return null;
      _remember(key, b);
      return b;
    } catch (_) {
      return null;
    }
  }

  static Future<void> write(String key, Uint8List bytes) async {
    _remember(key, bytes);
    try {
      final f = File('${(await _ensure()).path}/$key.bin');
      await f.writeAsBytes(bytes, flush: false);
    } catch (_) {
      // 缓存写失败不影响显示
    }
  }

  static void _remember(String key, Uint8List bytes) {
    _mem[key] = bytes;
    while (_mem.length > _memLimit) {
      _mem.remove(_mem.keys.first);
    }
  }

  @visibleForTesting
  static void clearMemory() => _mem.clear();
}
