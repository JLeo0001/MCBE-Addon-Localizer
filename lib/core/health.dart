import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'lang_files.dart';
import 'manifest.dart';

enum Severity { info, warning, error }

class HealthIssue {
  HealthIssue(this.severity, this.title, this.detail, {this.path = ''});

  final Severity severity;
  final String title;
  final String detail;
  final String path;
}

class HealthReport {
  HealthReport(this.issues, this.packs);

  final List<HealthIssue> issues;
  final int packs;

  int get errors => issues.where((e) => e.severity == Severity.error).length;
  int get warnings => issues.where((e) => e.severity == Severity.warning).length;
  int get infos => issues.where((e) => e.severity == Severity.info).length;

  /// 100 minus weighted penalties, floored at 0.
  int get score {
    final raw = 100 - errors * 15 - warnings * 6 - infos * 2;
    return raw < 0 ? 0 : raw;
  }

  String get grade {
    if (score >= 90) return '良好';
    if (score >= 70) return '可用';
    if (score >= 40) return '需修整';
    return '问题较多';
  }
}

/// Static checks over a mod's packs before/after localization.
class HealthChecker {
  static HealthReport run(List<String> packs, String code) {
    final issues = <HealthIssue>[];
    for (final pack in packs) {
      final label = p.basename(pack);
      final manifest = ManifestService.read(pack);
      if (manifest == null) {
        issues.add(HealthIssue(Severity.error, 'manifest 缺失或无法解析', label, path: pack));
        continue;
      }

      final header = manifest['header'];
      if (header is! Map) {
        issues.add(HealthIssue(Severity.error, 'manifest 缺少 header', label, path: pack));
      } else {
        for (final field in <String>['name', 'description']) {
          final value = '${header[field] ?? ''}'.trim();
          if (value.isEmpty) {
            issues.add(HealthIssue(Severity.warning, 'header.$field 为空', label, path: pack));
          } else if (value != 'pack.$field' &&
              !RegExp(r'^[A-Za-z][\w.]*(\.[\w]+)+$').hasMatch(value)) {
            issues.add(HealthIssue(Severity.info, 'header.$field 是字面量，未走语言文件', value,
                path: pack));
          }
        }
        if (header['uuid'] is! String) {
          issues.add(HealthIssue(Severity.error, 'header.uuid 缺失', label, path: pack));
        }
      }

      final texts = Directory(p.join(pack, 'texts'));
      if (!texts.existsSync()) {
        issues.add(HealthIssue(Severity.warning, '没有 texts/ 目录，无法本地化文本', label, path: pack));
      } else {
        final en = File(p.join(texts.path, 'en_US.lang'));
        if (!en.existsSync()) {
          issues.add(HealthIssue(Severity.warning, '缺少 en_US.lang', label, path: pack));
        }
        final target = File(p.join(texts.path, '$code.lang'));
        if (!target.existsSync()) {
          issues.add(HealthIssue(Severity.info, '尚无目标语言文件 $code.lang', label, path: pack));
        } else {
          issues.addAll(_checkLang(target, en.existsSync() ? en : null, label));
        }
      }

      issues.addAll(_checkJson(pack, label));
      issues.addAll(_checkImages(pack, label));
    }
    return HealthReport(issues, packs.length);
  }

  static List<HealthIssue> _checkLang(File target, File? en, String label) {
    final issues = <HealthIssue>[];
    final text = Fsx.readText(target.path);
    final parsed = LangFiles.parse(text);
    final seen = <String>{};
    var duplicates = 0;
    var broken = 0;
    final targetMap = <String, String>{};
    for (final line in parsed) {
      if (line.kind == LangLineKind.entry) {
        final key = line.key ?? '';
        if (key.isEmpty) {
          broken++;
          continue;
        }
        if (!seen.add(key)) duplicates++;
        targetMap[key] = line.value ?? '';
      } else if (line.kind == LangLineKind.comment &&
          line.raw.trim().isNotEmpty &&
          !line.raw.trimLeft().startsWith('##')) {
        broken++;
      }
    }
    if (duplicates > 0) {
      issues.add(HealthIssue(Severity.warning, '语言文件有 $duplicates 个重复键', target.path, path: target.path));
    }
    if (broken > 0) {
      issues.add(HealthIssue(Severity.warning, '语言文件有 $broken 行格式异常', p.basename(target.path),
          path: target.path));
    }
    if (en != null) {
      final enMap = LangFiles.readMap(en.path);
      var untranslated = 0;
      for (final entry in enMap.entries) {
        final value = targetMap[entry.key];
        if (value == null || value.trim().isEmpty || value == entry.value) untranslated++;
      }
      if (untranslated > 0) {
        issues.add(HealthIssue(
          Severity.info,
          '有 $untranslated 条与英文源相同或缺失',
          '$label / ${p.basename(target.path)}',
          path: target.path,
        ));
      }
    }
    return issues;
  }

  static List<HealthIssue> _checkJson(String pack, String label) {
    final issues = <HealthIssue>[];
    var bad = 0;
    for (final file in Fsx.walkFiles(pack, filter: (path) => path.toLowerCase().endsWith('.json'))) {
      try {
        final text = Fsx.readText(file.path);
        if (text.trim().isEmpty) continue;
        jsonDecode(Fsx.stripJsonComments(text));
      } catch (_) {
        bad++;
      }
    }
    if (bad > 0) {
      issues.add(HealthIssue(Severity.error, '$bad 个 JSON 无法解析', label, path: pack));
    }
    return issues;
  }

  static List<HealthIssue> _checkImages(String pack, String label) {
    final issues = <HealthIssue>[];
    var heavy = 0;
    for (final file in Fsx.walkFiles(pack)) {
      final lower = file.path.toLowerCase();
      if (!lower.endsWith('.png') && !lower.endsWith('.jpg') && !lower.endsWith('.jpeg')) continue;
      try {
        if (file.lengthSync() > 3 * 1024 * 1024) heavy++;
      } catch (_) {}
    }
    if (heavy > 0) {
      issues.add(HealthIssue(Severity.info, '$heavy 张图片超过 3 MB', label, path: pack));
    }
    return issues;
  }
}
