import 'dart:typed_data';

/// A resource / behavior pack discovered on disk.
class PackInfo {
  PackInfo({
    required this.path,
    required this.kind,
    required this.uuid,
    required this.depUuids,
    required this.displayName,
  });

  final String path; // absolute path
  final String kind; // "RP" | "BP"
  final String uuid;
  final Set<String> depUuids;
  final String displayName;
}

/// One selectable mod entry: resource pack, behavior pack, both paired, or an
/// archive (`.mcpack` / `.mcaddon`) that is unpacked on demand.
class ModEntry {
  ModEntry({
    required this.name,
    this.resourcePack,
    this.behaviorPack,
    this.archive,
    this.archiveHasRp = false,
    this.archiveHasBp = false,
    this.description = '',
    this.iconBytes,
  });

  final String name;
  final String? resourcePack;
  final String? behaviorPack;

  /// Set when the mod was discovered as a `.mcpack` / `.mcaddon` / `.zip`.
  final String? archive;
  final bool archiveHasRp;
  final bool archiveHasBp;

  /// Pack description (from `manifest.header.description` or its lang key).
  final String description;

  /// `pack_icon.png` bytes, read straight out of the archive when possible.
  final Uint8List? iconBytes;

  bool get isArchive => archive != null && archive!.isNotEmpty;

  bool get hasRp => isArchive ? archiveHasRp : (resourcePack != null && resourcePack!.isNotEmpty);
  bool get hasBp => isArchive ? archiveHasBp : (behaviorPack != null && behaviorPack!.isNotEmpty);

  List<String> packPaths() => <String>[
    if (!isArchive && hasRp) resourcePack!,
    if (!isArchive && hasBp) behaviorPack!,
  ];

  String get packLabel {
    if (hasRp && hasBp) return 'RP+BP';
    if (hasRp) return 'RP';
    if (hasBp) return 'BP';
    return '?';
  }
}

/// A planned folder rename for a pack directory.
class RenamePlan {
  RenamePlan({
    required this.src,
    required this.dest,
    required this.displayName,
    required this.suffix,
    this.skipped = false,
    this.reason = '',
  });

  final String src;
  final String dest;
  final String displayName;
  final String suffix;
  final bool skipped;
  final String reason;

  bool get changed => !skipped && src != dest;
}

/// A text region found by OCR inside one image.
class ImageRegion {
  ImageRegion({
    required this.left,
    required this.top,
    required this.right,
    required this.bottom,
    required this.text,
    required this.score,
  });

  final int left;
  final int top;
  final int right;
  final int bottom;
  final String text;
  final double score;

  int get width => right - left;
  int get height => bottom - top;

  String translation = '';
  int textColor = 0xFF000000; // ARGB
  int bgColor = 0xFFFFFFFF;
  String get output => translation.trim().isEmpty ? text : translation;
}

class UploadResult {
  UploadResult({required this.remoteId, required this.remoteLabel, this.extra = const {}});
  final String remoteId;
  final String remoteLabel;
  final Map<String, dynamic> extra;
}

class ShareResult {
  ShareResult({required this.url, this.password = ''});
  final String url;
  final String password;
}

class PublishResult {
  PublishResult({
    required this.driverId,
    required this.driverName,
    this.uploaded,
    this.share,
    this.error = '',
  });

  final String driverId;
  final String driverName;
  final UploadResult? uploaded;
  final ShareResult? share;
  final String error;

  bool get ok => error.isEmpty && uploaded != null;

  String summary() {
    if (error.isNotEmpty) return '$driverName · 失败error';
    final label = uploaded?.remoteLabel ?? '';
    final url = share?.url ?? '';
    final pwd = (share?.password ?? '').isEmpty ? '' : '  提取${share!.password}';
    return '$driverName · $label${url.isEmpty ? '' : ' · $url'}$pwd';
  }
}

/// Byte buffer helper used by the zip writer.
class ZipEntryData {
  ZipEntryData(this.name, this.bytes);
  final String name;
  final Uint8List bytes;
}
