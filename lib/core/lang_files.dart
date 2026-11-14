import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'types.dart';
import 'languages.dart';

enum LangLineKind { empty, comment, entry }

class LangLine {
  LangLine(this.kind, {this.key, this.value, this.raw = ''});
  final LangLineKind kind;
  final String? key;
  final String? value;
  final String raw;
}

/// `.lang` read / write helpers, mirroring MCBE's grammar.
class LangFiles {
  static List<LangLine> parse(String content) {
    final lines = content.split('\n');
    final out = <LangLine>[];
    for (var raw in lines) {
      if (raw.endsWith('\r')) raw = raw.substring(0, raw.length - 1);
      if (raw.trim().isEmpty) {
        out.add(LangLine(LangLineKind.empty, raw: raw));
      } else if (raw.startsWith('##')) {
        out.add(LangLine(LangLineKind.comment, raw: raw));
      } else if (raw.contains('=')) {
        final idx = raw.indexOf('=');
        out.add(LangLine(
          LangLineKind.entry,
          key: raw.substring(0, idx).trim(),
          value: raw.substring(idx + 1),
          raw: raw,
        ));
      } else {
        out.add(LangLine(LangLineKind.comment, raw: raw));
      }
    }
    return out;
  }

  static Map<String, String> readMap(String path) {
    final file = File(path);
    if (!file.existsSync()) return <String, String>{};
    final map = <String, String>{};
    for (final line in parse(Fsx.readText(file.path))) {
      if (line.kind != LangLineKind.entry) continue;
      final key = line.key;
      if (key == null || map.containsKey(key)) continue;
      map[key] = line.value ?? '';
    }
    return map;
  }

  static String sanitizeValue(String value) =>
      value.replaceAll('\r\n', r'\n').replaceAll('\n', r'\n').replaceAll('\r', r'\n');

  /// Appends only the keys that are not present yet; returns how many.
  static int upsert(String path, Map<String, String> entries) {
    if (entries.isEmpty) return 0;
    final file = File(path);
    final exists = file.existsSync();
    final existing = exists ? readMap(path) : <String, String>{};
    final missing = <String, String>{};
    for (final e in entries.entries) {
      if (existing.containsKey(e.key)) continue;
      missing[e.key] = e.value;
    }
    if (missing.isEmpty) return 0;
    final buf = StringBuffer();
    if (!exists || file.lengthSync() == 0) {
      // new file: no leading newline
    } else {
      final text = Fsx.readText(path);
      if (!text.endsWith('\n')) buf.write('\n');
    }
    for (final e in missing.entries) {
      buf.writeln('${e.key}=${sanitizeValue(e.value)}');
    }
    if (exists) {
      file.writeAsStringSync(buf.toString(), mode: FileMode.append, flush: true);
    } else {
      Fsx.ensureDir(p.dirname(path));
      file.writeAsStringSync(buf.toString(), flush: true);
    }
    return missing.length;
  }

  /// Replaces values of known keys, preserving comments and ordering.
  ///
  /// `parse` splits on `\n` and stores each line without its terminator, so the
  /// newline has to be put back here — otherwise the whole file collapses onto
  /// a single line after a translation pass.
  static String rebuild(String original, List<LangLine> parsed, Map<String, String> translated) {
    final buf = StringBuffer();
    for (var i = 0; i < parsed.length; i++) {
      final line = parsed[i];
      var text = line.raw;
      if (line.kind == LangLineKind.entry) {
        final key = line.key;
        final next = key == null ? null : translated[key];
        if (key != null && next != null && next.isNotEmpty && next != line.value) {
          text = '$key=${sanitizeValue(next)}';
        }
      }
      buf.write(text);
      if (i != parsed.length - 1) buf.write('\n');
    }
    var out = buf.toString();
    if (original.endsWith('\n') && !out.endsWith('\n')) out += '\n';
    return out;
  }

  static bool ensureLanguageInLanguages(String textsDir, String code) {
    final file = File(p.join(textsDir, 'languages.json'));
    List<String> codes;
    if (file.existsSync()) {
      final data = Fsx.readJsonFile(file.path);
      if (data is! List) return false;
      codes = data.map((e) => '$e').toList();
    } else {
      final langs = Directory(textsDir)
          .listSync()
          .whereType<File>()
          .map((f) => p.basenameWithoutExtension(f.path))
          .where((s) => s.isNotEmpty)
          .toList()
        ..sort();
      codes = langs.isEmpty ? <String>['en_US'] : langs;
    }
    if (codes.contains(code)) return false;
    codes.add(code);
    Fsx.writeText(file.path, const JsonEncoder.withIndent('  ').convert(codes));
    return true;
  }

