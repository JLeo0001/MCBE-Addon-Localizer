import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:arc_localizer/core/export_service.dart';

String manifest(String uuid, {String? description}) => jsonEncode(<String, dynamic>{
      'format_version': 2,
      'header': <String, dynamic>{
        'name': 'pack.name',
        if (description != null) 'description': description,
        'uuid': uuid,
        'version': <int>[1, 2, 3],
      },
      'modules': <dynamic>[
        <String, dynamic>{'type': 'resources', 'uuid': uuid},
      ],
    });

void main() {
  late Directory root;

  setUp(() => root = Directory.systemTemp.createTempSync('mcbe_export_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory makePack(String name) {
    final dir = Directory(p.join(root.path, name))..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(
      manifest('11111111-1111-1111-1111-111111111111', description: '示例说明'),
    );
    File(p.join(dir.path, 'texts', 'en_US.lang')).createSync(recursive: true);
    File(p.join(dir.path, 'texts', 'en_US.lang')).writeAsStringSync('pack.name=Demo');
    File(p.join(dir.path, 'textures', 'a.png')).createSync(recursive: true);
    File(p.join(dir.path, 'textures', 'a.png')).writeAsBytesSync(<int>[1, 2, 3, 4]);
    return dir;
  }

  test('exports a single pack as .mcpack with contents at the zip root', () {
    final pack = makePack('Demo RP');
    final out = Directory(p.join(root.path, 'out'))..createSync(recursive: true);

    final dest = ExportService.export(
      outDir: out.path,
      modName: 'Demo',
      credit: 'Local',
      rp: pack.path,
      bp: null,
      code: 'zh_CN',
    );

    expect(dest.toLowerCase().endsWith('.mcpack'), isTrue, reason: dest);
    final file = File(dest);
    expect(file.existsSync(), isTrue);
    expect(file.lengthSync(), greaterThan(0));

    final archive = ZipDecoder().decodeBytes(file.readAsBytesSync());
    final names = archive.files.map((f) => f.name).toList();
    expect(names.contains('manifest.json'), isTrue, reason: names.join(','));
    expect(names.contains('texts/en_US.lang'), isTrue, reason: names.join(','));
  });

  test('exports two packs as .mcaddon with BP/RP folders', () {
    final rp = makePack('Demo RP');
    final bpDir = Directory(p.join(root.path, 'Demo BP'))..createSync(recursive: true);
    File(p.join(bpDir.path, 'manifest.json')).writeAsStringSync(manifest('22222222-2222-2222-2222-222222222222'));
    final out = Directory(p.join(root.path, 'out'))..createSync(recursive: true);

    final dest = ExportService.export(
      outDir: out.path,
      modName: 'Demo',
      credit: 'Local',
      rp: rp.path,
      bp: bpDir.path,
      code: 'zh_CN',
    );

    expect(dest.toLowerCase().endsWith('.mcaddon'), isTrue, reason: dest);
    final archive = ZipDecoder().decodeBytes(File(dest).readAsBytesSync());
    final names = archive.files.map((f) => f.name).toList();
    expect(names.any((n) => n.startsWith('DemoRP/')), isTrue, reason: names.join(','));
    expect(names.any((n) => n.startsWith('DemoBP/')), isTrue, reason: names.join(','));
  });

  test('keeps the version from the mod name and appends the credit', () {
    final pack = makePack('Demo RP');
    final out = Directory(p.join(root.path, 'out'))..createSync(recursive: true);
    final dest = ExportService.export(
      outDir: out.path,
      modName: 'Demo 2.0.1',
      credit: 'Local',
      rp: pack.path,
      bp: null,
      code: 'zh_CN',
    );
    expect(p.basename(dest), contains('2.0.1'));
    expect(p.basename(dest), contains('Local'));
  });
}
