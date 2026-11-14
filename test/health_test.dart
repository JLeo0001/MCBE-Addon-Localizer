import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:arc_localizer/core/health.dart';

String manifest() => jsonEncode(<String, dynamic>{
      'format_version': 2,
      'header': <String, dynamic>{
        'name': 'pack.name',
        'description': 'pack.description',
        'uuid': '11111111-1111-1111-1111-111111111111',
        'version': <int>[1, 0, 0],
      },
      'modules': <dynamic>[
        <String, dynamic>{'type': 'resources', 'uuid': '11111111-1111-1111-1111-111111111111'},
      ],
    });

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('mcbe_health_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Directory pack() {
    final dir = Directory(p.join(root.path, 'Pack'))..createSync(recursive: true);
    File(p.join(dir.path, 'manifest.json')).writeAsStringSync(manifest());
    return dir;
  }

  test('healthy pack has no errors and a high score', () {
    final dir = pack();
    Directory(p.join(dir.path, 'texts')).createSync(recursive: true);
    File(p.join(dir.path, 'texts', 'en_US.lang')).writeAsStringSync('pack.name=Demo\n');
    File(p.join(dir.path, 'texts', 'zh_CN.lang')).writeAsStringSync('pack.name=演示\n');

    final report = HealthChecker.run(<String>[dir.path], 'zh_CN');
    expect(report.errors, 0);
    expect(report.score, greaterThanOrEqualTo(90));
  });

  test('missing manifest is an error', () {
    final dir = Directory(p.join(root.path, 'Broken'))..createSync(recursive: true);
    final report = HealthChecker.run(<String>[dir.path], 'zh_CN');
    expect(report.errors, greaterThan(0));
    expect(report.score, lessThan(100));
  });

  test('reports duplicate keys and untranslated entries', () {
    final dir = pack();
    Directory(p.join(dir.path, 'texts')).createSync(recursive: true);
    File(p.join(dir.path, 'texts', 'en_US.lang'))
        .writeAsStringSync('pack.name=Demo\nentity.a.name=Sword\n');
    File(p.join(dir.path, 'texts', 'zh_CN.lang'))
        .writeAsStringSync('pack.name=演示\npack.name=演示2\nentity.a.name=Sword\n');

    final report = HealthChecker.run(<String>[dir.path], 'zh_CN');
    expect(report.issues.any((e) => e.title.contains('重复')), isTrue);
    expect(report.issues.any((e) => e.title.contains('英文源')), isTrue);
  });

  test('unparsable json is reported', () {
    final dir = pack();
    Directory(p.join(dir.path, 'blocks')).createSync(recursive: true);
    File(p.join(dir.path, 'blocks', 'bad.json')).writeAsStringSync('{ not json');

    final report = HealthChecker.run(<String>[dir.path], 'zh_CN');
    expect(report.issues.any((e) => e.title.contains('JSON')), isTrue);
  });
}
