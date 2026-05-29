import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AppSettingsService extends ChangeNotifier {
  static final AppSettingsService instance = AppSettingsService._();

  AppSettingsService._();

  static const aspectOriginal = 'original';
  static const aspectFourThree = 'four_three';
  static const aspectStretch = 'stretch';

  static const _hapticFeedbackKey = 'settings.haptic_feedback';
  static const _buttonFeedbackKey = 'settings.button_feedback';
  static const _displayAspectRatioKey = 'settings.display_aspect_ratio';
  static const _displayBrightnessKey = 'settings.display_brightness';
  static const _networkEnabledKey = 'settings.network_enabled';
  static const _networkPortKey = 'settings.network_port';

  SharedPreferences? _prefs;

  bool _hapticFeedbackEnabled = true;
  bool _buttonFeedbackEnabled = false;
  String _displayAspectRatio = aspectOriginal;
  double _displayBrightness = 1;
  bool _networkEnabled = true;
  int _networkPort = 7845;

  bool get hapticFeedbackEnabled => _hapticFeedbackEnabled;
  bool get buttonFeedbackEnabled => _buttonFeedbackEnabled;
  String get displayAspectRatio => _displayAspectRatio;
  double get displayBrightness => _displayBrightness;
  bool get networkEnabled => _networkEnabled;
  int get networkPort => _networkPort;

  Future<void> init() async {
    _prefs ??= await SharedPreferences.getInstance();
    _hapticFeedbackEnabled = _prefs!.getBool(_hapticFeedbackKey) ?? true;
    _buttonFeedbackEnabled = _prefs!.getBool(_buttonFeedbackKey) ?? false;
    _displayAspectRatio =
        _prefs!.getString(_displayAspectRatioKey) ?? aspectOriginal;
    _displayBrightness = _prefs!.getDouble(_displayBrightnessKey) ?? 1;
    _networkEnabled = _prefs!.getBool(_networkEnabledKey) ?? true;
    _networkPort = _prefs!.getInt(_networkPortKey) ?? 7845;
  }

  Future<void> setHapticFeedbackEnabled(bool value) async {
    _hapticFeedbackEnabled = value;
    await _prefs?.setBool(_hapticFeedbackKey, value);
    notifyListeners();
  }

  Future<void> setButtonFeedbackEnabled(bool value) async {
    _buttonFeedbackEnabled = value;
    await _prefs?.setBool(_buttonFeedbackKey, value);
    notifyListeners();
  }

  Future<void> setDisplayAspectRatio(String value) async {
    _displayAspectRatio = value;
    await _prefs?.setString(_displayAspectRatioKey, value);
    notifyListeners();
  }

  Future<void> setDisplayBrightness(double value) async {
    _displayBrightness = value.clamp(0.5, 1.5);
    await _prefs?.setDouble(_displayBrightnessKey, _displayBrightness);
    notifyListeners();
  }

  Future<void> setNetworkEnabled(bool value) async {
    _networkEnabled = value;
    await _prefs?.setBool(_networkEnabledKey, value);
    notifyListeners();
  }

  Future<void> setNetworkPort(int value) async {
    _networkPort = value.clamp(1024, 65535);
    await _prefs?.setInt(_networkPortKey, _networkPort);
    notifyListeners();
  }
}
