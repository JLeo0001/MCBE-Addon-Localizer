import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Filesystem helpers, JSONC parsing and text heuristics shared by services.
class Fsx {
  static const Set<String> skipDirs = {'_backup', '.git', 'node_modules', '__pycache__'};

  static bool isSkippedPath(String path) {
    final norm = path.replaceAll('\\', '/');
    return norm.split('/').any(skipDirs.contains);
  }

  static Directory ensureDir(String path) {
    final d = Directory(path);
    if (!d.existsSync()) d.createSync(recursive: true);
    return d;
  }

  static List<File> walkFiles(String root, {bool Function(String path)? filter}) {
    final dir = Directory(root);
    if (!dir.existsSync()) return <File>[];
    final out = <File>[];
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (isSkippedPath(entity.path)) continue;
      if (filter != null && !filter(entity.path)) continue;
      out.add(entity);
    }
    return out;
  }

  static String readText(String path) {
    final bytes = File(path).readAsBytesSync();
    var text = utf8.decode(bytes, allowMalformed: true);
    if (text.startsWith('\uFEFF')) text = text.substring(1);
    return text;
  }

  static void writeText(String path, String text) {
    ensureDir(p.dirname(path));
    File(path).writeAsStringSync(text, flush: true);
  }

  /// Strips `//` and `/* */` comments while preserving string literals.
  static String stripJsonComments(String text) {
    final out = StringBuffer();
    var i = 0;
    final n = text.length;
    while (i < n) {
      final c = text[i];
      if (c == '"' || c == "'") {
        out.write(c);
        i++;
        while (i < n) {
          final d = text[i];
          out.write(d);
          i++;
          if (d == '\\' && i < n) {
            out.write(text[i]);
            i++;
          } else if (d == c) {
            break;
          }
        }
        continue;
      }
      if (c == '/' && i + 1 < n) {
        if (text[i + 1] == '/') {
          i += 2;
          while (i < n && text[i] != '\n' && text[i] != '\r') {
            i++;
          }
          continue;
        }
        if (text[i + 1] == '*') {
          i += 2;
          while (i + 1 < n && !(text[i] == '*' && text[i + 1] == '/')) {
            i++;
          }
          i = (i + 2 < n) ? i + 2 : n;
          continue;
        }
      }
      out.write(c);
      i++;
    }
    return out.toString();
  }

  static dynamic loadsJsonc(String text) {
    try {
      return jsonDecode(text);
    } catch (_) {
      return jsonDecode(stripJsonComments(text));
    }
  }

  static dynamic readJsonFile(String path) {
    try {
      return loadsJsonc(readText(path));
    } catch (_) {
      return null;
    }
  }

  /// Writes JSON with a backup of the previous file, atomically.
  static void writeJson(String path, Object? data, {bool backup = true}) {
    if (backup && File(path).existsSync()) {
      final dir = p.dirname(path);
      ensureDir(p.join(dir, '_backup'));
      File(path).copySync(p.join(dir, '_backup', p.basename(path)));
    }
    final text = const JsonEncoder.withIndent('    ').convert(data);
    writeText(path, '$text\n');
  }

  static String sanitizeName(String name, {int maxLen = 80, String fallback = 'unnamed'}) {
    var s = name.replaceAll(RegExp(r'搂.'), '');
    s = s.replaceAll(RegExp(r'[<>:"/\\|?*\x00-\x1f]'), '');
    s = s.replaceAll(RegExp(r'\s+'), ' ');
    s = s.trim().replaceAll(RegExp(r'^[ .]+|[ .]+$'), '');
    if (s.isEmpty) s = fallback;
    if (s.length > maxLen) s = s.substring(0, maxLen).trim();
    return s;
  }

  static String removeMcFormatting(String text) => text.replaceAll(RegExp(r'搂.'), '');

  static bool containsCjk(String text) =>
      text.runes.any((r) => r >= 0x4E00 && r <= 0x9FFF);

  static String basenameNoExt(String path) => p.basenameWithoutExtension(path);
}
