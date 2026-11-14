import 'dart:io';

import 'package:path/path.dart' as p;

import 'archive_probe.dart';
import 'languages.dart';
import 'manifest.dart';
import 'models.dart';
import 'pack_rename.dart';

/// Discovers mods anywhere under a directory: every folder that carries a
/// `manifest.json` counts as a pack, and every `.mcpack` / `.mcaddon` / `.zip`
/// counts as an archive-backed mod. No fixed `resource_packs`-style layout is
/// required.
class ModCatalog {
  static final RegExp _suffixRe = RegExp(r'(?:\s*[\[(_-]?\s*(BP|RP)\s*[\])]?)$');

  static const Set<String> _skipDirNames = <String>{
    'node_modules',
    '__MACOSX',
    '.git',
    '.dart_tool',
    'build',
  };

  static const int maxDepth = 6;

  static String _baseName(String name) =>
      name.replaceAll(_suffixRe, '').trim().toLowerCase();

  /// Recursively collects every pack folder under [baseDir].
  static List<PackInfo> scanPacks(String baseDir, {String targetCode = defaultCode}) {
    final found = <PackInfo>[];
    final seen = <String>{};

    void visit(Directory dir, int depth) {
      if (depth > maxDepth) return;
      final hasManifest = File(p.join(dir.path, 'manifest.json')).existsSync();
      if (hasManifest) {
        final info = _packAt(dir.path, targetCode, seen);
        if (info != null) found.add(info);
        return; // never descend into a pack
      }
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync();
      } catch (_) {
        return;
      }
      entries.sort((a, b) => a.path.toLowerCase().compareTo(b.path.toLowerCase()));
      for (final entry in entries) {
        if (entry is! Directory) continue;
        final name = p.basename(entry.path);
        if (name.startsWith('.') || _skipDirNames.contains(name)) continue;
        visit(entry, depth + 1);
      }
    }

