import 'dart:io';

import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';

import 'app.dart';
import 'core/config.dart';
import 'theme.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await _ensureStorageAccess();
  final config = await HubConfig.load();
  runApp(ArcLocalizerApp(config: config));
}

/// Android 11+ blocks other apps from reading `com.mojang` unless "all files"
/// access is granted, so ask for it once at startup. Windows needs nothing.
Future<void> _ensureStorageAccess() async {
  if (!Platform.isAndroid) return;
  try {
    if (await Permission.manageExternalStorage.isGranted) return;
    final status = await Permission.manageExternalStorage.request();
    if (status.isGranted) return;
    // Android 10 and below expose the legacy permission instead.
    if (await Permission.storage.isDenied) {
      await Permission.storage.request();
    }
  } catch (_) {
    // Permission prompts are best-effort; scanning reports problems itself.
  }
}

class ArcLocalizerApp extends StatelessWidget {
  const ArcLocalizerApp({super.key, required this.config});

  final HubConfig config;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: appTitle,
      debugShowCheckedModeBanner: false,
      theme: AppTheme.build(Brightness.light),
      darkTheme: AppTheme.build(Brightness.dark),
      themeMode: ThemeMode.system,
      home: HubApp(config: config),
    );
  }
}
