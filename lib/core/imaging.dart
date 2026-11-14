import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;

import 'types.dart';
import 'llm.dart';
import 'models.dart';

/// OCR backends. The desktop build talks to a local/remote OCR service; a
/// `Null` engine simply reports that OCR is unavailable.
abstract class OcrEngine {
  Future<List<ImageRegion>> detect(Uint8List bytes, int width, int height);

  static OcrEngine fromEndpoint(String endpoint) {
    final url = endpoint.trim();
    return url.isEmpty ? const NullOcrEngine() : HttpOcrEngine(url);
  }
}

class NullOcrEngine implements OcrEngine {
  const NullOcrEngine();

  @override
  Future<List<ImageRegion>> detect(Uint8List bytes, int width, int height) async =>
      <ImageRegion>[];
}

/// Expects `{ "regions": [{ "box": [[x,y],...], "text": "...", "score": 0.9 }] }`
/// (RapidOCR / PaddleOCR style). Also accepts the flat `[x0,y0,x1,y1]` form.
class HttpOcrEngine implements OcrEngine {
  HttpOcrEngine(this.endpoint);

  final String endpoint;

  @override
  Future<List<ImageRegion>> detect(Uint8List bytes, int width, int height) async {
    final client = HttpClient()..connectionTimeout = const Duration(seconds: 30);
    try {
      final req = await client.postUrl(Uri.parse(endpoint));
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(<String, dynamic>{
        'image': base64Encode(bytes),
        'width': width,
        'height': height,
      }));
      final resp = await req.close().timeout(const Duration(seconds: 120));
      final body = await resp.transform(utf8.decoder).join();
      if (resp.statusCode >= 400) {
        throw HttpException('OCR HTTP ${resp.statusCode}');
      }
      final data = jsonDecode(body);
      final list = data is Map ? data['regions'] : data;
      final out = <ImageRegion>[];
      if (list is List) {
        for (final item in list) {
          final region = _parse(item);
          if (region != null) out.add(region);
        }
      }
      return out;
    } finally {
      client.close(force: true);
    }
  }

  ImageRegion? _parse(dynamic item) {
    if (item is! Map) return null;
    final text = '${item['text'] ?? item['txt'] ?? ''}';
    final score = (item['score'] as num?)?.toDouble() ?? 1.0;
    if (text.trim().isEmpty) return null;
    final box = item['box'] ?? item['bbox'];
    int l = 0, t = 0, r = 0, b = 0;
    if (box is List && box.length == 4 && box.first is num) {
      l = (box[0] as num).round();
      t = (box[1] as num).round();
      r = (box[2] as num).round();
      b = (box[3] as num).round();
    } else if (box is List && box.isNotEmpty) {
      var minX = double.infinity, minY = double.infinity;
      var maxX = 0.0, maxY = 0.0;
      for (final pt in box) {
        if (pt is List && pt.length >= 2) {
          final x = (pt[0] as num).toDouble();
          final y = (pt[1] as num).toDouble();
          if (x < minX) minX = x;
          if (y < minY) minY = y;
          if (x > maxX) maxX = x;
          if (y > maxY) maxY = y;
        }
      }
      l = minX.round();
      t = minY.round();
      r = maxX.round();
      b = maxY.round();
    } else {
      return null;
    }
    if (r - l < 6 || b - t < 6) return null;
    return ImageRegion(
      left: l,
      top: t,
      right: r,
      bottom: b,
      text: text,
      score: score,
    );
  }
}

/// OCR erase 'translate 'redraw pipeline.
class OcrLocalizer {
  static const int pad = 4;
  static const int textBatch = 50;

  /// Returns (ok, total).
  static Future<(int, int)> batch(
    List<String> images,
    LlmConfig textLlm, {
    required String langLabel,
    required OcrEngine engine,
    LogFn? log,
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
  }) async {
    var ok = 0;
    for (var i = 0; i < images.length; i++) {
      if (cancelled?.call() ?? false) break;
      if (await localizeOne(images[i], textLlm, langLabel: langLabel, engine: engine, log: log)) {
        ok++;
      }
      onProgress?.call(i + 1, images.length);
    }
    return (ok, images.length);
  }

