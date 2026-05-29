import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Visual theme for on-screen controls (colors, shadows, label fonts).
class GamepadSkin {
  const GamepadSkin({
    required this.id,
    required this.name,
    required this.joystickRing,
    required this.joystickInner,
    required this.joystickKnob,
    required this.joystickActiveBorder,
    required this.barButtonFill,
    required this.barButtonPressed,
    required this.barLabel,
    required this.panelTint,
    this.colorA = AppColors.primary,
    this.colorADark = AppColors.primaryContainer,
    this.colorB = AppColors.secondary,
    this.colorBDark = AppColors.secondaryContainer,
    this.colorX = const Color(0xFF4DA3FF),
    this.colorXDark = const Color(0xFF2B6CB0),
    this.colorY = const Color(0xFFFFB020),
    this.colorYDark = const Color(0xFFC77800),
    this.colorShoulder = AppColors.surfaceContainerHigh,
    this.colorShoulderDark = AppColors.surfaceContainer,
    this.labelFontFamily,
    this.actionLabelFontFamily,
  });

  final String id;
  final String name;
  final List<Color> joystickRing;
  final Color joystickInner;
  final List<Color> joystickKnob;
  final Color joystickActiveBorder;
  final Color barButtonFill;
  final Color barButtonPressed;
  final Color barLabel;
  final Color panelTint;
  final Color colorA;
  final Color colorADark;
  final Color colorB;
  final Color colorBDark;
  final Color colorX;
  final Color colorXDark;
  final Color colorY;
  final Color colorYDark;
  final Color colorShoulder;
  final Color colorShoulderDark;
  final String? labelFontFamily;
  final String? actionLabelFontFamily;

  Color faceButtonColor(String label) {
    switch (label) {
      case 'A':
        return colorA;
      case 'B':
        return colorB;
      case 'X':
        return colorX;
      case 'Y':
        return colorY;
      case 'L':
      case 'R':
        return colorShoulder;
      default:
        return colorA;
    }
  }

  Color faceButtonDark(String label) {
    switch (label) {
      case 'A':
        return colorADark;
      case 'B':
        return colorBDark;
      case 'X':
        return colorXDark;
      case 'Y':
        return colorYDark;
      case 'L':
      case 'R':
        return colorShoulderDark;
      default:
        return colorADark;
    }
  }

  Color faceButtonText(String label) {
    switch (label) {
      case 'B':
        return AppColors.onSecondary;
      case 'L':
      case 'R':
        return AppColors.onSurface;
      default:
        return AppColors.onPrimary;
    }
  }
}

class GamepadSkins {
  GamepadSkins._();

  static const classic = GamepadSkin(
    id: 'classic',
    name: '经典紫',
    joystickRing: [
      AppColors.surfaceContainerHighest,
      AppColors.surfaceContainer,
      AppColors.surfaceContainerLowest,
    ],
    joystickInner: AppColors.surfaceContainerLow,
    joystickKnob: [
      AppColors.primary,
      AppColors.primaryContainer,
      AppColors.surfaceContainerHighest,
    ],
    joystickActiveBorder: AppColors.primary,
    barButtonFill: AppColors.surfaceBright,
    barButtonPressed: AppColors.surfaceContainerHighest,
    barLabel: AppColors.onSurface,
    panelTint: Color(0xFF1A1920),
  );

  static const midnight = GamepadSkin(
    id: 'midnight',
    name: '午夜黑',
    joystickRing: [
      Color(0xFF2A2A32),
      Color(0xFF1E1E24),
      Color(0xFF121218),
    ],
    joystickInner: Color(0xFF18181E),
    joystickKnob: [
      Color(0xFF8B86FF),
      Color(0xFF5C56CC),
      Color(0xFF2E2A55),
    ],
    joystickActiveBorder: Color(0xFF9D97FF),
    barButtonFill: Color(0xFF2E2E36),
    barButtonPressed: Color(0xFF1A1A22),
    barLabel: Color(0xFFD8D4E8),
    panelTint: Color(0xFF0C0C10),
    colorA: Color(0xFF8B86FF),
    colorADark: Color(0xFF5C56CC),
    colorB: Color(0xFF6E6A88),
    colorBDark: Color(0xFF454258),
  );

  static const neon = GamepadSkin(
    id: 'neon',
    name: '霓虹绿',
    joystickRing: [
      Color(0xFF1A2A24),
      Color(0xFF122018),
      Color(0xFF0A1410),
    ],
    joystickInner: Color(0xFF142820),
    joystickKnob: [
      Color(0xFF00FFAB),
      Color(0xFF00C987),
      Color(0xFF006B47),
    ],
    joystickActiveBorder: Color(0xFF00FFAB),
    barButtonFill: Color(0xFF1E2E28),
    barButtonPressed: Color(0xFF122018),
    barLabel: Color(0xFFB8F5DC),
    panelTint: Color(0xFF0A1210),
    colorA: Color(0xFF00FFAB),
    colorADark: Color(0xFF00B87A),
    colorB: Color(0xFF4DA3FF),
    colorBDark: Color(0xFF2B6CB0),
  );

  static const all = [classic, midnight, neon];

  static GamepadSkin byId(String id) {
    return all.firstWhere(
      (s) => s.id == id,
      orElse: () => classic,
    );
  }
}
