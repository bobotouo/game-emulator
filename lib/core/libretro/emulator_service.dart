import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';
import '../storage/storage_paths_service.dart';
import '../audio/audio_debug.dart';
import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import 'libretro_core.dart';

/// Emulator service managing the core lifecycle
class EmulatorService {
  LibretroCore? _core;
  bool _running = false;
  bool _paused = false;
  int _speed = 1;

  // Performance tracking (read from native frame counter)
  double _currentFps = 0;
  int _lastFrameCount = 0;
  DateTime _lastFpsUpdate = DateTime.now();
  Timer? _fpsTracker;

  // State
  String? _currentRomPath;
  String? _currentGameId;
  Uint8List? _lastSaveState;

  // Getters
  bool get isRunning => _running;
  bool get isPaused => _paused;
  double get currentFps => _currentFps;
  int get frameCount => _readFrameCounter();
  int get speed => _speed;
  int get baseWidth => _core?.baseWidth ?? 240;
  int get baseHeight => _core?.baseHeight ?? 160;
  String? get currentRomPath => _currentRomPath;
  LibretroCore? get core => _core;

  set speed(int value) {
    final clamped = value.clamp(1, 5);
    if (_speed == clamped) return;
    _speed = clamped;
    if (_running) {
      emu_loop.setEmulationSpeed(clamped);
    }
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
    if (Platform.isIOS) {
      final deviceHz = emu_loop.prepareAudioOutputRate(48000);
      // mGBA libretro has mAudioResampler — resample inside the core to device rate.
      final targetHz = deviceHz.round().clamp(8000, 192000);
      emu_loop.setTargetSampleRate(targetHz);
      logAudio('before loadGame: device=$deviceHz Hz mGBA_target=$targetHz (core resamples)');
    }
    final success = _core!.loadGame(romPath);
    if (!success) return false;

    logAudio(
      'after loadGame: core.sampleRate=${_core!.sampleRate} '
      'reported=${emu_loop.getReportedSampleRate()} fps=${_core!.fps}',
    );

    _currentRomPath = romPath;
    _currentGameId = gameId;
    _lastSaveState = null;

    final restored = await _restoreSaveStateFromDisk();
    debugPrint(
      restored
          ? 'Save state restored for $romPath'
          : 'No save state restored for $romPath (gameId=$gameId)',
    );

    // Warm up on a native thread — never call retro_run on the Dart isolate.
    final runPtr = _core!.retroRunPtr;
    if (!restored) {
      emu_loop.runSyncFrames(runPtr, 2);
    } else {
      emu_loop.runSyncFrames(runPtr, 1);
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
    if (Platform.isIOS) {
      final deviceHz = emu_loop.prepareAudioOutputRate(48000);
      final targetHz = deviceHz.round().clamp(8000, 192000);
      emu_loop.setTargetSampleRate(targetHz);
      logAudio('before loadGameFromBytes: device=$deviceHz Hz mGBA_target=$targetHz');
    }
    final success = _core!.loadGameFromBytes(romBytes, path);
    if (success) {
      _currentRomPath = path;
      _startGameLoop();
    }
    return success;
  }

  void startGameLoop() {
    if (_core == null || _running) return;

    final core = _core!;
    final fps = core.fps > 0 ? core.fps : 59.73;

    // Switch core to pure-C callbacks so retro_run is safe on a non-Dart thread.
    core.switchToNativeCallbacks();

    _running = true;
    _paused = false;
    _lastFpsUpdate = DateTime.now();
    _lastFrameCount = _readFrameCounter();

    // Start the native loop (platform-specific: GCD on iOS, pthread on Android).
    emu_loop.setEmulationSpeed(_speed);
    emu_loop.startNativeLoop(core.retroRunPtr, fps);

    // FPS: on iOS count presented frames (CADisplayLink), else retro_run count.
    _fpsTracker?.cancel();
    _fpsTracker = Timer.periodic(const Duration(seconds: 1), (_) {
      final now = DateTime.now();
      final elapsed = now.difference(_lastFpsUpdate).inMilliseconds;
      if (elapsed > 0) {
        final fc = _readFrameCounter();
        _currentFps = (fc - _lastFrameCount) * 1000.0 / elapsed;
        _lastFrameCount = fc;
        _lastFpsUpdate = now;
      }
    });
  }

  int _readFrameCounter() {
    if (Platform.isIOS) {
      return emu_loop.nativePresentedFrameCount();
    }
    return emu_loop.nativeFrameCount();
  }

  void _startGameLoop() => startGameLoop();

  void pause() {
    _paused = true;
    emu_loop.setLoopPaused(true);
  }

  void resume() {
    if (!_running) return;
    _paused = false;
    emu_loop.setLoopPaused(false);
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

    final runPtr = _core?.retroRunPtr;
    for (var attempt = 0; attempt < 6; attempt++) {
      if (attempt > 0 && runPtr != null) {
        emu_loop.runSyncFrames(runPtr, 1);
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

  // These setters are no-ops: all callbacks are now pure-C and thread-safe.
  // ignore: avoid_unused_parameters
  void setVideoCallback(VideoCallback callback) {}
  // ignore: avoid_unused_parameters
  void setAudioCallback(AudioCallback? callback) {}
  // ignore: avoid_unused_parameters
  void setInputPollCallback(InputPollCallback callback) {}

  /// Stop the emulator
  void stop() {
    _fpsTracker?.cancel();
    _fpsTracker = null;
    emu_loop.stopNativeLoop();
    emu_loop.clearInputs();
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
