import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../storage/storage_paths_service.dart';
import 'libretro_core.dart';

/// Emulator service managing the core lifecycle
class EmulatorService {
  LibretroCore? _core;
  Timer? _frameTimer;
  bool _running = false;
  bool _paused = false;
  int _speed = 1;

  // Performance tracking
  int _frameCount = 0;
  double _currentFps = 0;
  DateTime _lastFpsUpdate = DateTime.now();

  // State
  String? _currentRomPath;
  String? _currentGameId;
  Uint8List? _lastSaveState;

  // Getters
  bool get isRunning => _running;
  bool get isPaused => _paused;
  double get currentFps => _currentFps;
  int get frameCount => _frameCount;
  int get speed => _speed;
  String? get currentRomPath => _currentRomPath;
  LibretroCore? get core => _core;

  set speed(int value) {
    final clamped = value.clamp(1, 5);
    if (_speed == clamped) return;
    _speed = clamped;
  }

  /// Initialize the emulator with a core file
  Future<bool> initialize(String corePath) async {
    _core = LibretroCore();
    return _core!.initialize(corePath);
  }

  /// Load and start a ROM, restoring auto-save if present.
  Future<bool> loadAndStart(
    String romPath, {
    String? gameId,
    bool startLoop = true,
  }) async {
    if (_core == null) return false;

    await _core!.prepareSaveDirectory();
    final success = _core!.loadGame(romPath);
    if (!success) return false;

    _currentRomPath = romPath;
    _currentGameId = gameId;
    _lastSaveState = null;

    final restored = await _restoreSaveStateFromDisk();
    debugPrint(
      restored
          ? 'Save state restored for $romPath'
          : 'No save state restored for $romPath (gameId=$gameId)',
    );

    if (!restored) {
      _core!.runFrame();
      _core!.runFrame();
    } else {
      _core!.runFrame();
    }

    if (startLoop) {
      startGameLoop();
    }
    return true;
  }

  /// Load from bytes and start
  Future<bool> loadFromBytesAndStart(Uint8List romBytes, String? path) async {
    if (_core == null) return false;

    await _core!.prepareSaveDirectory();
    final success = _core!.loadGameFromBytes(romBytes, path);
    if (success) {
      _currentRomPath = path;
      _startGameLoop();
    }
    return success;
  }

  void startGameLoop() {
    if (_core == null || _running) return;

    _frameTimer?.cancel();
    _running = true;
    _paused = false;
    _frameCount = 0;
    _lastFpsUpdate = DateTime.now();

    final fps = _core!.fps > 0 ? _core!.fps : 59.73;
    final frameDuration = Duration(microseconds: (1000000 / fps).round());

    _frameTimer = Timer.periodic(frameDuration, (_) {
      if (!_paused && _running && _core != null) {
        for (var i = 0; i < _speed; i++) {
          _core!.runFrame();
          _frameCount++;
        }
        _updateFps();
      }
    });
  }

  void _startGameLoop() => startGameLoop();

  void _updateFps() {
    final now = DateTime.now();
    final elapsed = now.difference(_lastFpsUpdate).inMilliseconds;

    if (elapsed >= 1000) {
      _currentFps = _frameCount * 1000.0 / elapsed;
      _frameCount = 0;
      _lastFpsUpdate = now;
    }
  }

  void pause() {
    _paused = true;
  }

  void resume() {
    if (!_running) return;
    _paused = false;
  }

  /// Toggle pause state
  void togglePause() {
    _paused = !_paused;
  }

  /// Reset the current game
  void reset() {
    _core?.reset();
  }

  /// Save state to disk.
  Future<Uint8List?> saveState() async {
    final state = _core?.saveState();
    if (state == null) {
      debugPrint('saveState: core returned null');
      return null;
    }

    _lastSaveState = state;

    final romPath = _currentRomPath;
    if (romPath != null) {
      await StoragePathsService.ensureStorageAccess();
      final file = await _getSaveStateFile(romPath);
      await file.writeAsBytes(state, flush: true);
      debugPrint('Save state written: ${file.path} (${state.length} bytes)');
    }

    return state;
  }

  /// Load state
  Future<bool> loadState(Uint8List state) async {
    if (state.isEmpty) return false;

    String? error;
    final loaded =
        _core?.loadState(state, onError: (message) => error = message) ?? false;
    if (!loaded && error != null) {
      debugPrint('loadState failed: $error');
    }
    return loaded;
  }

  /// Restore save state from disk for the current ROM.
  Future<bool> _restoreSaveStateFromDisk() async {
    final romPath = _currentRomPath;
    if (romPath == null) return false;

    final file = await StoragePathsService.findSaveStateFile(
      romPath,
      gameId: _currentGameId,
    );
    if (file == null || !await file.exists()) {
      debugPrint('Save state file not found for $romPath');
      return false;
    }

    final state = await file.readAsBytes();
    if (state.isEmpty) {
      debugPrint('Save state file is empty: ${file.path}');
      return false;
    }

    debugPrint(
      'Loading save state from ${file.path} (${state.length} bytes)',
    );

    for (var attempt = 0; attempt < 6; attempt++) {
      if (attempt > 0) {
        _core?.runFrame();
      }

      if (await loadState(state)) {
        _lastSaveState = state;
        return true;
      }
    }

    return false;
  }

  /// Load last save state from disk if available.
  Future<bool> loadLastState() async {
    if (_lastSaveState != null) {
      return loadState(_lastSaveState!);
    }
    return _restoreSaveStateFromDisk();
  }

  /// Auto-save before leaving the game.
  Future<void> autoSave() async {
    if (_currentRomPath == null || _core == null || !_core!.isGameLoaded) {
      return;
    }

    pause();
    _frameTimer?.cancel();
    _frameTimer = null;

    await saveState();
  }

  /// Auto-save then stop the emulator.
  Future<void> autoSaveAndStop() async {
    await autoSave();
    stop();
  }

  Future<File> _getSaveStateFile(String romPath) {
    final gameId = _currentGameId;
    if (gameId != null) {
      return StoragePathsService.saveStateFileForGame(
        gameId: gameId,
        romPath: romPath,
      );
    }
    return StoragePathsService.saveStateFileForRom(romPath);
  }

  /// Update input state
  void updateInput(Map<int, bool> state) {
    _core?.updateInput(state);
  }

  /// Set video callback
  void setVideoCallback(VideoCallback callback) {
    _core?.videoCallback = callback;
  }

  /// Set audio callback
  void setAudioCallback(AudioCallback? callback) {
    _core?.audioCallback = callback;
  }

  /// Set input poll callback
  void setInputPollCallback(InputPollCallback callback) {
    _core?.inputPollCallback = callback;
  }

  /// Stop the emulator
  void stop() {
    _frameTimer?.cancel();
    _frameTimer = null;
    _running = false;
    _paused = false;
    _speed = 1;
    setAudioCallback(null);
    _core?.unloadGame();
    _currentRomPath = null;
    _currentGameId = null;
  }

  /// Dispose resources
  void dispose() {
    stop();
    _core?.dispose();
    _core = null;
  }
}