  static Future<bool> localizeOne(
    String path,
    LlmConfig textLlm, {
    required String langLabel,
    required OcrEngine engine,
    LogFn? log,
  }) async {
    final file = File(path);
    if (!file.existsSync()) return false;
    final bytes = file.readAsBytesSync();
    final decoded = img.decodeImage(bytes);
    if (decoded == null) {
      log?.call('  无法解码 ${p.basename(path)}');
      return false;
    }
    final regions = await engine.detect(bytes, decoded.width, decoded.height);
    if (regions.isEmpty) {
      log?.call('  · ${p.basename(path)} 未识别到文字');
      return false;
    }
    regions.sort((a, b) => a.top == b.top ? a.left.compareTo(b.left) : a.top.compareTo(b.top));

    // Sample colours, then erase.
    for (final region in regions) {
      _sampleColors(decoded, region);
      _fill(decoded, region, region.bgColor);
    }

    // Translate.
    final texts = regions.map((r) => r.text).toList();
    final translated = await _translate(texts, textLlm, langLabel, log);
    for (var i = 0; i < regions.length && i < translated.length; i++) {
      regions[i].translation = translated[i];
    }

    // Redraw with Flutter's text engine so CJK renders with real fonts.
    final out = await _redraw(decoded, regions, watermark: true);
    if (out == null) return false;

    final backupDir = Directory(p.join(p.dirname(path), '_backup'));
    if (!backupDir.existsSync()) backupDir.createSync(recursive: true);
    final backup = p.join(backupDir.path, p.basename(path));
    if (!File(backup).existsSync()) file.copySync(backup);
    file.writeAsBytesSync(out, flush: true);
    log?.call('  ✓ ${p.basename(path)}（${regions.length} 段）');
    return true;
  }

  static Future<List<String>> _translate(
    List<String> texts,
    LlmConfig cfg,
    String langLabel,
    LogFn? log,
  ) async {
    if (texts.isEmpty || !cfg.configured) return texts;
    final client = LlmClient(cfg);
    final out = <String>[];
    for (var i = 0; i < texts.length; i += textBatch) {
      final chunk = texts.sublist(i, (i + textBatch).clamp(0, texts.length));
      try {
        out.addAll(await client.translateImageTexts(chunk, langLabel, log: log));
      } catch (e) {
        log?.call('  图片文本翻译失败: $e');
        out.addAll(chunk);
      }
    }
    return out;
  }

  static void _sampleColors(img.Image image, ImageRegion region) {
    // Ring band around the text box provides the background colour.
    final ring = <int, int>{};
    for (var y = region.top - pad; y <= region.bottom + pad; y++) {
      if (y < 0 || y >= image.height) continue;
      for (var x = region.left - pad; x <= region.right + pad; x++) {
        if (x < 0 || x >= image.width) continue;
        final inside = x >= region.left && x <= region.right && y >= region.top && y <= region.bottom;
        if (inside) continue;
        final px = image.getPixel(x, y);
        final bucket = (px.r.toInt() >> 4) << 8 | (px.g.toInt() >> 4) << 4 | (px.b.toInt() >> 4);
        ring[bucket] = (ring[bucket] ?? 0) + 1;
      }
    }
    if (ring.isNotEmpty) {
      final best = ring.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
      final r = ((best >> 8) & 0xF) * 16 + 8;
      final g = ((best >> 4) & 0xF) * 16 + 8;
      final b = (best & 0xF) * 16 + 8;
      region.bgColor = 0xFF000000 | (r << 16) | (g << 8) | b;
    }
    // Text colour = darkest pixel inside the box.
    var minLum = 999.0;
    var textColor = 0xFF000000;
    for (var y = region.top; y <= region.bottom && y < image.height; y++) {
      if (y < 0) continue;
      for (var x = region.left; x <= region.right && x < image.width; x++) {
        if (x < 0) continue;
        final px = image.getPixel(x, y);
        final lum = 0.299 * px.r + 0.587 * px.g + 0.114 * px.b;
        if (lum < minLum) {
          minLum = lum;
          textColor = (0xFF << 24) | (px.r.toInt() << 16) | (px.g.toInt() << 8) | px.b.toInt();
        }
      }
    }
    region.textColor = textColor;
  }

