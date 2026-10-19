import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// 上传前把图片缩到最长边 [maxSide]、JPEG [quality]。
///
/// 手机照片动辄 3 MB，而模型侧只需要看清内容：1600 长边 + q85 通常约 200–400 KB，
/// 上行少一个数量级。解码失败返回 null，调用方按原图发送（绝不因为压缩失败挡住消息）。
/// 纯 Dart，跑在 `compute` 的独立 isolate 里。
Uint8List? shrinkImageForUpload(Uint8List src, {int maxSide = 1600, int quality = 85}) {
  final decoded = img.decodeImage(src);
  if (decoded == null) return null;
  var out = decoded;
  if (decoded.width > maxSide || decoded.height > maxSide) {
    out = decoded.width >= decoded.height
        ? img.copyResize(decoded, width: maxSide, interpolation: img.Interpolation.average)
        : img.copyResize(decoded, height: maxSide, interpolation: img.Interpolation.average);
  }
  return Uint8List.fromList(img.encodeJpg(out, quality: quality));
}
