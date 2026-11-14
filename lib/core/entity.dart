import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'types.dart';

/// Entity helpers: monster health scan and `monster` family tagging.
class EntityService {
  static List<String> packDirs(String worldOrPack) {
    final nested = Directory(p.join(worldOrPack, 'behavior_packs'));
    if (nested.existsSync()) {
      return nested.listSync().whereType<Directory>().map((d) => d.path).toList();
    }
    return <String>[worldOrPack];
  }

  static List<File> entityFiles(List<String> packs) {
    final out = <File>[];
    for (final pack in packs) {
      final dir = Directory(p.join(pack, 'entities'));
      if (!dir.existsSync()) continue;
      out.addAll(dir.listSync().whereType<File>().where((f) => f.path.endsWith('.json')));
    }
    return out;
  }

  static String identifierOf(Map data) {
    final desc = data['minecraft:entity'];
    if (desc is Map) {
      final d = desc['description'];
      if (d is Map && d['identifier'] is String) return d['identifier'] as String;
    }
    return '';
  }

  static List<String> familiesOf(Map data) {
    final entity = data['minecraft:entity'];
    if (entity is! Map) return <String>[];
    final comps = entity['components'];
    if (comps is! Map) return <String>[];
    final tf = comps['minecraft:type_family'];
    if (tf is! Map) return <String>[];
    final families = tf['family'];
    if (families is List) return families.map((e) => '$e').toList();
    return <String>[];
  }

  static String healthOf(Map data) {
    final entity = data['minecraft:entity'];
    if (entity is! Map) return '?';
    final comps = entity['components'];
    if (comps is! Map) return '?';
    final hp = comps['minecraft:health'];
    if (hp is Map) {
      final v = hp['value'] ?? hp['max'];
      if (v is num) return '${v.round()}';
      if (v is String) return v;
    }
    return '?';
  }

  static bool targetsPlayers(Map data) {
    final text = jsonEncode(data);
    return text.contains('"player"') &&
        (text.contains('nearest_attackable_target') ||
            text.contains('behavior.nearest_attackable_target') ||
            text.contains('hurt_by_target'));
  }

  static String nameFromPacks(List<String> packs, String identifier) {
    for (final pack in packs) {
      final texts = Directory(p.join(pack, 'texts'));
      if (!texts.existsSync()) continue;
      for (final file in texts.listSync().whereType<File>()) {
        if (!file.path.endsWith('.lang')) continue;
        for (final line in Fsx.readText(file.path).split('\n')) {
          if (line.startsWith('entity.$identifier.name=')) {
            return line.substring('entity.$identifier.name='.length).trim();
          }
        }
      }
    }
    return '';
  }

  /// Returns (identifier, hp, display name) for every monster-family entity.
  static List<(String, String, String)> scanMonsters(List<String> packs, LogFn log) {
    final out = <(String, String, String)>[];
    for (final file in entityFiles(packs)) {
      final data = Fsx.readJsonFile(file.path);
      if (data is! Map<String, dynamic>) continue;
      final families = familiesOf(data);
      if (!families.contains('monster')) continue;
      final id = identifierOf(data);
      if (id.isEmpty) continue;
      final name = nameFromPacks(packs, id);
      out.add((id, healthOf(data), name));
      log('  $id → ${name.isEmpty ? '' : '[$name] '}血量 ${healthOf(data)}');
    }
    out.sort((a, b) => a.$1.compareTo(b.$1));
    return out;
  }

  /// Adds `monster` to entities that attack players; returns how many changed.
  static int addMonsterTags(List<String> packs, LogFn log) {
    var changed = 0;
    for (final file in entityFiles(packs)) {
      final data = Fsx.readJsonFile(file.path);
      if (data is! Map<String, dynamic>) continue;
      final entity = data['minecraft:entity'];
      if (entity is! Map) continue;
      final comps = entity['components'];
      if (comps is! Map) continue;
      final families = familiesOf(data);
      if (families.contains('monster')) continue;
      if (!targetsPlayers(data)) continue;
      var tf = comps['minecraft:type_family'];
      if (tf is! Map) {
        tf = <String, dynamic>{'family': <String>[]};
        comps['minecraft:type_family'] = tf;
      }
      final list = tf['family'];
      if (list is List) {
        list.add('monster');
      } else {
        tf['family'] = <String>['monster'];
      }
      Fsx.writeJson(file.path, data, backup: false);
      changed++;
      log('  ${p.basename(file.path)} 已添monster');
    }
    return changed;
  }
}

