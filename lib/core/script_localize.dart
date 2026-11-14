import 'fsx.dart';
import 'types.dart';
import 'llm.dart';

/// A translatable string literal found in a script file.
class TipSpan {
  TipSpan(this.start, this.end, this.text, this.quote);
  final int start; // content start (exclusive of quote)
  final int end; // content end
  final String text;
  final String quote;
}

/// Extracts and replaces player-visible strings in Bedrock scripts.
class ScriptLocalizer {
  static const Set<String> extensions = {'.js', '.ts', '.mjs', '.cjs'};
  static const int batchSize = 30;

  static final RegExp tipMethod = RegExp(
    r'\.(?:sendMessage|setActionBar|setTitle|setSubtitle|title|button|label|body|toggle|slider|dropdown|textField|divider|header|submitButton)\s*\(',
  );
  static final RegExp tipProp = RegExp(r'\b(?:tooltip|placeholderText|placeholder)\s*:');
  static final RegExp rawText = RegExp(r'"text"\s*:');
  static final RegExp uiConstArray = RegExp(r'\bconst\s+([A-Z][A-Z0-9_]*)\s*=\s*\[');
  static final RegExp uiConstHint = RegExp(
    r'(CHANGELOG|TITLES?|MESSAGES?|TIPS?|HELP|DESCS?|LABELS?|TEXTS?|NEWS|HINTS?|ALERTS?|NOTIFY)',
    caseSensitive: false,
  );
  static final RegExp resourcePath = RegExp(
    r'^(?:textures|texture|sounds|models|particles|fonts|ui|entities|blocks?)/|/\S+\.(?:png|jpg|jpeg|tga|fsb|ogg|wav|mp3|json|lang)$',
    caseSensitive: false,
  );
  static const List<String> skipPrefixes = <String>[
    'textures/',
    'texture/',
    'http://',
    'https://',
    'minecraft:',
    'data:',
    '@minecraft/',
    './',
    '../',
  ];

  static List<String> scriptFiles(String root) => Fsx.walkFiles(root, filter: (path) {
    final lower = path.toLowerCase();
    return extensions.any(lower.endsWith);
  }).map((f) => f.path).toList();

  // ---------------------------------------------------------------- scanning

  static int _skipString(String src, int i) {
    final quote = src[i];
    i++;
    while (i < src.length) {
      final c = src[i];
      if (c == '\\') {
        i += 2;
        continue;
      }
      if (c == quote) return i + 1;
      if (quote == '`' && c == r'$' && i + 1 < src.length && src[i + 1] == '{') {
        i = _skipInterpolation(src, i + 2);
        continue;
      }
      i++;
    }
    return i;
  }

  static int _skipInterpolation(String src, int i) {
    var depth = 1;
    while (i < src.length) {
      final c = src[i];
      if (c == '"' || c == "'" || c == '`') {
        i = _skipString(src, i);
        continue;
      }
      if (c == '{') depth++;
      if (c == '}') {
        depth--;
        if (depth == 0) return i + 1;
      }
      i++;
    }
    return i;
  }

  static int _skipTrivia(String src, int i) {
    while (i < src.length) {
      final c = src[i];
      if (c == ' ' || c == '\t' || c == '\n' || c == '\r') {
        i++;
        continue;
      }
      if (c == '/' && i + 1 < src.length) {
        if (src[i + 1] == '/') {
          while (i < src.length && src[i] != '\n') {
            i++;
          }
          continue;
        }
        if (src[i + 1] == '*') {
          i += 2;
          while (i + 1 < src.length && !(src[i] == '*' && src[i + 1] == '/')) {
            i++;
          }
          i += 2;
          continue;
        }
      }
      break;
    }
    return i;
  }

