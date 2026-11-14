import 'dart:convert';
import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'types.dart';
import 'lang_files.dart';

/// `minecraft:display_name` -> language key standardization.
class DisplayNameService {
  static final RegExp langKeyRe = RegExp(r'^[A-Za-z]\w*(\.[\w:]+)+$');
  static const Set<String> entityComponents = {'minecraft:entity', 'minecraft:client_entity'};
  static const Set<String> identComponents = {'entity', 'client_entity', 'item', 'block'};

  static String? identifierOf(Map data, String? relPath) {
    final desc = data['description'];
    if (desc is Map && desc['identifier'] is String) {
      final id = desc['identifier'] as String;
      if (id.contains(':')) return id;
    }
    for (final key in identComponents) {
      final comp = data[key];
      if (comp is Map) {
        final inner = comp['description'];
        if (inner is Map && inner['identifier'] is String) {
          final id = inner['identifier'] as String;
          if (id.contains(':')) return id;
        }
      }
    }
    return null;
  }

  static String? deriveLangKey(Map data, String? relPath) {
    final id = identifierOf(data, relPath);
    if (id == null) return null;
    final norm = (relPath ?? '').replaceAll(r'\', '/').toLowerCase();
    for (final entry in entityComponents) {
      final comp = data[entry];
      if (comp is Map) {
        final desc = comp['description'];
        if (desc is Map && desc['identifier'] is String) {
          if (desc.containsKey('spawn_egg')) {
            return 'item.spawn_egg.entity.$id.name';
          }
          return 'entity.$id.name';
        }
      }
    }
    if (data['minecraft:block'] != null || norm.contains('/blocks/')) {
      return 'tile.$id.name';
    }
    if (data['minecraft:item'] != null || norm.contains('/items/')) {
      return 'item.$id.name';
    }
    return null;
  }

  static String? findDisplayName(Map data) {
    final hit = _findRecursive(data, 0);
    return hit;
  }

  static String? _findRecursive(Object? node, int depth) {
    if (depth > 12) return null;
    if (node is Map) {
      final dn = node['minecraft:display_name'];
      if (dn is String && dn.trim().isNotEmpty) return dn;
      if (dn is Map && dn['value'] is String) return dn['value'] as String;
      for (final v in node.values) {
        final hit = _findRecursive(v, depth + 1);
        if (hit != null) return hit;
      }
    } else if (node is List) {
      for (final v in node) {
        final hit = _findRecursive(v, depth + 1);
        if (hit != null) return hit;
      }
    }
    return null;
  }

  static bool _replaceDisplayName(Object? node, String value, int depth) {
    if (depth > 12) return false;
    if (node is Map) {
      if (node.containsKey('minecraft:display_name')) {
        node['minecraft:display_name'] = value;
        return true;
      }
      for (final v in node.values) {
        if (_replaceDisplayName(v, value, depth + 1)) return true;
      }
    } else if (node is List) {
      for (final v in node) {
        if (_replaceDisplayName(v, value, depth + 1)) return true;
      }
    }
    return false;
  }

  /// Rewrites literal display names into language keys and fills both lang maps.
  static (int, int, int) standardizeInPack(
    String packDir,
    String code, {
    required LogFn log,
    String? Function(String relPath, Map data)? translateFallback,
  }) {
    final texts = LangFiles.ensureTextsDir(packDir, code, log);
    if (texts == null) return (0, 0, 0);
    final enPath = p.join(texts, 'en_US.lang');
    final targetPath = p.join(texts, '$code.lang');
    final enMap = LangFiles.readMap(enPath);
    final targetMap = LangFiles.readMap(targetPath);

    var found = 0, standardized = 0, fallback = 0;
    final files = Fsx.walkFiles(packDir, filter: (path) => path.toLowerCase().endsWith('.json'));
    for (final file in files) {
      final rel = p.relative(file.path, from: packDir).replaceAll('\\', '/');
      final lower = rel.toLowerCase();
      if (lower.contains('/texts/') || lower.startsWith('texts/')) continue;
      if (lower.contains('_backup')) continue;
      final data = Fsx.readJsonFile(file.path);
      if (data is! Map<String, dynamic>) continue;
      final display = findDisplayName(data);
      if (display == null || display.trim().isEmpty) continue;
      found++;
      final key = deriveLangKey(data, rel);
      if (key == null) {
        final tr = translateFallback?.call(rel, data);
        if (tr != null && tr.isNotEmpty && tr != display) {
          _replaceDisplayName(data, tr, 0);
          Fsx.writeJson(file.path, data, backup: false);
          fallback++;
        }
        continue;
      }
      final isKey = langKeyRe.hasMatch(display);
      if (isKey && display == key) {
        enMap.putIfAbsent(key, () => display);
        targetMap.putIfAbsent(key, () => display);
        continue;
      }
      final original = isKey ? (enMap[display] ?? display) : display;
      if (_replaceDisplayName(data, key, 0)) {
        Fsx.writeJson(file.path, data, backup: false);
      }
      enMap[key] = original;
      targetMap[key] = original;
      standardized++;
    }
    LangFiles.upsert(enPath, enMap);
    LangFiles.upsert(targetPath, targetMap);
    log('  display_name: 找到 $found，标准化 $standardized，回退 $fallback');
    return (found, standardized, fallback);
  }
}

/// Minimal helper for building a translation prompt batch.
String textPromptFor(Map<String, String> entries, String langLabel) {
  final buf = StringBuffer()
    ..writeln('你是 Minecraft 基岩版附加包的本地化译者。把下面的值翻译成$langLabel')
    ..writeln('要求：只输出 key=译文 的行；保留 § 颜色代码、%s/%d 占位符、\\n 转义；不要在译文里加引号。');
  entries.forEach((k, v) => buf.writeln('$k=$v'));
  return buf.toString();
}

String jsonEncodeSafe(Object? value) => jsonEncode(value);



