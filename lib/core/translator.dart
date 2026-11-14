import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'llm.dart';
import 'types.dart';

/// On-disk memo of translations, keyed by `<language>\u0000<source text>`.
///
/// Duplicate strings inside a pack (and repeated runs over the same pack) cost
/// nothing after the first request.
class TranslationCache {
  TranslationCache._(this._file, this._map);

  final File _file;
  final Map<String, String> _map;
  bool _dirty = false;

  static TranslationCache? _instance;

  static Future<TranslationCache> load() async {
    final cached = _instance;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'translation_cache.json'));
    var map = <String, String>{};
    if (file.existsSync()) {
      try {
        final data = jsonDecode(file.readAsStringSync());
        if (data is Map) {
          data.forEach((k, v) {
            if (k is String && v is String) map[k] = v;
          });
        }
      } catch (_) {
        map = <String, String>{};
      }
    }
    return _instance = TranslationCache._(file, map);
  }

  static String _key(String lang, String text) => '$lang\u0000$text';

  String? lookup(String lang, String text) => _map[_key(lang, text)];

  void store(String lang, String source, String translated) {
    if (source.trim().isEmpty || translated.trim().isEmpty) return;
    _map[_key(lang, source)] = translated;
    _dirty = true;
  }

  /// Snapshot for the translation-memory screen.
  Map<String, String> get entries => Map<String, String>.unmodifiable(_map);

  int get length => _map.length;

  void removeKey(String key) {
    if (_map.remove(key) != null) _dirty = true;
  }

  void clearAll() {
    if (_map.isEmpty) return;
    _map.clear();
    _dirty = true;
  }

  /// Writes at most once per few seconds; called after each batch.
  Future<void> flush() async {
    if (!_dirty) return;
    _dirty = false;
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_map), flush: false);
    } catch (_) {
      // cache is best-effort
    }
  }
}

/// Deduplicating, chunked translator with retry and split-on-failure.
class BatchTranslator {
  BatchTranslator(this.client, this.cache);

  final LlmClient client;
  final TranslationCache cache;

  static const int chunkSize = 60;

  /// Translates [texts] and returns `source -> translated` for every input.
  Future<Map<String, String>> translate(
    List<String> texts,
    String langLabel, {
    String langCode = '',
    LogFn? log,
    void Function(int done, int total)? onProgress,
    bool Function()? cancelled,
    Map<String, String> glossary = const <String, String>{},
  }) async {
    final result = <String, String>{};
    final pending = <String>[];
    for (final text in texts.toSet()) {
      final fixed = glossary[text];
      if (fixed != null && fixed.trim().isNotEmpty) {
        result[text] = fixed;
        cache.store(langCode, text, fixed);
        continue;
      }
      final cached = cache.lookup(langCode, text);
      if (cached != null) {
        result[text] = cached;
      } else {
        pending.add(text);
      }
    }
    if (result.isNotEmpty) log?.call('  命中缓存 ${result.length} 条，待请求 ${pending.length} 条');
    if (pending.isEmpty) return result;

    var done = 0;
    for (var i = 0; i < pending.length; i += chunkSize) {
      if (cancelled?.call() ?? false) break;
      final chunk = pending.sublist(i, (i + chunkSize).clamp(0, pending.length));
      final translated = await _translateChunk(chunk, langLabel, langCode, log, cancelled, _hintFor(glossary));
      result.addAll(translated);
      done += chunk.length;
      log?.call('  已翻译 $done/${pending.length}');
      onProgress?.call(done, pending.length);
      await cache.flush();
    }
    return result;
  }

  String _hintFor(Map<String, String> glossary) {
    if (glossary.isEmpty) return '';
    final lines = glossary.entries.take(40).map((e) => '- ${e.key} => ${e.value}');
    return '术语表（必须原样使用这些译法）：\n${lines.join('\n')}';
  }

  Future<Map<String, String>> _translateChunk(
    List<String> chunk,
    String langLabel,
    String langCode,
    LogFn? log,
    bool Function()? cancelled,
    String hint,
  ) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      if (cancelled?.call() ?? false) return <String, String>{};
      try {
        final out = await client.translateImageTexts(chunk, langLabel, log: log, label: '语言翻译', hint: hint);
        final map = <String, String>{};
        for (var i = 0; i < chunk.length && i < out.length; i++) {
          final value = out[i].trim();
          if (value.isEmpty) continue;
          map[chunk[i]] = value;
          cache.store(langCode, chunk[i], value);
        }
        if (map.length == chunk.length) return map;
        // Partial answer: keep what we got, retry the rest.
        final missing = chunk.where((t) => !map.containsKey(t)).toList();
        if (missing.isEmpty) return map;
        if (attempt == 2) {
          if (missing.length == 1) return map;
          final half = missing.length ~/ 2;
          final a = await _translateChunk(missing.sublist(0, half), langLabel, langCode, log, cancelled, hint);
          final b = await _translateChunk(missing.sublist(half), langLabel, langCode, log, cancelled, hint);
          return <String, String>{...map, ...a, ...b};
        }
      } catch (e) {
        log?.call('  ✗ 批次失败（第 $attempt 次）：$e');
        await Future<void>.delayed(Duration(milliseconds: 400 * attempt));
        if (attempt == 2 && chunk.length > 1) {
          final half = chunk.length ~/ 2;
          final a = await _translateChunk(chunk.sublist(0, half), langLabel, langCode, log, cancelled, hint);
          final b = await _translateChunk(chunk.sublist(half), langLabel, langCode, log, cancelled, hint);
          return <String, String>{...a, ...b};
        }
      }
    }
    return <String, String>{};
  }
}