  /// Collects argument-level string literals after `match`.
  static void _collectArgs(String src, int matchEnd, List<TipSpan> out) {
    var i = matchEnd;
    var paren = 1, bracket = 0, brace = 0;
    while (i < src.length && paren > 0) {
      final c = src[i];
      if (c == '"' || c == "'" || c == '`') {
        final end = _skipString(src, i);
        if (brace == 0 && paren == 1 && bracket <= 1) {
          final quote = c;
          final content = src.substring(i + 1, end - 1);
          if (!content.contains(quote) || quote == '`') {
            out.add(TipSpan(i + 1, end - 1, content, quote));
          }
        }
        i = end;
        continue;
      }
      if (c == '(') paren++;
      if (c == ')') paren--;
      if (c == '[') bracket++;
      if (c == ']') bracket--;
      if (c == '{') brace++;
      if (c == '}') brace--;
      i++;
    }
  }

  static bool isSafeTip(String raw) {
    var text = raw.replaceAll(RegExp(r'\\\r?\n'), '').trim();
    if (text.length < 2) return false;
    final lower = text.toLowerCase();
    for (final prefix in skipPrefixes) {
      if (lower.startsWith(prefix)) return false;
    }
    if (resourcePath.hasMatch(text)) return false;
    if (text.contains(r'${')) {
      final bodies = RegExp(r'\$\{([^}]*)\}').allMatches(text).map((m) => m.group(1)!.trim());
      for (final body in bodies) {
        if (!RegExp(r'^[A-Za-z_$][\w.$]*(\[\d+\])?$').hasMatch(body) &&
            !RegExp(r'^[A-Za-z_$][\w.$]*(\[\d+\])?\s*\([^()]*\)$').hasMatch(body)) {
          return false;
        }
      }
    }
    if (text.contains('`')) return false;
    if (Fsx.containsCjk(text)) return true;
    return RegExp(r'[A-Za-z]{3,}').hasMatch(text);
  }

  static List<TipSpan> extract(String src) {
    final spans = <TipSpan>[];
    for (final m in tipMethod.allMatches(src)) {
      _collectArgs(src, m.end, spans);
    }
    for (final m in tipProp.allMatches(src)) {
      var i = _skipTrivia(src, m.end);
      if (i < src.length && (src[i] == '"' || src[i] == "'" || src[i] == '`')) {
        final end = _skipString(src, i);
        spans.add(TipSpan(i + 1, end - 1, src.substring(i + 1, end - 1), src[i]));
      }
    }
    for (final m in rawText.allMatches(src)) {
      var i = _skipTrivia(src, m.end);
      if (i < src.length && (src[i] == '"' || src[i] == "'" || src[i] == '`')) {
        final end = _skipString(src, i);
        spans.add(TipSpan(i + 1, end - 1, src.substring(i + 1, end - 1), src[i]));
      }
    }
    for (final m in uiConstArray.allMatches(src)) {
      final name = m.group(1) ?? '';
      if (!uiConstHint.hasMatch(name)) continue;
      var i = m.end;
      var depth = 1;
      while (i < src.length && depth > 0) {
        final c = src[i];
        if (c == '"' || c == "'" || c == '`') {
          final end = _skipString(src, i);
          if (depth == 1) {
            spans.add(TipSpan(i + 1, end - 1, src.substring(i + 1, end - 1), c));
          }
          i = end;
          continue;
        }
        if (c == '[') depth++;
        if (c == ']') depth--;
        i++;
      }
    }

    final seen = <String>{};
    final filtered = <TipSpan>[];
    for (final span in spans) {
      final logical = span.text.replaceAll(RegExp(r'\\\r?\n'), ' ');
      if (!isSafeTip(span.text)) continue;
      final key = '${span.start}:${logical.trim()}';
      if (!seen.add(key)) continue;
      filtered.add(span);
    }
    filtered.sort((a, b) => a.start.compareTo(b.start));
    return filtered;
  }

  // ------------------------------------------------------------- translation