    final root = Directory(baseDir);
    if (root.existsSync()) visit(root, 0);
    return found;
  }

  static PackInfo? _packAt(String path, String targetCode, Set<String> seen) {
    final key = p.normalize(p.absolute(path));
    if (!seen.add(key)) return null;
    final data = ManifestService.read(path);
    if (data == null) return null;
    final header = data['header'];
    if (header is! Map) return null;
    final uuid = header['uuid'];
    if (uuid is! String || uuid.trim().isEmpty) return null;
    final deps = <String>{};
    final rawDeps = data['dependencies'];
    final list = rawDeps is List ? rawDeps : (rawDeps is Map ? <dynamic>[rawDeps] : const <dynamic>[]);
    for (final d in list) {
      if (d is Map && d['uuid'] is String) {
        deps.add((d['uuid'] as String).trim().toLowerCase());
      }
    }
    final display = PackRename.resolveDisplayName(path, targetCode).name ?? p.basename(path);
    return PackInfo(
      path: path,
      kind: _inferKind(path, data),
      uuid: uuid.trim().toLowerCase(),
      depUuids: deps,
      displayName: display,
    );
  }

  /// Every archive under [baseDir] (depth-limited), sorted by path.
  static List<String> findArchives(String baseDir) {
    final out = <String>[];
    void visit(Directory dir, int depth) {
      if (depth > maxDepth) return;
      List<FileSystemEntity> entries;
      try {
        entries = dir.listSync();
      } catch (_) {
        return;
      }
      for (final entry in entries) {
        if (entry is Directory) {
          final name = p.basename(entry.path);
          if (name.startsWith('.') || _skipDirNames.contains(name)) continue;
          visit(entry, depth + 1);
        } else if (entry is File && ArchiveProbe.isArchivePath(entry.path)) {
          out.add(entry.path);
        }
      }
    }

    final root = Directory(baseDir);
    if (root.existsSync()) visit(root, 0);
    out.sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
    return out;
  }

  /// Packs on disk plus archive-backed mods, paired and sorted for display.
  static List<ModEntry> listMods(String baseDir, {String targetCode = defaultCode}) {
    final packs = scanPacks(baseDir, targetCode: targetCode);
    final mods = _pairPacks(packs, targetCode);

    for (final archivePath in findArchives(baseDir)) {
      final info = ArchiveProbe.inspect(archivePath);
      final inner = info.packs;
      final hasRp = inner.any((e) => e.kind == 'RP');
      final hasBp = inner.any((e) => e.kind == 'BP');
      var name = inner.isNotEmpty && inner.first.name.trim().isNotEmpty
          ? inner.first.name
          : p.basenameWithoutExtension(archivePath);
      name = stripCreditSuffix(name).replaceAll(RegExp(r'§.'), '').trim();
      if (name.isEmpty) name = p.basenameWithoutExtension(archivePath);
      mods.add(ModEntry(
        name: name,
        archive: archivePath,
        archiveHasRp: inner.isEmpty ? true : hasRp,
        archiveHasBp: hasBp,
        description: info.description,
        iconBytes: info.icon,
      ));
    }

    mods.sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    return mods;
  }

  static List<ModEntry> _pairPacks(List<PackInfo> packs, String targetCode) {
    final rps = packs.where((e) => e.kind == 'RP').toList();
    final bps = packs.where((e) => e.kind == 'BP').toList();
    final usedRp = <PackInfo>{};
    final usedBp = <PackInfo>{};
    final groups = <List<PackInfo>>[];

    for (final bp in bps) {
      PackInfo? match;
      for (final dep in bp.depUuids) {
        for (final rp in rps) {
          if (!usedRp.contains(rp) && rp.uuid == dep) {
            match = rp;
            break;
          }
        }
        if (match != null) break;
      }
      if (match == null) {
        for (final rp in rps) {
          if (!usedRp.contains(rp) && rp.depUuids.contains(bp.uuid)) {
            match = rp;
            break;
          }
        }
      }
      if (match != null) {
        groups.add(<PackInfo>[match, bp]);
        usedRp.add(match);
        usedBp.add(bp);
      }
    }
    for (final rp in rps) {
      if (usedRp.contains(rp)) continue;
      PackInfo? match;
      for (final dep in rp.depUuids) {
        for (final bp in bps) {
          if (!usedBp.contains(bp) && bp.uuid == dep) {
            match = bp;
            break;
          }
        }
        if (match != null) break;
      }
      if (match != null) {
        groups.add(<PackInfo>[rp, match]);
        usedRp.add(rp);
        usedBp.add(match);
      } else {
        groups.add(<PackInfo>[rp]);
        usedRp.add(rp);
      }
    }
    for (final bp in bps) {
      if (!usedBp.contains(bp)) groups.add(<PackInfo>[bp]);
    }

    // Merge leftover singles that share a base display name.
    final merged = <List<PackInfo>>[];
    final loose = <PackInfo>[];
    for (final group in groups) {
      if (group.length == 2) {
        merged.add(group);
      } else {
        loose.add(group.first);
      }
    }
    final claimed = <PackInfo>{};
    for (final a in loose) {
      if (claimed.contains(a)) continue;
      for (final b in loose) {
        if (identical(a, b) || claimed.contains(b)) continue;
        if (a.kind == b.kind) continue;
        if (_baseName(a.displayName) == _baseName(b.displayName)) {
          final rp = a.kind == 'RP' ? a : b;
          final bp = a.kind == 'BP' ? a : b;
          merged.add(<PackInfo>[rp, bp]);
          claimed.add(a);
          claimed.add(b);
          break;
        }
      }
    }
    for (final a in loose) {
      if (!claimed.contains(a)) merged.add(<PackInfo>[a]);
    }

    final mods = <ModEntry>[];
    for (final group in merged) {
      PackInfo? rp;
      PackInfo? bp;
      for (final e in group) {
        if (e.kind == 'RP') rp = e;
        if (e.kind == 'BP') bp = e;
      }
      var name = (rp ?? bp)!.displayName;
      name = name.replaceAll(_suffixRe, '').replaceAll(RegExp(r'§.'), '').trim();
      if (name.isEmpty) name = p.basename((rp ?? bp)!.path);
      mods.add(ModEntry(
        name: name,
        resourcePack: rp?.path,
        behaviorPack: bp?.path,
        description: _descriptionOf((bp ?? rp)!.path, targetCode),
      ));
    }
    return mods;
  }

  /// Reads `header.description`, resolving `pack.description` with the target
  /// language first, then `en_US`, then any other language file.
  static String _descriptionOf(String packPath, String code) {
    final resolved = ManifestService.resolveDescription(packPath, code);
    if (resolved.isNotEmpty) return resolved;
    final data = ManifestService.read(packPath);
    final header = data?['header'];
    if (header is! Map) return '';
    final raw = '${header['description'] ?? ''}'.trim();
    if (raw.isEmpty || raw == 'pack.description') return '';
    return raw;
  }

  /// Human-readable report explaining what was found (and what was not).
  static String diagnose(String baseDir) {
    final b = StringBuffer();
    final base = Directory(baseDir);
    b.writeln('基准目录: $baseDir');
    b.writeln('存在: ${base.existsSync()}');
    b.writeln('扫描深度上限: $maxDepth（不进入以 . 开头的目录与 node_modules/build）');
    b.writeln('');

    final packs = scanPacks(baseDir);
    b.writeln('识别到的包目录: ${packs.length} 个');
    for (final pack in packs.take(12)) {
      b.writeln('  [${pack.kind}] ${pack.displayName}');
      b.writeln('        ${pack.path}');
    }
    if (packs.length > 12) b.writeln('  …其余 ${packs.length - 12} 个省略');

    final archives = findArchives(baseDir);
    b.writeln('');
    b.writeln('识别到的压缩包: ${archives.length} 个');
    for (final a in archives.take(12)) {
      final inner = ArchiveProbe.probe(a);
      final kinds = inner.map((e) => e.kind).toSet().join('+');
      b.writeln('  ${p.basename(a)}  ${inner.isEmpty ? '（无法读取 manifest）' : '[$kinds ${inner.length} 个包]'}');
    }
    if (archives.length > 12) b.writeln('  …其余 ${archives.length - 12} 个省略');

    final mods = listMods(baseDir);
    b.writeln('');
    b.writeln('合并后的模组: ${mods.length} 个');
    for (final m in mods.take(12)) {
      b.writeln('  ${m.isArchive ? '[压缩包]' : '[文件夹]'} ${m.name}  (${m.packLabel})');
    }
    return b.toString();
  }

  /// RP/BP guess for a pack folder.
  static String _inferKind(String path, Map data) {
    final modules = data['modules'];
    if (modules is List) {
      for (final m in modules) {
        if (m is Map) {
          if (m['type'] == 'data') return 'BP';
          if (m['type'] == 'resources') return 'RP';
        }
      }
    }
    final parent = p.basename(p.dirname(path)).toLowerCase();
    if (parent.contains('behavior')) return 'BP';
    if (parent.contains('resource')) return 'RP';
    if (Directory(p.join(path, 'texts')).existsSync() ||
        Directory(p.join(path, 'textures')).existsSync() ||
        Directory(p.join(path, 'font')).existsSync()) {
      return 'RP';
    }
    if (Directory(p.join(path, 'entities')).existsSync() ||
        Directory(p.join(path, 'scripts')).existsSync() ||
        Directory(p.join(path, 'loot_tables')).existsSync()) {
      return 'BP';
    }
    return 'RP';
  }
}
