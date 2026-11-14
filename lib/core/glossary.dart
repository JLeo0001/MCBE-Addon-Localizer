import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// A fixed translation for one term, per language.
class GlossaryTerm {
  GlossaryTerm({required this.term, required this.translation, required this.lang});

  final String term;
  final String translation;
  final String lang;

  Map<String, dynamic> toJson() =>
      <String, dynamic>{'term': term, 'translation': translation, 'lang': lang};

  static GlossaryTerm fromJson(Map<String, dynamic> json) => GlossaryTerm(
        term: '${json['term'] ?? ''}',
        translation: '${json['translation'] ?? ''}',
        lang: '${json['lang'] ?? ''}',
      );
}

/// User-maintained terminology, honoured by the translator.
class Glossary {
  Glossary._(this._file, this._terms);

  final File _file;
  final List<GlossaryTerm> _terms;

  static Glossary? _instance;

  static Future<Glossary> load() async {
    final cached = _instance;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'glossary.json'));
    final terms = <GlossaryTerm>[];
    if (file.existsSync()) {
      try {
        final data = jsonDecode(file.readAsStringSync());
        if (data is List) {
          for (final row in data) {
            if (row is Map<String, dynamic>) terms.add(GlossaryTerm.fromJson(row));
          }
        }
      } catch (_) {
        terms.clear();
      }
    }
    return _instance = Glossary._(file, terms);
  }

  List<GlossaryTerm> get all => List<GlossaryTerm>.unmodifiable(_terms);

  /// Exact-match dictionary for [code]; empty entries are ignored.
  Map<String, String> map(String code) {
    final out = <String, String>{};
    for (final term in _terms) {
      if (term.lang != code && term.lang != '*') continue;
      if (term.term.trim().isEmpty || term.translation.trim().isEmpty) continue;
      out[term.term.trim()] = term.translation.trim();
    }
    return out;
  }

  Future<void> add(GlossaryTerm term) async {
    _terms.removeWhere((e) => e.term == term.term && e.lang == term.lang);
    _terms.add(term);
    await _flush();
  }

  Future<void> removeAt(int index) async {
    if (index < 0 || index >= _terms.length) return;
    _terms.removeAt(index);
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(
        jsonEncode(_terms.map((e) => e.toJson()).toList()),
        flush: true,
      );
    } catch (_) {}
  }
}
