import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:arc_localizer/core/mod_catalog.dart';

String packManifest(String uuid, {List<String> deps = const <String>[]}) => jsonEncode(<String, dynamic>{
      'format_version': 2,
      'header': <String, dynamic>{
        'name': 'pack.name',
        'uuid': uuid,
        'version': <int>[1, 0, 0],
      },
      if (deps.isNotEmpty)
        'dependencies': deps.map((d) => <String, dynamic>{'uuid': d}).toList(),
    });

void main() {
  late Directory root;

  setUp(() {
    root = Directory.systemTemp.createTempSync('mcbe_scan_');
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('finds packs under the standard com.mojang layout', () {
    final rp = Directory(p.join(root.path, 'resource_packs', 'My Mod RP'))..createSync(recursive: true);
    final bp = Directory(p.join(root.path, 'behavior_packs', 'My Mod BP'))..createSync(recursive: true);
    File(p.join(rp.path, 'manifest.json')).writeAsStringSync(packManifest('11111111-1111-1111-1111-111111111111'));
    File(p.join(bp.path, 'manifest.json')).writeAsStringSync(packManifest(
      '22222222-2222-2222-2222-222222222222',
      deps: <String>['11111111-1111-1111-1111-111111111111'],
    ));

    final mods = ModCatalog.listMods(root.path);
    expect(mods, hasLength(1));
    expect(mods.first.hasRp, isTrue);
    expect(mods.first.hasBp, isTrue);
  });

  test('finds packs in development_* roots', () {
    final dir = Directory(p.join(root.path, 'development_resource_packs', 'Dev Pack'));
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(packManifest('33333333-3333-3333-3333-333333333333'));

    final mods = ModCatalog.listMods(root.path);
    expect(mods, hasLength(1));
    expect(mods.first.hasRp, isTrue);
  });

  test('handles a directory that is itself a pack', () {
    File(p.join(root.path, 'manifest.json')).writeAsStringSync(packManifest('44444444-4444-4444-4444-444444444444'));

    final mods = ModCatalog.listMods(root.path);
    expect(mods, isNotEmpty, reason: '选中的目录本身就是包时应能识别');
  });

  test('handles a directory holding pack folders directly', () {
    final dir = Directory(p.join(root.path, 'Some Addon'));
    dir.createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(packManifest('55555555-5555-5555-5555-555555555555'));

    final mods = ModCatalog.listMods(root.path);
    expect(mods, isNotEmpty, reason: '父目录下直接放着包文件夹时应能识别');
  });

  test('survives manifests without uuid', () {
    final dir = Directory(p.join(root.path, 'resource_packs', 'Broken'))..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(jsonEncode(<String, dynamic>{
      'format_version': 2,
      'header': <String, dynamic>{'name': 'x'},
    }));

    expect(() => ModCatalog.listMods(root.path), returnsNormally);
    expect(ModCatalog.listMods(root.path), isEmpty);
  });
}
