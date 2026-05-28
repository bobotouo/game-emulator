import 'package:flutter/material.dart';

class AppColors {
  // Primary - Indigo
  static const primary = Color(0xFF6150B1);
  static const primaryContainer = Color(0xFF483697);
  static const onPrimary = Color(0xFFFFFFFF);
  static const onPrimaryContainer = Color(0xFFDDD4FF);

  // Secondary - Mint Green
  static const secondary = Color(0xFF00FFAB);
  static const secondaryContainer = Color(0xFF00E297);
  static const onSecondary = Color(0xFF003822);
  static const onSecondaryContainer = Color(0xFF007149);

  // Tertiary
  static const tertiary = Color(0xFFC6C4DB);
  static const tertiaryContainer = Color(0xFF5E5D71);

  // Surface & Background
  static const background = Color(0xFF131318);
  static const surface = Color(0xFF131318);
  static const surfaceDim = Color(0xFF131318);
  static const surfaceBright = Color(0xFF39393E);
  static const surfaceContainerLowest = Color(0xFF0E0E13);
  static const surfaceContainerLow = Color(0xFF1B1B20);
  static const surfaceContainer = Color(0xFF1F1F24);
  static const surfaceContainerHigh = Color(0xFF2A292F);
  static const surfaceContainerHighest = Color(0xFF35343A);
  static const surfaceVariant = Color(0xFF35343A);

  // Text
  static const onSurface = Color(0xFFE4E1E9);
  static const onSurfaceVariant = Color(0xFFC9C4D4);
  static const onBackground = Color(0xFFE4E1E9);

  // Outline
  static const outline = Color(0xFF938F9D);
  static const outlineVariant = Color(0xFF484552);

  // Error
  static const error = Color(0xFFFFB4AB);
  static const errorContainer = Color(0xFF93000A);
  static const onError = Color(0xFF690005);
  static const onErrorContainer = Color(0xFFFFDAD6);

  // Surface Tint
  static const surfaceTint = Color(0xFFCABEFF);
}

class AppTypography {
  // System monospace font family
  static const String _monospace = 'monospace';
  static const String _sansSerif = 'sans-serif';

  static TextTheme get textTheme {
    return TextTheme(
      displayLarge: TextStyle(
        fontFamily: _monospace,
        fontSize: 32,
        fontWeight: FontWeight.w700,
        height: 1.2,
        letterSpacing: -0.04,
      ),
      headlineMedium: TextStyle(
        fontFamily: _monospace,
        fontSize: 24,
        fontWeight: FontWeight.w700,
        height: 1.3,
      ),
      headlineSmall: TextStyle(
        fontFamily: _monospace,
        fontSize: 20,
        fontWeight: FontWeight.w700,
        height: 1.4,
      ),
      bodyLarge: TextStyle(
        fontFamily: _sansSerif,
        fontSize: 16,
        fontWeight: FontWeight.w400,
        height: 1.6,
      ),
      bodyMedium: TextStyle(
        fontFamily: _sansSerif,
        fontSize: 14,
        fontWeight: FontWeight.w400,
        height: 1.6,
      ),
      labelLarge: TextStyle(
        fontFamily: _monospace,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        height: 1,
        letterSpacing: 0.1,
      ),
    );
  }
}

class AppTheme {
  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: AppColors.primary,
        onPrimary: AppColors.onPrimary,
        primaryContainer: AppColors.primaryContainer,
        onPrimaryContainer: AppColors.onPrimaryContainer,
        secondary: AppColors.secondary,
        onSecondary: AppColors.onSecondary,
        secondaryContainer: AppColors.secondaryContainer,
        onSecondaryContainer: AppColors.onSecondaryContainer,
        tertiary: AppColors.tertiary,
        tertiaryContainer: AppColors.tertiaryContainer,
        surface: AppColors.surface,
        onSurface: AppColors.onSurface,
        onSurfaceVariant: AppColors.onSurfaceVariant,
        error: AppColors.error,
        onError: AppColors.onError,
        errorContainer: AppColors.errorContainer,
        onErrorContainer: AppColors.onErrorContainer,
        outline: AppColors.outline,
        outlineVariant: AppColors.outlineVariant,
        surfaceContainerHighest: AppColors.surfaceContainerHighest,
      ),
      scaffoldBackgroundColor: AppColors.background,
      textTheme: AppTypography.textTheme,
      appBarTheme: const AppBarTheme(
        backgroundColor: AppColors.surface,
        foregroundColor: AppColors.onSurface,
        elevation: 0,
      ),
      cardTheme: CardThemeData(
        color: AppColors.surfaceContainer,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.outlineVariant, width: 1),
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          backgroundColor: AppColors.primary,
          foregroundColor: AppColors.onPrimary,
          elevation: 0,
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: AppColors.surfaceContainerLow,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.outlineVariant),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.outlineVariant),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: const BorderSide(color: AppColors.primary, width: 2),
        ),
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: AppColors.surfaceContainerLow,
        selectedItemColor: AppColors.primary,
        unselectedItemColor: AppColors.onSurfaceVariant,
        type: BottomNavigationBarType.fixed,
      ),
    );
  }
}
