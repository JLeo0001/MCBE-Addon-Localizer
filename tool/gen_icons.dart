// Generates platform icon assets from a single square PNG.
// Usage: dart run tool/gen_icons.dart <source.png>
import 'dart:io';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

void main(List<String> args) {
  final source = File(args.isEmpty ? 'icon_source.png' : args.first);
  if (!source.existsSync()) {
    stderr.writeln('source icon not found: ${source.path}');
    exit(1);
  }
  final decoded = img.decodePng(source.readAsBytesSync());
  if (decoded == null) {
    stderr.writeln('source is not a readable PNG');
    exit(1);
  }
  final square = _square(decoded);

  const android = <String, int>{
    'android/app/src/main/res/mipmap-mdpi/ic_launcher.png': 48,
    'android/app/src/main/res/mipmap-hdpi/ic_launcher.png': 72,
    'android/app/src/main/res/mipmap-xhdpi/ic_launcher.png': 96,
    'android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png': 144,
    'android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png': 192,
  };
  for (final entry in android.entries) {
    final out = File(entry.key);
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(img.encodePng(img.copyResize(square, width: entry.value, height: entry.value)));
    stdout.writeln('wrote ${entry.key} (${entry.value}px)');
  }

  // Windows .ico with several sizes, each entry stored as PNG.
  const sizes = <int>[16, 24, 32, 48, 64, 128, 256];
  final payloads = <int, Uint8List>{};
  for (final size in sizes) {
    payloads[size] = Uint8List.fromList(
      img.encodePng(img.copyResize(square, width: size, height: size)),
    );
  }
  final ico = File('windows/runner/resources/app_icon.ico');
  ico.parent.createSync(recursive: true);
  ico.writeAsBytesSync(_buildIco(sizes, payloads));
  stdout.writeln('wrote ${ico.path} (${sizes.join(", ")}px)');
}

img.Image _square(img.Image image) {
  if (image.width == image.height) return image;
  final side = image.width < image.height ? image.width : image.height;
  final x = (image.width - side) ~/ 2;
  final y = (image.height - side) ~/ 2;
  return img.copyCrop(image, x: x, y: y, width: side, height: side);
}

Uint8List _buildIco(List<int> sizes, Map<int, Uint8List> payloads) {
  final header = ByteData(6);
  header.setUint16(0, 0, Endian.little); // reserved
  header.setUint16(2, 1, Endian.little); // type: icon
  header.setUint16(4, sizes.length, Endian.little);

  var offset = 6 + sizes.length * 16;
  final out = BytesBuilder();
  out.add(header.buffer.asUint8List());

  for (final size in sizes) {
    final data = payloads[size]!;
    final entry = ByteData(16);
    entry.setUint8(0, size >= 256 ? 0 : size);
    entry.setUint8(1, size >= 256 ? 0 : size);
    entry.setUint8(2, 0); // palette
    entry.setUint8(3, 0); // reserved
    entry.setUint16(4, 1, Endian.little); // planes
    entry.setUint16(6, 32, Endian.little); // bpp
    entry.setUint32(8, data.length, Endian.little);
    entry.setUint32(12, offset, Endian.little);
    out.add(entry.buffer.asUint8List());
    offset += data.length;
  }
  for (final size in sizes) {
    out.add(payloads[size]!);
  }
  return out.toBytes();
}
