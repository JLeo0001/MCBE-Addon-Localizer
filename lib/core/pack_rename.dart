import 'dart:io';

import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'lang_files.dart';
import 'manifest.dart';
import 'models.dart';
import 'types.dart';

class PackDisplay {
  PackDisplay(this.name, [this.reason = '']);
  final String? name;
  final String reason;
}

/// Folder naming: `<localized pack name> BP` / `<localized pack name> RP`.
class PackRename {
  static final RegExp _suffixRe = RegExp(r'(?:\s*[\[(_-]?\s*(BP|RP)\s*[\])]?)$');

  static String sanitizeFolderName(String name, {int maxLen = 80}) =>
      Fsx.sanitizeName(name, maxLen: maxLen, fallback: 'unnamed_pack');

  static String ensurePackSuffix(String name, String suffix) {
    final m = _suffixRe.firstMatch(name);
    if (m != null) {
      if (m.group(1) == suffix) {
        return '${name.replaceAll(_suffixRe, '').trim()} $suffix';
      }
      return '$name $suffix';
    }
    return '${name.trim()} $suffix';
  }

  static String? inferPackSuffix(String packDir) {
    final parent = p.basename(p.dirname(packDir));
    for (final entry in <MapEntry<String, String>>[
      const MapEntry('behavior_packs', 'BP'),
      const MapEntry('development_behavior_packs', 'BP'),
      const MapEntry('resource_packs', 'RP'),
      const MapEntry('development_resource_packs', 'RP'),
    ]) {
      if (entry.key == parent) return entry.value;
    }
    return null;
  }

  /// Priority: `<code>.lang` pack.name → `en_US.lang` pack.name →
  /// `languages.json` order → other lang files → manifest header.name.
  static PackDisplay resolveDisplayName(String packDir, String targetCode) {
    final texts = Directory(p.join(packDir, 'texts'));
    if (texts.existsSync()) {
      final direct = <String>[p.join(texts.path, '$targetCode.lang')];
      if (targetCode == 'zh_CN') direct.add(p.join(texts.path, 'zh_cn.lang'));
      String? pick(String? raw) {
        final value = (raw ?? '').trim();
        return value.isEmpty ? null : value;
      }

      for (final path in direct) {
        final name = pick(LangFiles.readMap(path)['pack.name']);
        if (name != null) return PackDisplay(name);
      }
      final english = pick(LangFiles.readMap(p.join(texts.path, 'en_US.lang'))['pack.name']);
      if (english != null) return PackDisplay(english);

      final listed = <String>[];
      final media = Fsx.readJsonFile(p.join(texts.path, 'languages.json'));
      if (media is List) {
        for (final code in media) {
          final path = p.join(texts.path, '$code.lang');
          if (File(path).existsSync()) listed.add(path);
        }
      }
      final extra = texts
          .listSync()
          .whereType<File>()
          .map((f) => f.path)
          .where((s) => s.toLowerCase().endsWith('.lang'))
          .where((s) => !listed.contains(s))
          .toList()
        ..sort();
      for (final path in <String>[...listed, ...extra]) {
        final name = pick(LangFiles.readMap(path)['pack.name']);
        if (name != null) return PackDisplay(name);
      }
    }
    final data = ManifestService.read(packDir);
    final header = data?['header'];
    if (header is Map) {
      final name = header['name'];
      if (name is String && name.trim().isNotEmpty) {
        if (name == 'pack.name') {
          return PackDisplay(null, '未能从 .lang 解析 pack.name');
        }
        return PackDisplay(name.trim());
      }
    }
    return PackDisplay(null, '无法解析包名');
  }

  static RenamePlan planForPack(String packDir, String targetCode) {
    final suffix = inferPackSuffix(packDir);
    if (suffix == null) {
      return RenamePlan(
        src: packDir,
        dest: packDir,
        displayName: '',
        suffix: '',
        skipped: true,
        reason: '不在标准包目录下',
      );
    }
    final resolved = resolveDisplayName(packDir, targetCode);
    final name = resolved.name;
    if (name == null) {
      return RenamePlan(
        src: packDir,
        dest: packDir,
        displayName: '',
        suffix: suffix,
        skipped: true,
        reason: resolved.reason,
      );
    }
    final base = sanitizeFolderName(name);
    final dest = p.join(p.dirname(packDir), ensurePackSuffix(base, suffix));
    return RenamePlan(src: packDir, dest: dest, displayName: name, suffix: suffix);
  }

  static List<RenamePlan> planRenames(String baseDir, String targetCode) {
    final plans = <RenamePlan>[];
    for (final root in <String>[
      'behavior_packs',
      'development_behavior_packs',
      'resource_packs',
      'development_resource_packs',
    ]) {
      final dir = Directory(p.join(baseDir, root));
      if (!dir.existsSync()) continue;
      final subs = dir.listSync().whereType<Directory>().toList()
        ..sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      for (final sub in subs) {
        plans.add(planForPack(sub.path, targetCode));
      }
    }
    return plans;
  }

  /// Two-phase rename to survive case-only and swap collisions.
  static (int, List<String>) applyRenames(List<RenamePlan> plans, {LogFn? log}) {
    final changes = plans.where((e) => e.changed).toList();
    final temps = <String, String>{};
    final errors = <String>[];
    var ok = 0;
    for (var i = 0; i < changes.length; i++) {
      final plan = changes[i];
      try {
        var tmp = p.join(p.dirname(plan.src), '__mcbe_rename_tmp_${i}_${p.basename(plan.src)}');
        var n = 0;
        while (FileSystemEntity.isDirectorySync(tmp) || FileSystemEntity.isFileSync(tmp)) {
          n++;
          tmp = p.join(p.dirname(plan.src), '__mcbe_rename_tmp_${i}_$n');
        }
        Directory(plan.src).renameSync(tmp);
        temps[plan.src] = tmp;
      } catch (e) {
        errors.add('${p.basename(plan.src)}: $e');
      }
    }
    for (final plan in changes) {
      final tmp = temps[plan.src];
      if (tmp == null) continue;
      try {
        var dest = plan.dest;
        if (Directory(dest).existsSync() || File(dest).existsSync()) {
          var n = 2;
          while (Directory('${plan.dest}_$n').existsSync()) {
            n++;
          }
          dest = '${plan.dest}_$n';
        }
        Directory(tmp).renameSync(dest);
        ok++;
        log?.call('  重命名: ${p.basename(plan.src)} → ${p.basename(dest)}');
      } catch (e) {
        errors.add('${p.basename(plan.src)}: $e');
        try {
          Directory(tmp).renameSync(plan.src);
        } catch (_) {}
      }
    }
    return (ok, errors);
  }
}

