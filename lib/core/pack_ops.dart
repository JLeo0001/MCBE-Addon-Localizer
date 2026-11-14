import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'types.dart';
import 'lang_files.dart';
import 'languages.dart';
import 'manifest.dart';

/// JSON / JS normalization pass run when a pack is opened.
class FormatService {
  static const Set<String> skipNames = {'_backup', '.git', 'node_modules', '__pycache__'};

  static (List<String>, List<String>) collectTargets(String root) {
    final jsons = <String>[];
    final js = <String>[];
    for (final file in Fsx.walkFiles(root)) {
      final name = p.basename(file.path).toLowerCase();
      if (name.endsWith('.backup') || name.endsWith('.bak')) continue;
      if (name.endsWith('.json')) jsons.add(file.path);
      if (name.endsWith('.js')) js.add(file.path);
    }
    return (jsons, js);
  }

  /// Returns (ok, failed, skipped).
  static (int, int, int) formatJsonFiles(
    List<String> files, {
    LogFn? log,
    void Function(int done, int total, String path)? onProgress,
  }) {
    var ok = 0, fail = 0, skip = 0;
    for (var i = 0; i < files.length; i++) {
      final path = files[i];
      onProgress?.call(i, files.length, path);
      try {
        final name = p.basename(path).toLowerCase();
        if (name.endsWith('.backup') || name.endsWith('.bak')) {
          skip++;
          continue;
        }
        final text = Fsx.readText(path);
        if (text.trim().isEmpty) {
          skip++;
          continue;
        }
        final trimmed = text.trimLeft();
        if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) {
          skip++;
          continue;
        }

        final data = Fsx.loadsJsonc(text);
        if (data is! Map && data is! List) {
          fail++;
          continue;
        }
        final pretty = '${const JsonEncoderBridge().pretty(data)}\n';
        if (pretty == text) {
          ok++;
          continue;
        }
        File(path).writeAsStringSync(pretty, flush: true);
        ok++;
      } catch (e) {
        fail++;
        log?.call('  ✗ 格式化失败 ${p.basename(path)}: $e');
      }
      onProgress?.call(i + 1, files.length, path);
    }
    return (ok, fail, skip);
  }

  /// Light JS cleanup: trailing whitespace, CRLF normalization, EOF newline.
  static (int, int, int) formatJsFiles(
    List<String> files, {
    LogFn? log,
    void Function(int done, int total, String path)? onProgress,
  }) {
    var ok = 0, fail = 0;
    for (var i = 0; i < files.length; i++) {
      final path = files[i];
      onProgress?.call(i, files.length, path);
      try {
        final text = Fsx.readText(path);
        var out = text.replaceAll('\r\n', '\n');
        final lines = out.split('\n').map((l) => l.replaceAll(RegExp(r'[ \t]+$'), '')).toList();
        out = lines.join('\n');
        if (!out.endsWith('\n')) out += '\n';
        if (out != text) File(path).writeAsStringSync(out, flush: true);
        ok++;
      } catch (e) {
        fail++;
        log?.call('  ✗ JS 规范化失败 ${p.basename(path)}: $e');
      }
      onProgress?.call(i + 1, files.length, path);
    }
    return (ok, fail, 0);
  }
}

/// Small bridge to avoid importing dart:convert everywhere.
class JsonEncoderBridge {
  const JsonEncoderBridge();
  String pretty(Object? data) => const _PrettyJson().convert(data);
}

class _PrettyJson {
  const _PrettyJson();
  String convert(Object? data) => _encode(data, 0);

  String _encode(Object? v, int depth) {
    final pad = '    ' * depth;
    final pad2 = '    ' * (depth + 1);
    if (v is Map) {
      if (v.isEmpty) return '{}';
      final parts = v.entries.map((e) => '$pad2${_str('${e.key}')}: ${_encode(e.value, depth + 1)}');
      return '{\n${parts.join(',\n')}\n$pad}';
    }
    if (v is List) {
      if (v.isEmpty) return '[]';
      final parts = v.map((e) => '$pad2${_encode(e, depth + 1)}');
      return '[\n${parts.join(',\n')}\n$pad]';
    }
    if (v is String) return _str(v);
    if (v == null) return 'null';
    return '$v';
  }

