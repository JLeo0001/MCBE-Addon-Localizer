import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'config.dart';

/// A reusable bundle of localization settings (language, credit, LLM configs).
class ConfigProfile {
  ConfigProfile({
    required this.name,
    required this.language,
    required this.credit,
    required this.textLlm,
    required this.imageLlm,
  });

  final String name;
  final String language;
  final String credit;
  final Map<String, dynamic> textLlm;
  final Map<String, dynamic> imageLlm;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'language': language,
        'credit': credit,
        'text_llm': textLlm,
        'image_llm': imageLlm,
      };

  static ConfigProfile fromJson(Map<String, dynamic> json) => ConfigProfile(
        name: '${json['name'] ?? '未命名'}',
        language: '${json['language'] ?? 'zh_CN'}',
        credit: '${json['credit'] ?? 'Local'}',
        textLlm: (json['text_llm'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
        imageLlm: (json['image_llm'] as Map?)?.cast<String, dynamic>() ?? <String, dynamic>{},
      );

  /// Captures the current configuration under [name].
  static ConfigProfile capture(HubConfig config, String name) => ConfigProfile(
        name: name,
        language: config.str('target_language'),
        credit: config.str('translator_credit'),
        textLlm: Map<String, dynamic>.from(config.section('text_llm')),
        imageLlm: Map<String, dynamic>.from(config.section('image_llm')),
      );

  Future<void> applyTo(HubConfig config) async {
    config.set(language, 'target_language');
    config.set(credit, 'translator_credit');
    final text = config.section('text_llm');
    text
      ..clear()
      ..addAll(textLlm);
    final image = config.section('image_llm');
    image
      ..clear()
      ..addAll(imageLlm);
    await config.save();
  }
}

class Profiles {
  Profiles._(this._file, this._items);

  final File _file;
  final List<ConfigProfile> _items;

  static Profiles? _instance;

  static Future<Profiles> load() async {
    final cached = _instance;
    if (cached != null) return cached;
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'profiles.json'));
    final items = <ConfigProfile>[];
    if (file.existsSync()) {
      try {
        final data = jsonDecode(file.readAsStringSync());
        if (data is List) {
          for (final row in data) {
            if (row is Map<String, dynamic>) items.add(ConfigProfile.fromJson(row));
          }
        }
      } catch (_) {
        items.clear();
      }
    }
    return _instance = Profiles._(file, items);
  }

  List<ConfigProfile> get all => List<ConfigProfile>.unmodifiable(_items);

  Future<void> save(ConfigProfile profile) async {
    _items.removeWhere((e) => e.name == profile.name);
    _items.add(profile);
    await _flush();
  }

  Future<void> remove(String name) async {
    _items.removeWhere((e) => e.name == name);
    await _flush();
  }

  Future<void> _flush() async {
    try {
      await _file.parent.create(recursive: true);
      await _file.writeAsString(jsonEncode(_items.map((e) => e.toJson()).toList()), flush: true);
    } catch (_) {}
  }
}
