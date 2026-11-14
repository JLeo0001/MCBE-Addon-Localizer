import 'dart:io';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'fsx.dart';
import 'types.dart';
import 'languages.dart';
import 'manifest.dart';

/// Builds `.mcpack` / `.mcaddon` archives from a localized mod.
class ExportService {
  static const Set<String> skipNames = {'.ds_store', 'thumbs.db', 'desktop.ini'};

  static String baseModName(String name) =>
      stripCreditSuffix(Fsx.removeMcFormatting(name)).trim();

  static String? versionInName(String name) {
    final m = RegExp(r'(?<![\d.])v?(\d+\.\d+\.\d+)(?![\d.])', caseSensitive: false).firstMatch(name);
    return m?.group(1);
  }

  static String? formatVersion(dynamic version) {
    if (version is List || version is Iterable) {
      final parts = <String>[];
      for (final v in version) {
        if (v is int) {
          parts.add('$v');
        } else if (v is String && RegExp(r'^\d+$').hasMatch(v)) {
          parts.add(v);
        } else {
          return null;
        }
        if (parts.length == 3) break;
      }
      while (parts.length < 3) {
        parts.add('0');
      }
      return parts.join('.');
    }
    if (version is String) {
      final m = RegExp(r'(\d+)\.(\d+)\.(\d+)').firstMatch(version);
      return m?.group(0);
    }
    return null;
  }

  static String? packVersion(String? packPath) {
    if (packPath == null) return null;
    final data = Fsx.readJsonFile(p.join(packPath, 'manifest.json'));
    if (data is Map && data['header'] is Map) {
      return formatVersion((data['header'] as Map)['version']);
    }
    return null;
  }

  /// (version, source) where source is "name" | "bp" | "rp" | "".
  static (String?, String) versionToAppend(String modName, String? bp, String? rp) {
    final inName = versionInName(modName);
    if (inName != null) return (inName, 'name');
    final bpv = packVersion(bp);
    if (bpv != null) return (bpv, 'bp');
    final rpv = packVersion(rp);
    if (rpv != null) return (rpv, 'rp');
    return (null, '');
  }

  static String buildFileName(String modName, String credit, bool both, String code, String? version) {
    final base = Fsx.sanitizeName(baseModName(modName), fallback: 'unnamed_mod');
    final stem = version == null ? base : '$base $version';
    final name = withCredit(stem, credit, code);
    return '${Fsx.sanitizeName(name, fallback: 'unnamed_mod')}${both ? '.mcaddon' : '.mcpack'}';
  }

  static String export({
    required String outDir,
    required String modName,
    required String credit,
    required String? rp,
    required String? bp,
    required String code,
    LogFn? log,
  }) {
    final both = rp != null && bp != null;
    final base = Fsx.sanitizeName(baseModName(modName), fallback: 'unnamed_mod');
    final (version, _) = versionToAppend(modName, bp, rp);
    final fileName = buildFileName(modName, credit, both, code, version);
    final destination = File(p.join(outDir, fileName));
    if (destination.existsSync()) destination.deleteSync();

    // Ship packs whose manifest points at pack.name / pack.description so the
    // game shows the localized title instead of the source-language literal.
    if (rp != null) ManifestService.ensureLangKeys(rp, code, log);
    if (bp != null) ManifestService.ensureLangKeys(bp, code, log);

    final archive = Archive();
    if (rp != null && bp != null) {
      _addTree(archive, rp, '${base}RP', log);
      _addTree(archive, bp, '${base}BP', log);
    } else {
      _addTree(archive, (rp ?? bp)!, '', log);
    }

    final bytes = ZipEncoder().encode(archive);
    destination.parent.createSync(recursive: true);
    destination.writeAsBytesSync(bytes, flush: true);
    log?.call('  压缩包: ${destination.path}');
    log?.call('  条目数: ${archive.length}');
    return destination.path;
  }

  static void _addTree(Archive archive, String root, String prefix, LogFn? log) {
    final files = Fsx.walkFiles(root);
    for (final file in files) {
      final rel = p.relative(file.path, from: root).replaceAll('\\', '/');
      final lower = rel.toLowerCase();
      if (lower.contains('_backup')) continue;
      if (lower.endsWith('.backup') || lower.endsWith('.bak')) continue;
      if (skipNames.contains(p.basename(lower))) continue;
      try {
        final data = file.readAsBytesSync();
        final name = prefix.isEmpty ? rel : '$prefix/$rel';
        archive.addFile(ArchiveFile(name, data.length, data));
      } catch (e) {
        log?.call('  鈿?璺宠繃 ${p.basename(file.path)}: $e');
      }
    }
  }
}

/// Pack lifecycle: move official packs to `development_*`, delete, prune config.
class PackManage {
  static const Map<String, String> officialToDev = {
    'resource_packs': 'development_resource_packs',
    'behavior_packs': 'development_behavior_packs',
  };

  static String? devTarget(String packDir) {
    final parent = Directory(p.dirname(packDir));
    final devName = officialToDev[p.basename(parent.path)];
    if (devName == null) return null;
    return p.join(p.dirname(parent.path), devName, p.basename(packDir));
  }

  static String? moveToDevelopment(String packDir) {
    final target = devTarget(packDir);
    if (target == null) return null;
    var dest = target;
    var n = 2;
    while (Directory(dest).existsSync()) {
      dest = '${target}_$n';
      n++;
    }
    Directory(dest).parent.createSync(recursive: true);
    Directory(packDir).renameSync(dest);
    return dest;
  }

  static (int, List<String>) deleteDirs(List<String> paths) {
    var ok = 0;
    final errors = <String>[];
    for (final path in paths) {
      final dir = Directory(path);
      if (!dir.existsSync()) continue;
      try {
        dir.deleteSync(recursive: true);
        ok++;
      } catch (e) {
        errors.add('${p.basename(path)}: $e');
      }
    }
    return (ok, errors);
  }
}