  String _str(String s) {
    final b = StringBuffer('"');
    for (final r in s.runes) {
      switch (r) {
        case 0x22:
          b.write(r'\"');
        case 0x5C:
          b.write(r'\\');
        case 0x0A:
          b.write(r'\n');
        case 0x0D:
          b.write(r'\r');
        case 0x09:
          b.write(r'\t');
        default:
          if (r < 0x20) {
            b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
          } else {
            b.writeCharCode(r);
          }
      }
    }
    b.write('"');
    return b.toString();
  }
}

/// Applies the translator credit to `pack.name` and the manifest header.
class CreditService {
  static bool applyToPack(String packDir, String credit, String code, LogFn log) {
    var changed = false;
    final texts = p.join(packDir, 'texts');
    final langPath = p.join(texts, '$code.lang');
    final enPath = p.join(texts, 'en_US.lang');
    final enMap = LangFiles.readMap(enPath);
    if (File(langPath).existsSync()) {
      final map = LangFiles.readMap(langPath);
      final current = map['pack.name'];
      if (current == null || current.trim().isEmpty) {
        final fallback = enMap['pack.name'];
        if (fallback != null && fallback.trim().isNotEmpty) {
          LangFiles.upsert(langPath, <String, String>{'pack.name': fallback});
        }
      }
      final base = LangFiles.readMap(langPath)['pack.name'] ?? 'pack';
      final next = withCredit(base, credit, code);
      if (next != base) {
        _rewriteLangKey(langPath, 'pack.name', next);
        changed = true;
      }
    }
    final data = ManifestService.read(packDir);
    final header = data?['header'];
    if (header is Map && data != null) {
      final name = header['name'];
      if (name is String && name != 'pack.name' && name.trim().isNotEmpty) {
        final next = withCredit(name, credit, code);
        if (next != name) {
          header['name'] = next;
          Fsx.writeJson(p.join(packDir, 'manifest.json'), data);
          changed = true;
        }
      }
    }
    if (changed) log('  ✓ 已应用署名 ${creditSuffix(code, credit)}');
    LicenseService.write(packDir, credit, code, log);
    return changed;
  }

  static void _rewriteLangKey(String path, String key, String value) {
    final text = Fsx.readText(path);
    final lines = text.split('\n');
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].startsWith('$key=')) {
        lines[i] = '$key=${LangFiles.sanitizeValue(value)}';
      }
    }
    File(path).writeAsStringSync(lines.join('\n'), flush: true);
  }
}

/// Writes the localization license note into a pack.
class LicenseService {
  static const String fileName = '本地化协议_LOCALIZATION_LICENSE.txt';

  static String build(String credit, String code) {
    final lang = labelOf(code);
    return '''
本地化协'/ Localization Notice
================================

本地化'/ Localizer: $credit
目标语言 / Target language: $lang ($code)
工具 / Tool: $toolNameHan ($toolNameLatin)

1. 本包为非官方本地化版本，不含任何付费内容，禁止用于任何形式的付费转售'   This is an unofficial localization. It must not be sold or resold for profit.

2. 原模组著作权归原作者所有；本文件不改变原模组的授权条款'   The original addon remains the property of its author; this notice does not
   alter the original license.

3. 再分发时必须保留本文件、包名中的本地化者署名以及图片中的水印'   Redistribution must keep this file, the pack-name credit and the image
   watermark intact.

4. 使用本工具即表示你已知悉：本地化结果由机器翻译生成，可能存在误差'   Translations are machine-generated and may contain errors.
''';
  }

  static void write(String packDir, String credit, String code, LogFn log) {
    final file = File(p.join(packDir, fileName));
    final text = build(credit, code);
    if (file.existsSync() && file.readAsStringSync() == text) return;
    file.writeAsStringSync(text, flush: true);
    log('  已写入本地化协议');
  }
}