  static Future<Map<String, String>> translateStrings(
    List<String> strings,
    LlmConfig cfg, {
    required String langLabel,
    LogFn? log,
  }) async {
    if (strings.isEmpty) return <String, String>{};
    final client = LlmClient(cfg);
    final result = <String, String>{};
    for (var start = 0; start < strings.length; start += batchSize) {
      final chunk = strings.sublist(start, (start + batchSize).clamp(0, strings.length));
      final payload = <Map<String, String>>[
        for (var i = 0; i < chunk.length; i++)
          <String, String>{'id': 'S${(start + i).toString().padLeft(4, '0')}', 'text': chunk[i]},
      ];
      final prompt = '你是 Minecraft 基岩版脚本界面的本地化译者，JSON 里每个对象的 text 翻译langLabel'
          '只输出同结构的 JSON 数组，逐项保留 id；保留 § 颜色代码、%s/%d 占位符与 \${} 插值，不要解释。'
          '${const _JsonLike().encode(payload)}';
      try {
        final resp = await client.complete(
          <Map<String, dynamic>>[
            <String, dynamic>{'role': 'user', 'content': prompt},
          ],
          temperature: 0.2,
          log: log,
          label: '脚本翻译',
        );
        final text = LlmClient.contentOf(resp);
        final parsed = _parseArray(text);
        if (parsed != null) {
          for (final item in parsed) {
            if (item is! Map) continue;
            final id = '${item['id']}';
            final value = item['text'];
            if (value is String && value.trim().isNotEmpty) result[id] = value;
          }
        }
      } catch (e) {
        log?.call('  脚本批次翻译失败: $e');
      }
    }
    return result;
  }

