import 'package:flutter/material.dart';

ThemeData buildMaxDesktopTheme() {
  return ThemeData(
    useMaterial3: true,
    brightness: Brightness.dark,
    colorScheme: ColorScheme.fromSeed(
      seedColor: const Color(0xFF5B8DEF),
      brightness: Brightness.dark,
    ),
    listTileTheme: ListTileThemeData(
      tileColor: ColorScheme.fromSeed(
        seedColor: const Color(0xFF5B8DEF),
        brightness: Brightness.dark,
      ).surfaceContainerHighest.withValues(alpha: 0.35),
    ),
  );
}
