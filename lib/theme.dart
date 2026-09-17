import 'package:flutter/material.dart';

// Evide brand palette (matched to the logo).
class AppColors {
  static const ink = Color(0xFF202B49);
  static const inkSoft = Color(0xFF44506E);
  static const inkFaint = Color(0xFF8791A6);
  static const paper = Color(0xFFF6F7F9);
  static const surface = Color(0xFFFFFFFF);
  static const line = Color(0xFFE3E7EC);
  static const accent = Color(0xFF0D6DED);
  static const accentSoft = Color(0xFFEAF1FE);
  static const amber = Color(0xFFF5BD2A);
  static const amberSoft = Color(0xFFFDF4DC);
  static const go = Color(0xFF1F8A54);
  static const goSoft = Color(0xFFE4F3EA);
  static const stop = Color(0xFFC0392B);
  static const stopSoft = Color(0xFFFBE9E7);
}

ThemeData buildTheme() {
  return ThemeData(
    useMaterial3: true,
    scaffoldBackgroundColor: AppColors.paper,
    colorScheme: ColorScheme.fromSeed(seedColor: AppColors.accent, primary: AppColors.accent),
    fontFamily: 'Roboto',
    appBarTheme: const AppBarTheme(
      backgroundColor: AppColors.ink,
      foregroundColor: Colors.white,
      elevation: 0,
      centerTitle: false,
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: AppColors.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.line),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppColors.accent, width: 1.5),
      ),
    ),
  );
}
