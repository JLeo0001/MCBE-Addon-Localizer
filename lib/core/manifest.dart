import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'lang_files.dart';
import 'types.dart';
import 'languages.dart';

/// `manifest.json` read / patch helpers.
class ManifestService {
  static const Map<String, String> headerLangKeys = <String, String>{
    'name': 'pack.name',
    'description': 'pack.description',
  };

  /// Returns the parsed manifest, or null when missing / unparseable.
  static Map<String, dynamic>? read(String packPath) {
    final file = File(p.join(packPath, 'manifest.json'));
    if (!file.existsSync()) return null;
    final data = Fsx.readJsonFile(file.path);
    return data is Map<String, dynamic> ? data : null;
  }

  static bool hasAddonProductType(Map<String, dynamic>? data) {
    if (data == null) return false;
    final md = data['metadata'];
    return md is Map && md['product_type'] == 'addon';
  }

  static bool applyAddonProductType(String packPath, LogFn log) {
    final data = read(packPath);
    if (data == null) {
      log('  无法解析 manifest.json');
      return false;
    }
    if (hasAddonProductType(data)) {
      log('  · 已是 addon，跳');
      return true;
    }
    final md = data['metadata'];
    if (md is Map<String, dynamic>) {
      md['product_type'] = 'addon';
    } else {
      data['metadata'] = <String, dynamic>{'product_type': 'addon'};
    }
    Fsx.writeJson(p.join(packPath, 'manifest.json'), data);
    log('  已写metadata.product_type = addon');
    return true;
  }

  static bool removeAddonProductType(String packPath, LogFn log) {
    final data = read(packPath);
    if (data == null) {
      log('  无法解析 manifest.json');
      return false;
    }
    final md = data['metadata'];
    if (md is! Map<String, dynamic> || !md.containsKey('product_type')) {
      log('  · 没有 product_type，跳');
      return true;
    }
    md.remove('product_type');
    if (md.isEmpty) data.remove('metadata');
    Fsx.writeJson(p.join(packPath, 'manifest.json'), data);
    log('  已移product_type');
    return true;
  }

  static bool applyPbrCapability(String resourcePack, LogFn log) {
    final data = read(resourcePack);
    if (data == null) {
      log('  无法解析 manifest.json');
      return false;
    }
    final caps = data['capabilities'];
    if (caps is! List) {
      log('  capabilities 不是数组');
      return false;
    }
    if (caps.contains('pbr')) {
      log('  · 已启pbr，跳');
      return true;
    }
    caps.add('pbr');
    Fsx.writeJson(p.join(resourcePack, 'manifest.json'), data);
    log('  已添pbr capability');
    return true;
  }

  /// Makes `header.name` / `header.description` point at `pack.name` /
  /// `pack.description`, moving any literal text into the lang files first.
  ///
  /// Called before export so the shipped pack renders localized names in game.
  static bool ensureLangKeys(String packPath, String code, [LogFn? log]) {
    final data = read(packPath);
    if (data == null) return false;
    final header = data['header'];
    if (header is! Map) return false;
    final texts = Directory(p.join(packPath, 'texts'));
    if (!texts.existsSync()) return false;

    final enPath = p.join(texts.path, 'en_US.lang');
    final targetPath = p.join(texts.path, '$code.lang');
    var changed = false;

    void ensure(String field, String langKey) {
      final current = '${header[field] ?? ''}'.trim();
      if (current.isEmpty || current == langKey) return;
      LangFiles.upsert(enPath, <String, String>{langKey: current});
      if (File(targetPath).existsSync()) {
        LangFiles.upsert(targetPath, <String, String>{langKey: current});
      }
      header[field] = langKey;
      changed = true;
    }

    ensure('name', 'pack.name');
    ensure('description', 'pack.description');
    if (changed) {
      Fsx.writeJson(p.join(packPath, 'manifest.json'), data, backup: false);
      log?.call('  ✓ manifest 改用语言键（${p.basename(packPath)}）');
    }
    return changed;
  }

  /// Resolves `pack.name`, preferring the target language, then `en_US`, then
  /// the first other language file that defines it.
  static String resolveName(String packPath, String code) =>
      _resolveKey(packPath, code, 'pack.name');

  /// Same fallback chain for `pack.description`.
  static String resolveDescription(String packPath, String code) =>
      _resolveKey(packPath, code, 'pack.description');

  static String _resolveKey(String packPath, String code, String key) {
    final texts = Directory(p.join(packPath, 'texts'));
    if (!texts.existsSync()) return '';
    final candidates = <String>[
      p.join(texts.path, '$code.lang'),
      if (code == 'zh_CN') p.join(texts.path, 'zh_cn.lang'),
      p.join(texts.path, 'en_US.lang'),
    ];
    for (final path in candidates) {
      final value = (LangFiles.readMap(path)[key] ?? '').trim();
      if (value.isNotEmpty) return value;
    }
    try {
      final files = texts.listSync().whereType<File>().where((f) => f.path.toLowerCase().endsWith('.lang')).toList()
        ..sort((a, b) => a.path.compareTo(b.path));
      for (final file in files) {
        final value = (LangFiles.readMap(file.path)[key] ?? '').trim();
        if (value.isNotEmpty) return value;
      }
    } catch (_) {}
    return '';
  }

  /// Upper-cases legacy header keys and moves literal name/description into
  /// language keys (`pack.name` / `pack.description`).
  static bool normalizeHeaderKeys(
    String packPath,
    LogFn log, {
    required String code,
    required void Function(String path, Map<String, String> entries) upsert,
  }) {
    final data = read(packPath);
    if (data == null) return false;
    final header = data['header'];
    if (header is! Map<String, dynamic>) return false;
    var changed = false;
    for (final entry in headerLangKeys.entries) {
      final value = header[entry.key];
      if (value is! String || value.trim().isEmpty) continue;
      if (value == entry.value) continue;
      final literal = entry.key == 'name' ? stripCreditSuffix(value) : value;
      header[entry.key] = entry.value;
      upsert(packPath, <String, String>{entry.value: literal});
      changed = true;
    }
    if (changed) {
      Fsx.writeJson(p.join(packPath, 'manifest.json'), data);
      log('  manifest header 已转为语言');
    }
    return changed;
  }
}


