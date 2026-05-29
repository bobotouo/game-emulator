import 'dart:io';

import 'package:flutter/services.dart';
import 'package:vibration/vibration.dart';

import '../settings/app_settings_service.dart';

/// Centralized haptic feedback, gated by user settings.
class HapticService {
  HapticService._();

  static final HapticService instance = HapticService._();

  final AppSettingsService _settings = AppSettingsService.instance;

  DateTime? _lastGameRumble;
  bool? _hasVibrator;

  Future<bool> get _canVibrate async {
    if (!Platform.isAndroid) return false;
    _hasVibrator ??= await Vibration.hasVibrator();
    return _hasVibrator == true;
  }

  /// Virtual gamepad action buttons (A / B).
  Future<void> buttonPress() async {
    if (!_settings.buttonFeedbackEnabled) return;
    await _vibrate(duration: 20, amplitude: 180);
  }

  /// D-pad, Start, Select and other secondary controls.
  Future<void> selectionClick() async {
    if (!_settings.buttonFeedbackEnabled) return;
    await _vibrate(duration: 12, amplitude: 120);
  }

  /// Libretro core rumble events (e.g. Game Boy Player shake).
  Future<void> gameRumble(int strength, {required bool strong}) async {
    if (!_settings.hapticFeedbackEnabled || strength <= 0) return;

    final now = DateTime.now();
    if (_lastGameRumble != null &&
        now.difference(_lastGameRumble!).inMilliseconds < 80) {
      return;
    }
    _lastGameRumble = now;

    final normalized = strength / 65535.0;
    if (Platform.isAndroid) {
      final duration = strong || normalized > 0.65
          ? 45
          : normalized > 0.25
          ? 28
          : 16;
      final amplitude = (normalized * 255).round().clamp(80, 255);
      await _vibrate(duration: duration, amplitude: amplitude);
      return;
    }

    if (strong || normalized > 0.65) {
      HapticFeedback.heavyImpact();
    } else if (normalized > 0.25) {
      HapticFeedback.mediumImpact();
    } else {
      HapticFeedback.lightImpact();
    }
  }

  Future<void> _vibrate({required int duration, required int amplitude}) async {
    if (Platform.isAndroid && await _canVibrate) {
      final hasAmplitude = await Vibration.hasAmplitudeControl();
      if (hasAmplitude == true) {
        await Vibration.vibrate(duration: duration, amplitude: amplitude);
      } else {
        await Vibration.vibrate(duration: duration);
      }
      return;
    }

    HapticFeedback.mediumImpact();
  }
}
