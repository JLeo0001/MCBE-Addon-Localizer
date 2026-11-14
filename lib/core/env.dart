import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:url_launcher/url_launcher.dart';

/// Platform paths and shell integration.
class Env {
  static const List<MapEntry<String, String>> packRoots = <MapEntry<String, String>>[
    MapEntry('behavior_packs', 'BP'),
    MapEntry('development_behavior_packs', 'BP'),
    MapEntry('resource_packs', 'RP'),
    MapEntry('development_resource_packs', 'RP'),
  ];

  static bool get isWindows => Platform.isWindows;
  static bool get isAndroid => Platform.isAndroid;

  /// `%APPDATA%\Minecraft Bedrock\Users\Shared\games\com.mojang` on Windows.
  static String minecraftBaseDir() {
    if (isWindows) {
      final appData = Platform.environment['APPDATA'] ??
          p.join(Platform.environment['USERPROFILE'] ?? '', 'AppData', 'Roaming');
      return p.join(appData, 'Minecraft Bedrock', 'Users', 'Shared', 'games', 'com.mojang');
    }
    return '/storage/emulated/0/Android/data/com.mojang.minecraftpe/files/games/com.mojang';
  }

  static String resolveModsBase(String? custom) {
    final raw = (custom ?? '').trim();
    return raw.isEmpty ? minecraftBaseDir() : raw;
  }

  /// Returns null for blank paths or paths that are not directories.
  static String? resolvePackDir(String? raw) {
    final s = (raw ?? '').trim();
    if (s.isEmpty) return null;
    final dir = Directory(s);
    return dir.existsSync() ? dir.path : null;
  }

  /// Opens a directory in the OS file manager.
  ///
  /// Windows uses Explorer directly: `url_launcher` has no file-URI handler
  /// there, and its failure used to surface as "打开文件夹失败".
  static Future<void> openFolder(String path) async {
    final dir = Directory(path);
    if (!dir.existsSync()) {
      throw FileSystemException('目录不存在', path);
    }
    if (isWindows) {
      await Process.start('explorer', <String>[dir.path], mode: ProcessStartMode.detached);
      return;
    }
    if (isAndroid) {
      try {
        await launchUrl(Uri.file(dir.path), mode: LaunchMode.externalApplication);
      } catch (e) {
        throw FileSystemException('系统没有可用于打开目录的应用', dir.path);
      }
      return;
    }
    await launchUrl(Uri.directory(dir.path));
  }

  static Future<void> openUrl(String url) async {
    final uri = Uri.parse(url);
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  /// Default export directory: <home>/Downloads, falling back to documents.
  static String defaultExportDir() {
    if (isWindows) {
      final home = Platform.environment['USERPROFILE'] ?? '';
      if (home.isNotEmpty) return p.join(home, 'Downloads');
    }
    final home = Platform.environment['HOME'] ?? '';
    if (home.isNotEmpty) return p.join(home, 'Downloads');
    return Directory.current.path;
  }
}
