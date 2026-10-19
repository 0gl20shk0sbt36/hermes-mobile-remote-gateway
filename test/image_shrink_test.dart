import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:hermes_mobile/image_shrink.dart';

Uint8List _jpeg(int w, int h, {int quality = 95}) {
  final im = img.Image(width: w, height: h);
  // 画点噪声，避免纯色图被压到 0 字节导致断言失真
  for (var y = 0; y < h; y += 4) {
    for (var x = 0; x < w; x += 4) {
      im.setPixelRgb(x, y, (x * 7) % 255, (y * 5) % 255, ((x + y) * 3) % 255);
    }
  }
  return Uint8List.fromList(img.encodeJpg(im, quality: quality));
}

void main() {
  test('大图被缩到最长边 1600', () {
    final src = _jpeg(2400, 1800);
    final out = shrinkImageForUpload(src)!;
    final decoded = img.decodeJpg(out)!;
    expect(decoded.width, 1600);
    expect(decoded.height, 1200);
    expect(out.length, lessThan(src.length));
  });

  test('竖图按高度缩', () {
    final out = shrinkImageForUpload(_jpeg(1200, 2400))!;
    final decoded = img.decodeJpg(out)!;
    expect(decoded.height, 1600);
    expect(decoded.width, 800);
  });

  test('小图不放大、只重编码', () {
    final out = shrinkImageForUpload(_jpeg(640, 480))!;
    final decoded = img.decodeJpg(out)!;
    expect(decoded.width, 640);
    expect(decoded.height, 480);
  });

  test('非图片返回 null（调用方按原图发送）', () {
    expect(shrinkImageForUpload(Uint8List.fromList([1, 2, 3, 4, 5])), isNull);
  });
}