  static void _fill(img.Image image, ImageRegion region, int argb) {
    final color = img.ColorRgba8(
      (argb >> 16) & 0xFF,
      (argb >> 8) & 0xFF,
      argb & 0xFF,
      255,
    );
    img.fillRect(
      image,
      x1: (region.left - pad).clamp(0, image.width - 1),
      y1: (region.top - pad).clamp(0, image.height - 1),
      x2: (region.right + pad).clamp(0, image.width - 1),
      y2: (region.bottom + pad).clamp(0, image.height - 1),
      color: color,
    );
  }

  static Future<Uint8List?> _redraw(
    img.Image base,
    List<ImageRegion> regions, {
    required bool watermark,
  }) async {
    final ui.Image? uiImage = await _toUiImage(base);
    if (uiImage == null) return null;
    final recorder = ui.PictureRecorder();
    final canvas = ui.Canvas(recorder);
    canvas.drawImage(uiImage, ui.Offset.zero, ui.Paint());

    for (final region in regions) {
      final text = region.output;
      if (text.trim().isEmpty) continue;
      var fontSize = (region.height * 0.92).clamp(6.0, 200.0);
      ui.Paragraph? paragraph;
      while (fontSize >= 6) {
        paragraph = _paragraph(text, fontSize, region.textColor);
        if (paragraph.width <= region.width && paragraph.height <= region.height) break;
        fontSize -= 1;
      }
      paragraph ??= _paragraph(text, 6, region.textColor);
      final dx = region.left + (region.width - paragraph.width) / 2;
      final dy = region.top + (region.height - paragraph.height) / 2;
      canvas.drawParagraph(paragraph, ui.Offset(dx, dy));
    }

    if (watermark && base.width >= 64 && base.height >= 64) {
      final mark = _paragraph(
        '本地化 / Localized',
        (base.height * 0.035).clamp(8.0, 20.0),
        0xFFFFFFFF,
        stroke: true,
      );
      canvas.drawParagraph(
        mark,
        ui.Offset(
          base.width - mark.width - 6,
          base.height - mark.height - 6,
        ),
      );
    }

    final picture = recorder.endRecording();
    final outImage = await picture.toImage(base.width, base.height);
    final byteData = await outImage.toByteData(format: ui.ImageByteFormat.png);
    uiImage.dispose();
    outImage.dispose();
    return byteData?.buffer.asUint8List();
  }

  static ui.Paragraph _paragraph(String text, double fontSize, int argb, {bool stroke = false}) {
    final builder = ui.ParagraphBuilder(ui.ParagraphStyle(
      fontSize: fontSize,
      textAlign: ui.TextAlign.center,
      maxLines: 6,
    ));
    final color = ui.Color(argb);
    builder.pushStyle(ui.TextStyle(
      color: color,
      fontSize: fontSize,
      fontWeight: stroke ? ui.FontWeight.w600 : ui.FontWeight.normal,
      shadows: stroke
          ? const <ui.Shadow>[
              ui.Shadow(color: ui.Color(0xCC000000), blurRadius: 2),
            ]
          : null,
    ));
    builder.addText(text);
    final paragraph = builder.build();
    paragraph.layout(ui.ParagraphConstraints(width: 4096));
    return paragraph;
  }

  static Future<ui.Image?> _toUiImage(img.Image image) {
    final rgba = image.convert(numChannels: 4);
    final completer = Completer<ui.Image?>();
    ui.decodeImageFromPixels(
      rgba.getBytes(order: img.ChannelOrder.rgba),
      rgba.width,
      rgba.height,
      ui.PixelFormat.rgba8888,
      (image) => completer.complete(image),
    );
    return completer.future;
  }
}

/// Simple visible watermark for images translated by the vision model.
class Watermark {
  static Future<Uint8List?> stamp(Uint8List bytes) async {
    final decoded = img.decodeImage(bytes);
    if (decoded == null) return null;
    return OcrLocalizer._redraw(decoded, const <ImageRegion>[], watermark: true);
  }

  static void backup(String path) {
    final dir = Directory(p.join(p.dirname(path), '_backup'));
    if (!dir.existsSync()) dir.createSync(recursive: true);
    final backup = p.join(dir.path, p.basename(path));
    if (!File(backup).existsSync()) File(path).copySync(backup);
  }
}

/// Pixel dimensions of an encoded image, or null when it cannot be decoded.
(int, int)? decodeImageSizeSync(Uint8List bytes) {
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null;
  return (decoded.width, decoded.height);
}

Future<(int, int)?> decodeImageSize(Uint8List bytes) async =>
    decodeImageSizeSync(bytes);

