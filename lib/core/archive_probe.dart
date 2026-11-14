import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:path/path.dart' as p;

import 'fsx.dart';

/// One pack discovered inside an archive.
class ArchivePack {
  ArchivePack({
    required this.prefix,
    required this.uuid,
    required this.deps,
    required this.kind,
    required this.name,
    this.description = '',
  });

  /// Directory prefix inside the archive ('' when the pack sits at the root).
  final String prefix;
  final String uuid;
  final Set<String> deps;
  final String kind; // 'RP' | 'BP'
  final String name;
  final String description;
}

/// Everything the mod list needs to render an archive without unpacking it.
class ArchiveInfo {
  ArchiveInfo({required this.packs, this.icon, this.description = ''});

  final List<ArchivePack> packs;
  final Uint8List? icon;
  final String description;

  bool get isEmpty => packs.isEmpty;
}

class _CacheEntry {
  _CacheEntry(this.size, this.mtime, this.info);
  final int size;
  final int mtime;
  final ArchiveInfo info;
}

/// Reads `.mcpack` / `.mcaddon` / `.zip` archives without extracting them.
/// Results are cached per file until it changes on disk.
class ArchiveProbe {
  static final Map<String, _CacheEntry> _cache = <String, _CacheEntry>{};

  static bool isArchivePath(String path) {
    final lower = path.toLowerCase();
    return lower.endsWith('.mcpack') || lower.endsWith('.mcaddon') || lower.endsWith('.zip');
  }

  static ArchiveInfo inspect(String path) {
    final file = File(path);
    if (!file.existsSync()) return ArchiveInfo(packs: <ArchivePack>[]);
    final stat = file.statSync();
    final cached = _cache[path];
    if (cached != null &&
        cached.size == stat.size &&
        cached.mtime == stat.modified.millisecondsSinceEpoch) {
      return cached.info;
    }
    final info = _read(path);
    _cache[path] = _CacheEntry(stat.size, stat.modified.millisecondsSinceEpoch, info);
    return info;
  }

  /// Backwards-compatible helper: just the packs.
  static List<ArchivePack> probe(String path) => inspect(path).packs;

  static Archive? _decode(String path) {
    try {
      return ZipDecoder().decodeBytes(File(path).readAsBytesSync());
    } catch (_) {
      return null;
    }
  }

  static ArchiveInfo _read(String path) {
    final archive = _decode(path);
    if (archive == null) return ArchiveInfo(packs: <ArchivePack>[]);

    final packs = <ArchivePack>[];
    Uint8List? icon;
    var iconIsRoot = false;

    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (name.startsWith('__MACOSX/')) continue;
      final lower = name.toLowerCase();

      if (lower.endsWith('manifest.json')) {
        final manifest = _parse(utf8.decode(entry.content as List<int>, allowMalformed: true));
        if (manifest == null) continue;
        final header = manifest['header'];
        if (header is! Map) continue;
        final uuid = header['uuid'];
        if (uuid is! String || uuid.trim().isEmpty) continue;
        final prefix = name.substring(0, name.length - 'manifest.json'.length);
        packs.add(ArchivePack(
          prefix: prefix,
          uuid: uuid.trim().toLowerCase(),
          deps: _deps(manifest),
          kind: _kind(manifest, prefix),
          name: '${header['name'] ?? ''}',
          description: '${header['description'] ?? ''}',
        ));
      } else if (lower.endsWith('pack_icon.png')) {
        final bytes = entry.content as List<int>;
        if (bytes.length > 2 * 1024 * 1024) continue;
        final atRoot = !name.contains('/');
        // Prefer the shallowest icon, otherwise keep the first one seen.
        if (icon == null || (atRoot && !iconIsRoot)) {
          icon = Uint8List.fromList(bytes);
          iconIsRoot = atRoot;
        }
      }
    }

    final descriptions = <String>[];
    for (final pack in packs) {
      final resolved = _resolveDescription(archive, pack);
      if (resolved.isNotEmpty && !descriptions.contains(resolved)) {
        descriptions.add(resolved);
      }
    }
    return ArchiveInfo(packs: packs, icon: icon, description: descriptions.join('  |  '));
  }

  static String _resolveDescription(Archive archive, ArchivePack pack) {
    final raw = pack.description.trim();
    if (raw.isEmpty) return '';
    // Already readable text.
    if (!RegExp(r'^[A-Za-z][\w.]*(\.[\w]+)+$').hasMatch(raw)) return raw;
    // Otherwise it is a lang key: look it up next to the pack.
    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (!name.startsWith('${pack.prefix}texts/')) continue;
      if (!name.toLowerCase().endsWith('.lang')) continue;
      final text = utf8.decode(entry.content as List<int>, allowMalformed: true);
      for (final line in text.split('\n')) {
        if (line.startsWith('$raw=')) {
          final value = line.substring(raw.length + 1).trim();
          if (value.isNotEmpty) return value;
        }
      }
    }
    return raw;
  }

  static Map<String, dynamic>? _parse(String text) {
    try {
      final decoded = Fsx.loadsJsonc(text.replaceFirst('\uFEFF', ''));
      return decoded is Map<String, dynamic> ? decoded : null;
    } catch (_) {
      return null;
    }
  }

  static Set<String> _deps(Map manifest) {
    final out = <String>{};
    final raw = manifest['dependencies'];
    final list = raw is List ? raw : (raw is Map ? <dynamic>[raw] : const <dynamic>[]);
    for (final d in list) {
      if (d is Map && d['uuid'] is String) {
        out.add((d['uuid'] as String).trim().toLowerCase());
      }
    }
    return out;
  }

  static String _kind(Map manifest, String prefix) {
    final modules = manifest['modules'];
    if (modules is List) {
      for (final m in modules) {
        if (m is Map) {
          if (m['type'] == 'data') return 'BP';
          if (m['type'] == 'resources') return 'RP';
        }
      }
    }
    final lower = prefix.toLowerCase();
    if (lower.contains('behavior') || lower.contains('bp')) return 'BP';
    if (lower.contains('resource') || lower.contains('rp')) return 'RP';
    return 'RP';
  }

  /// Extracts the archive into [destDir]; returns the directory that holds the
  /// pack folders.
  static String extract(String archivePath, String destDir) {
    final archive = _decode(archivePath);
    final root = Directory(destDir)..createSync(recursive: true);
    if (archive == null) return root.path;

    for (final entry in archive.files) {
      if (!entry.isFile) continue;
      final name = entry.name.replaceAll('\\', '/');
      if (name.startsWith('__MACOSX/')) continue;
      if (name.split('/').any((seg) => seg == '..' || seg == '.')) continue;
      final target = File(p.join(root.path, name));
      final data = entry.content as List<int>;
      target.parent.createSync(recursive: true);
      target.writeAsBytesSync(Uint8List.fromList(data), flush: true);
    }
    return root.path;
  }
}
