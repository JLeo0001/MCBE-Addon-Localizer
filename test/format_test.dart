import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:arc_localizer/core/lang_files.dart';
import 'package:arc_localizer/core/pack_ops.dart';

void main() {
  late Directory root;
  setUp(() => root = Directory.systemTemp.createTempSync('mcbe_fmt_'));
  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  test('pretty-prints a minified json file', () {
    final file = File(p.join(root.path, 'blocks', 'a.json'))..createSync(recursive: true);
    final minified = jsonEncode(<String, dynamic>{
      'format_version': '1.20.0',
      'minecraft:block': <String, dynamic>{
        'description': <String, dynamic>{'identifier': 'demo:a'},
        'components': <String, dynamic>{
          'minecraft:geometry': 'geometry.a',
        },
      },
    });
    file.writeAsStringSync(minified);
    expect(minified.contains('\n'), isFalse);

    final (ok, fail, skip) = FormatService.formatJsonFiles(<String>[file.path]);
    expect(ok, 1, reason: 'ok=$ok fail=$fail skip=$skip');
    final out = file.readAsStringSync();
    expect(out.contains('\n'), isTrue, reason: '应被格式化换行');
    expect(out.split('\n').length, greaterThan(5));
  });

  test('manifest.json is formatted too', () {
    final file = File(p.join(root.path, 'manifest.json'));
    file.writeAsStringSync(jsonEncode(<String, dynamic>{
      'format_version': 2,
      'header': <String, dynamic>{'name': 'x', 'uuid': 'u', 'version': <int>[1, 0, 0]},
    }));
    FormatService.formatJsonFiles(<String>[file.path]);
    expect(file.readAsStringSync().contains('\n'), isTrue);
  });

  test('lang upsert writes one entry per line while preserving existing', () {
    final file = File(p.join(root.path, 'texts', 'zh_CN.lang'))..createSync(recursive: true);
    file.writeAsStringSync('## header\npack.name=Demo\n');
    LangFiles.upsert(file.path, <String, String>{
      'pack.description': '说明',
      'entity.demo:a.name': '甲',
    });
    final lines = file.readAsStringSync().split('\n').where((l) => l.trim().isNotEmpty).toList();
    expect(lines, hasLength(4), reason: lines.join(' | '));
    expect(lines[0], '## header');
    expect(lines[3], 'entity.demo:a.name=甲');
  });

  test('lang normalizer puts every entry on its own line and ends with newline', () {
    final file = File(p.join(root.path, 'texts', 'en_US.lang'))..createSync(recursive: true);
    file.writeAsStringSync('a=1\nb=2');
    final changed = LangFiles.normalizeLayout(file.path);
    expect(changed, isTrue);
    final text = file.readAsStringSync();
    expect(text.endsWith('\n'), isTrue);
    expect(text.split('\n').where((l) => l.isNotEmpty), hasLength(2));
  });

  test('rebuild keeps one entry per line after translating', () {
    const original = '## header\npack.name=Demo\nentity.demo:a.name=Diamond Sword\n';
    final parsed = LangFiles.parse(original);
    final out = LangFiles.rebuild(original, parsed, <String, String>{
      'entity.demo:a.name': '钻石剑',
    });
    final lines = out.split('\n').where((l) => l.isNotEmpty).toList();
    expect(lines, hasLength(3), reason: out);
    expect(lines[1], 'pack.name=Demo');
    expect(lines[2], 'entity.demo:a.name=钻石剑');
    expect(out.endsWith('\n'), isTrue);
  });
}
