import 'package:flutter/material.dart';

/// Brand palette sampled from the original product icon.
class Brand {
  static const indigo = Color(0xFF24266D);
  static const violet = Color(0xFF5C256E);
  static const magenta = Color(0xFFA7205B);
  static const crimson = Color(0xFFCA1E54);
  static const pink = Color(0xFFE83467);

  static const gradient = LinearGradient(
    begin: Alignment.bottomLeft,
    end: Alignment.topRight,
    colors: [indigo, violet, crimson],
  );
}

class AppTheme {
  static ThemeData build(Brightness brightness) {
    final scheme = ColorScheme.fromSeed(
      seedColor: Brand.magenta,
      brightness: brightness,
    );
    final base = ThemeData(useMaterial3: true, colorScheme: scheme);
    return base.copyWith(
      visualDensity: VisualDensity.standard,
      scaffoldBackgroundColor: scheme.surface,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surfaceContainer,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        centerTitle: false,
      ),
      cardTheme: CardThemeData(
        elevation: 0,
        margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: scheme.outlineVariant),
        ),
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      inputDecorationTheme: const InputDecorationTheme(
        border: OutlineInputBorder(),
        isDense: true,
      ),
      snackBarTheme: SnackBarThemeData(behavior: SnackBarBehavior.floating),
    );
  }
}
