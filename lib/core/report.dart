import 'dart:io';

import 'package:flutter/foundation.dart';

import 'lang_files.dart';

/// One "before → after" row produced by a translation pass.
class ReportEntry {
  ReportEntry({
    required this.file,
    required this.key,
    required this.before,
    required this.after,
  });

  final String file;
  final String key;
  final String before;
  String after;
}

/// Session-scoped record of what the last translation actually changed,
/// powering the diff screen.
class TranslationReport extends ChangeNotifier {
  TranslationReport._();

  static final TranslationReport instance = TranslationReport._();

  final List<ReportEntry> _entries = <ReportEntry>[];

  List<ReportEntry> get entries => List<ReportEntry>.unmodifiable(_entries);
  int get length => _entries.length;

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  /// Called after a file is rewritten; [parsed] gives the pre-translation text.
  void record(String file, List<LangLine> parsed, Map<String, String> mapping) {
    final before = <String, String>{};
    for (final line in parsed) {
      if (line.kind != LangLineKind.entry) continue;
      final key = line.key;
      if (key == null) continue;
      before.putIfAbsent(key, () => line.value ?? '');
    }
    for (final entry in mapping.entries) {
      final old = before[entry.key];
      if (old == null || old == entry.value) continue;
      _entries.removeWhere((e) => e.file == file && e.key == entry.key);
      _entries.add(ReportEntry(file: file, key: entry.key, before: old, after: entry.value));
    }
    notifyListeners();
  }

  /// Applies a hand-edited translation back into the file it came from.
  bool applyEdit(ReportEntry entry) {
    try {
      final file = File(entry.file);
      if (!file.existsSync()) return false;
      final raw = file.readAsStringSync();
      final parsed = LangFiles.parse(raw);
      final text = LangFiles.rebuild(raw, parsed, <String, String>{entry.key: entry.after});
      if (text == raw) return false;
      file.writeAsStringSync(text, flush: true);
      notifyListeners();
      return true;
    } catch (_) {
      return false;
    }
  }
}
