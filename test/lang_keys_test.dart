import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:arc_localizer/core/export_service.dart';
import 'package:arc_localizer/core/manifest.dart';
import 'package:arc_localizer/core/mod_catalog.dart';
import 'package:arc_localizer/core/pack_rename.dart';

String manifest({String name = 'Demo', String description = 'A demo', String? langName}) =>
    jsonEncode(<String, dynamic>{
      'format_version': 2,
      'header': <String, dynamic>{
        'name': langName ?? name,
        'description': description,
        'uuid': '11111111-1111-1111-1111-111111111111',
        'version': <int>[1, 0, 0],
      },
      'modules': <dynamic>[
        <String, dynamic>{'type': 'resources', 'uuid': '11111111-1111-1111-1111-111111111111'},
      ],
    });

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('mcbe_langkey_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory makePack({String name = 'Demo', String description = 'A demo', String? langName}) {
    final dir = Directory(p.join(root.path, 'Demo RP'))..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      manifest(name: name, description: description, langName: langName),
    );
    Directory(p.join(dir.path, 'texts')).createSync(recursive: true);
    File(p.join(dir.path, 'texts', 'en_US.lang')).writeAsStringSync('pack.name=Demo EN\npack.description=English desc\n');
    File(p.join(dir.path, 'texts', 'zh_CN.lang')).writeAsStringSync('pack.name=演示\npack.description=中文说明\n');
    return dir;
  }

  test('resolves pack.name from the target language first', () {
    final pack = makePack(langName: 'pack.name');
    expect(PackRename.resolveDisplayName(pack.path, 'zh_CN').name, '演示');
  });

  test('falls back to en_US when the target language has no entry', () {
    final dir = Directory(p.join(root.path, 'P'))..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(manifest(langName: 'pack.name'));
    Directory(p.join(dir.path, 'texts')).createSync(recursive: true);
    File(p.join(dir.path, 'texts', 'en_US.lang')).writeAsStringSync('pack.name=English Name\n');
    expect(PackRename.resolveDisplayName(dir.path, 'ja_JP').name, 'English Name');
    expect(ManifestService.resolveName(dir.path, 'ja_JP'), 'English Name');
  });

  test('description falls back from target to en_US', () {
    final pack = makePack(langName: 'pack.name');
    expect(ManifestService.resolveDescription(pack.path, 'zh_CN'), '中文说明');
    expect(ManifestService.resolveDescription(pack.path, 'ja_JP'), 'English desc');
  });

  test('mod list uses the localized name and description', () {
    makePack(langName: 'pack.name');
    final mods = ModCatalog.listMods(root.path, targetCode: 'zh_CN');
    expect(mods, hasLength(1));
    expect(mods.first.name, '演示');
    expect(mods.first.description, '中文说明');
  });

  test('ensureLangKeys turns a literal header into pack.name', () {
    final pack = makePack(name: 'Literal Name', description: 'Literal desc');
    // No existing lang keys: the literal must be moved into the files.
    File(p.join(pack.path, 'texts', 'en_US.lang')).writeAsStringSync('');
    File(p.join(pack.path, 'texts', 'zh_CN.lang')).writeAsStringSync('');
    final changed = ManifestService.ensureLangKeys(pack.path, 'zh_CN');
    expect(changed, isTrue);
    final data = jsonDecode(File(p.join(pack.path, 'manifest.json')).readAsStringSync());
    expect(data['header']['name'], 'pack.name');
    expect(data['header']['description'], 'pack.description');
    expect(File(p.join(pack.path, 'texts', 'en_US.lang')).readAsStringSync(), contains('pack.name=Literal Name'));
  });

  test('exported manifest points at pack.name', () {
    final pack = makePack(langName: 'pack.name');
    final out = Directory(p.join(root.path, 'out'))..createSync(recursive: true);
    final dest = ExportService.export(
      outDir: out.path,
      modName: 'Demo',
      credit: 'Local',
      rp: pack.path,
      bp: null,
      code: 'zh_CN',
    );
    final archive = ZipDecoder().decodeBytes(File(dest).readAsBytesSync());
    final entry = archive.files.firstWhere((f) => f.name == 'manifest.json');
    final decoded = jsonDecode(utf8.decode(entry.content as List<int>));
    expect(decoded['header']['name'], 'pack.name');
  });
}
