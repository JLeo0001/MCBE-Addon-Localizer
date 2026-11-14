import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:arc_localizer/core/archive_probe.dart';
import 'package:arc_localizer/core/mod_catalog.dart';

const String rpUuid = '11111111-1111-1111-1111-111111111111';
const String bpUuid = '22222222-2222-2222-2222-222222222222';

String manifest(String uuid, String moduleType, {List<String> deps = const <String>[]}) =>
    jsonEncode(<String, dynamic>{
      'format_version': 2,
      'header': <String, dynamic>{
        'name': 'pack.name',
        'description': 'pack.description',
        'uuid': uuid,
        'version': <int>[1, 0, 0],
      },
      'modules': <dynamic>[
        <String, dynamic>{'type': moduleType, 'uuid': uuid},
      ],
      if (deps.isNotEmpty)
        'dependencies': deps.map((d) => <String, dynamic>{'uuid': d}).toList(),
    });

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mcbe_archive_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  File makeAddon(String name) {
    final archive = Archive();
    void add(String path, String content) {
      final bytes = utf8.encode(content);
      archive.addFile(ArchiveFile(path, bytes.length, bytes));
    }

    add('Foo RP/manifest.json', manifest(rpUuid, 'resources'));
    add('Foo RP/texts/en_US.lang', 'pack.name=Foo\npack.description=一个示例模组');
    add('Foo RP/pack_icon.png', 'PNGDATA');
    add('Foo BP/manifest.json', manifest(bpUuid, 'data', deps: <String>[rpUuid]));
    add('Foo BP/scripts/main.js', 'console.log("hi");');
    final bytes = ZipEncoder().encode(archive);
    final file = File(p.join(root.path, name))..writeAsBytesSync(bytes);
    return file;
  }

  test('probes packs inside an .mcaddon without extracting', () {
    final addon = makeAddon('Demo.mcaddon');
    final packs = ArchiveProbe.probe(addon.path);
    expect(packs, hasLength(2));
    expect(packs.where((e) => e.kind == 'RP'), hasLength(1));
    expect(packs.where((e) => e.kind == 'BP'), hasLength(1));
  });

  test('reads icon bytes and resolves a lang-key description', () {
    final addon = makeAddon('Demo.mcaddon');
    final info = ArchiveProbe.inspect(addon.path);
    expect(info.icon, isNotNull, reason: '应能直接从压缩包取出 pack_icon.png');
    expect(info.description, contains('一个示例模组'), reason: 'pack.description 应解析为 lang 文案');

    final mods = ModCatalog.listMods(root.path);
    expect(mods.single.iconBytes, isNotNull);
    expect(mods.single.description, contains('一个示例模组'));
  });

  test('caches probe results until the file changes', () {
    final addon = makeAddon('Demo.mcaddon');
    final first = ArchiveProbe.inspect(addon.path);
    final second = ArchiveProbe.inspect(addon.path);
    expect(identical(first, second), isTrue);
  });

  test('lists archive-backed mods and marks both pack kinds', () {
    makeAddon('Demo.mcaddon');
    final mods = ModCatalog.listMods(root.path);
    expect(mods, hasLength(1));
    expect(mods.first.isArchive, isTrue);
    expect(mods.first.hasRp, isTrue);
    expect(mods.first.hasBp, isTrue);
  });

  test('extracts an archive so the normal pipeline can read it', () {
    final addon = makeAddon('Demo.mcaddon');
    final dest = p.join(root.path, 'work', 'demo');
    ArchiveProbe.extract(addon.path, dest);
    expect(File(p.join(dest, 'Foo RP', 'manifest.json')).existsSync(), isTrue);
    expect(File(p.join(dest, 'Foo BP', 'scripts', 'main.js')).existsSync(), isTrue);

    final packs = ModCatalog.scanPacks(dest);
    expect(packs, hasLength(2));
    expect(packs.any((e) => e.kind == 'RP'), isTrue);
    expect(packs.any((e) => e.kind == 'BP'), isTrue);
  });

  test('finds packs nested inside arbitrary folders', () {
    final deep = Directory(p.join(root.path, 'downloads', 'some', 'nested', 'pack'))
      ..createSync(recursive: true);
    File(p.join(deep.path, 'manifest.json')).writeAsStringSync(manifest(rpUuid, 'resources'));

    final mods = ModCatalog.listMods(root.path);
    expect(mods, hasLength(1));
    expect(mods.first.hasRp, isTrue);
  });
}