  static String? findBaseLang(String textsDir, String targetCode) {
    final en = File(p.join(textsDir, 'en_US.lang'));
    if (en.existsSync()) return en.path;
    final candidates = Directory(textsDir)
        .listSync()
        .whereType<File>()
        .where((f) => f.path.toLowerCase().endsWith('.lang'))
        .where((f) => p.basenameWithoutExtension(f.path) != targetCode)
        .toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    return candidates.isEmpty ? null : candidates.first.path;
  }

  /// Ensures `texts/` exists with `en_US.lang` plus the target language file.
  static String? ensureTextsDir(String packDir, String code, LogFn log) {
    final texts = p.join(packDir, 'texts');
    Fsx.ensureDir(texts);
    final en = File(p.join(texts, 'en_US.lang'));
    if (!en.existsSync()) {
      final base = findBaseLang(texts, code);
      if (base != null && p.basename(base) != 'en_US.lang') {
        File(base).copySync(en.path);
        log('  已用 ${p.basename(base)} 生成 en_US.lang');
      } else {
        en.writeAsStringSync('', flush: true);
      }
    }
    ensureLanguageInLanguages(texts, 'en_US');
    ensureLanguageInLanguages(texts, code);
    if (code == 'zh_CN') ensureLanguageInLanguages(texts, 'zh_CN');
    return texts;
  }

  /// Copies the best source language to `<code>.lang` when missing.
  static String? copyLangToTarget(String textsDir, String code, LogFn log) {
    final target = File(p.join(textsDir, '$code.lang'));
    final base = findBaseLang(textsDir, code);
    if (base == null) {
      log('  未找到可复制的源语言文件');
      return null;
    }
    if (target.existsSync()) return target.path;
    File(base).copySync(target.path);
    log('  已复制 ${p.basename(base)} → $code.lang');
    return target.path;
  }

  /// Rewrites a .lang file so every entry sits on its own line with LF
  /// endings and exactly one trailing newline. Returns true when it changed.
  static bool normalizeLayout(String path) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final original = Fsx.readText(path);
    final normalized = original.replaceAll('\r\n', '\n').replaceAll('\r', '\n');
    final parsed = parse(normalized);
    final buf = StringBuffer();
    for (final line in parsed) {
      switch (line.kind) {
        case LangLineKind.empty:
          buf.writeln();
        case LangLineKind.comment:
          buf.writeln(line.raw);
        case LangLineKind.entry:
          buf.writeln('${line.key}=${line.value}');
      }
    }
    var text = buf.toString().replaceFirst(RegExp(r'\n+$'), '\n');
    if (text.isEmpty) text = '\n';
    if (text == original) return false;
    file.writeAsStringSync(text, flush: true);
    return true;
  }
  static int syncMissingFromEnUs(String textsDir, String code, LogFn log) {
    final en = p.join(textsDir, 'en_US.lang');
    if (!File(en).existsSync()) return 0;
    final target = p.join(textsDir, '$code.lang');
    final enMap = readMap(en);
    final missing = <String, String>{};
    final targetMap = readMap(target);
    for (final e in enMap.entries) {
      if (!targetMap.containsKey(e.key)) missing[e.key] = e.value;
    }
    final added = upsert(target, missing);
    if (added > 0) log('  en_US 补齐 $added 个键');
    return added;
  }

  /// Heuristic: does this lang file still contain untranslated source text?
  static bool needsTranslation(String path, String code) {
    final file = File(path);
    if (!file.existsSync()) return false;
    final lang = languageOf(code);
    for (final line in parse(Fsx.readText(path))) {
      if (line.kind != LangLineKind.entry) continue;
      final value = line.value ?? '';
      if (lang.script == 'latin') {
        if (value.trim().isNotEmpty && RegExp(r'[A-Za-z]{3,}').hasMatch(value)) return true;
        continue;
      }
      if (Fsx.containsCjk(value) != (lang.script == 'han')) {
        if (value.trim().isNotEmpty) return true;
      }
    }
    return false;
  }
}