  static List<dynamic>? _parseArray(String text) {
    final start = text.indexOf('[');
    final end = text.lastIndexOf(']');
    if (start < 0 || end <= start) return null;
    try {
      final decoded = const _JsonLike().decode(text.substring(start, end + 1));
      return decoded is List ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static String fitQuote(String text, String quote) {
    var out = text;
    if (quote == '`') {
      out = out.replaceAll('`', r'\`');
      return out;
    }
    out = out.replaceAll('\r\n', r'\n').replaceAll('\n', r'\n').replaceAll('\t', r'\t');
    if (quote == "'") out = out.replaceAll("'", r"\'");
    if (quote == '"') out = out.replaceAll('"', r'\"');
    return out;
  }

  static String applyReplacements(String src, List<TipSpan> spans, Map<String, String> mapping) {
    final ordered = List<TipSpan>.from(spans)..sort((a, b) => b.start.compareTo(a.start));
    var out = src;
    for (final span in ordered) {
      final key = span.text.replaceAll(RegExp(r'\\\r?\n'), ' ');
      final replacement = mapping[key] ?? mapping[span.text];
      if (replacement == null || replacement.trim().isEmpty) continue;
      out = out.replaceRange(span.start, span.end, fitQuote(replacement, span.quote));
    }
    return out;
  }

  static bool validate(String src) {
    var depth = 0;
    var i = 0;
    while (i < src.length) {
      final c = src[i];
      if (c == '"' || c == "'" || c == '`') {
        final end = _skipString(src, i);
        if (end <= i) return false;
        final body = src.substring(i + 1, end - 1);
        if (c != '`' && body.contains('\n')) return false;
        i = end;
        continue;
      }
      if (c == '(' || c == '[' || c == '{') depth++;
      if (c == ')' || c == ']' || c == '}') depth--;
      if (depth < 0) return false;
      i++;
    }
    return depth == 0;
  }

  /// Returns (files, hits, written, rolledBack).
  static Future<(int, int, int, int)> localize(
    String root,
    LlmConfig cfg, {
    required String langLabel,
    LogFn? log,
    bool Function()? cancelled,
  }) async {
    final files = scriptFiles(root);
    var hits = 0, written = 0, rolled = 0;
    for (final path in files) {
      if (cancelled?.call() ?? false) break;
      final src = Fsx.readText(path);
      final spans = extract(src);
      if (spans.isEmpty) continue;
      hits += spans.length;
      final unique = <String>{};
      for (final span in spans) {
        final key = span.text.replaceAll(RegExp(r'\\\r?\n'), ' ');
        if (Fsx.containsCjk(key) || RegExp(r'[A-Za-z]{3,}').hasMatch(key)) unique.add(key);
      }
      final mapping = await translateStrings(unique.toList(), cfg, langLabel: langLabel, log: log);
      if (mapping.isEmpty) continue;
      final next = applyReplacements(src, spans, mapping);
      if (next == src) continue;
      if (!validate(next)) {
        rolled++;
        log?.call('  ${path.split(RegExp(r"[\\/]")).last} 结构校验失败，已回退');
        continue;
      }
      Fsx.writeText(path, next);
      written++;
    }
    return (files.length, hits, written, rolled);
  }
}

/// Tiny JSON helper so this file does not depend on dart:convert naming.
class _JsonLike {
  const _JsonLike();
  String encode(Object? value) => _enc(value);

  String _enc(Object? v) {
    if (v == null) return 'null';
    if (v is String) {
      final b = StringBuffer('"');
      for (final r in v.runes) {
        if (r == 0x22) {
          b.write(r'\"');
        } else if (r == 0x5C) {
          b.write(r'\\');
        } else if (r == 0x0A) {
          b.write(r'\n');
        } else if (r == 0x0D) {
          b.write(r'\r');
        } else if (r == 0x09) {
          b.write(r'\t');
        } else if (r < 0x20) {
          b.write('\\u${r.toRadixString(16).padLeft(4, '0')}');
        } else {
          b.writeCharCode(r);
        }
      }
      return (b..write('"')).toString();
    }
    if (v is num || v is bool) return '$v';
    if (v is List) return '[${v.map(_enc).join(',')}]';
    if (v is Map) {
      return '{${v.entries.map((e) => '${_enc('${e.key}')}:${_enc(e.value)}').join(',')}}';
    }
    return _enc('$v');
  }

  dynamic decode(String text) => _JsonReader(text).read();
}

class _JsonReader {
  _JsonReader(this.s);
  final String s;
  int i = 0;

  dynamic read() {
    _ws();
    final v = _value();
    return v;
  }

  void _ws() {
    while (i < s.length && ' \t\r\n'.contains(s[i])) {
      i++;
    }
  }

  dynamic _value() {
    _ws();
    if (i >= s.length) throw const FormatException('eof');
    final c = s[i];
    if (c == '{') return _object();
    if (c == '[') return _array();
    if (c == '"') return _string();
    return _scalar();
  }

  Map<String, dynamic> _object() {
    final out = <String, dynamic>{};
    i++;
    while (true) {
      _ws();
      if (i >= s.length) throw const FormatException('eof');
      if (s[i] == '}') {
        i++;
        return out;
      }
      final key = _string();
      _ws();
      if (i >= s.length || s[i] != ':') throw const FormatException('expected :');
      i++;
      out[key] = _value();
      _ws();
      if (i < s.length && s[i] == ',') i++;
    }
  }

  List<dynamic> _array() {
    final out = <dynamic>[];
    i++;
    while (true) {
      _ws();
      if (i >= s.length) throw const FormatException('eof');
      if (s[i] == ']') {
        i++;
        return out;
      }
      out.add(_value());
      _ws();
      if (i < s.length && s[i] == ',') i++;
    }
  }

  String _string() {
    final b = StringBuffer();
    i++;
    while (i < s.length) {
      final c = s[i];
      if (c == '\\') {
        i++;
        if (i >= s.length) break;
        final e = s[i];
        switch (e) {
          case 'n':
            b.write('\n');
          case 'r':
            b.write('\r');
          case 't':
            b.write('\t');
          case '"':
            b.write('"');
          case '\\':
            b.write('\\');
          case '/':
            b.write('/');
          case 'b':
            b.write('\b');
          case 'f':
            b.write('\f');
          case 'u':
            final hex = s.substring(i + 1, (i + 5).clamp(0, s.length));
            b.writeCharCode(int.parse(hex, radix: 16));
            i += 4;
          default:
            b.write(e);
        }
        i++;
        continue;
      }
      if (c == '"') {
        i++;
        break;
      }
      b.write(c);
      i++;
    }
    return b.toString();
  }

  dynamic _scalar() {
    final start = i;
    while (i < s.length && !',]} \t\r\n'.contains(s[i])) {
      i++;
    }
    final token = s.substring(start, i);
    if (token == 'true') return true;
    if (token == 'false') return false;
    if (token == 'null') return null;
    return num.tryParse(token) ?? token;
  }
}

