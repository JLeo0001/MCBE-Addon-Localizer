import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// App-level configuration, persisted as JSON in the app support directory.
///
/// Layout matches the original tool: a flat document with `text_llm`,
/// `image_llm` and `cloud_drives` sub-objects.
class HubConfig {
  HubConfig._(this.path, this._data);

  final String path;
  final Map<String, dynamic> _data;

  static Map<String, dynamic> defaultConfig() => <String, dynamic>{
    'resource_pack_path': '',
    'behavior_pack_path': '',
    'current_mod_name': '',
    'mods_base_dir': '',
    'translator_credit': 'Local',
    'target_language': 'zh_CN',
    'export_dir': '',
    'image_localize_method': 'llm',
    'ocr_endpoint': '',
    'text_llm': <String, dynamic>{
      'base_url': 'https://api.openai.com/v1',
      'api_key': '',
      'model': 'gpt-4o-mini',
      'proxy': '',
    },
    'image_llm': <String, dynamic>{
      'base_url': 'https://api.openai.com/v1',
      'api_key': '',
      'model': 'gpt-image-1',
      'proxy': '',
    },
    'cloud_drives': <String, dynamic>{},
  };

  static Future<HubConfig> load() async {
    final dir = await getApplicationSupportDirectory();
    final file = File(p.join(dir.path, 'config.json'));
    final data = defaultConfig();
    if (await file.exists()) {
      try {
        final raw = jsonDecode(await file.readAsString());
        if (raw is Map<String, dynamic>) {
          _deepMerge(data, raw);
        }
      } catch (_) {
        // corrupted config: fall back to defaults
      }
    }
    _sanitize(data);
    return HubConfig._(file.path, data);
  }

  static void _deepMerge(Map<String, dynamic> base, Map<String, dynamic> over) {
    over.forEach((key, value) {
      final cur = base[key];
      if (cur is Map<String, dynamic> && value is Map) {
        final nested = <String, dynamic>{};
        value.forEach((k, v) => nested['$k'] = v);
        _deepMerge(cur, nested);
      } else {
        base[key] = value;
      }
    });
  }

  static void _sanitize(Map<String, dynamic> data) {
    final credit = (data['translator_credit'] as String? ?? '').trim();
    data['translator_credit'] = credit.isEmpty ? 'Local' : credit;
    final lang = (data['target_language'] as String? ?? '').trim();
    data['target_language'] = lang.isEmpty ? 'zh_CN' : lang;
    final method = (data['image_localize_method'] as String? ?? '').trim().toLowerCase();
    data['image_localize_method'] = (method == 'ocr') ? 'ocr' : 'llm';
  }

  Map<String, dynamic> get raw => _data;

  /// `get('text_llm', 'api_key')`; missing keys yield null.
  T? get<T>(Object key, [Object? sub]) {
    dynamic cur = _data[key];
    if (sub != null && cur is Map) cur = cur[sub];
    if (cur is T) return cur;
    if (T == String && cur != null) return cur.toString() as T;
    return null;
  }

  String str(Object key, [Object? sub]) => get<dynamic>(key, sub)?.toString() ?? '';

  bool flag(Object key, Object sub) {
    final v = get<dynamic>(key, sub);
    return v == true;
  }

  void set(Object? value, Object key, [Object? sub]) {
    if (sub == null) {
      _data['$key'] = value;
      return;
    }
    final cur = _data['$key'];
    if (cur is Map<String, dynamic>) {
      cur['$sub'] = value;
    } else {
      _data['$key'] = <String, dynamic>{'$sub': value};
    }
  }

  Map<String, dynamic> section(String key) {
    final cur = _data[key];
    if (cur is Map<String, dynamic>) return cur;
    final fresh = <String, dynamic>{};
    _data[key] = fresh;
    return fresh;
  }

  Timer? _saveTimer;
  bool _dirty = false;

  /// Marks the document dirty and persists it shortly after the last change.
  /// Settings screens call this on every edit, so there is no save button.
  void scheduleSave({Duration delay = const Duration(milliseconds: 350)}) {
    _dirty = true;
    _saveTimer?.cancel();
    _saveTimer = Timer(delay, () {
      _dirty = false;
      save();
    });
  }

  /// Writes immediately if anything is pending (used when leaving a page).
  Future<void> flush() async {
    _saveTimer?.cancel();
    if (!_dirty) return;
    _dirty = false;
    await save();
  }

  Future<bool> save() async {
    try {
      final file = File(path);
      await file.parent.create(recursive: true);
      await file.writeAsString(
        const JsonEncoder.withIndent('  ').convert(_data),
        flush: true,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
