import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../storage/storage_paths_service.dart';
import '../audio/audio_debug.dart';
import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import 'emulator_core_resolver.dart';
import 'libretro_bindings.dart';

/// Callback types kept for API compatibility; no longer used in hot path.
typedef VideoCallback =
    void Function(Uint8List framebuffer, int width, int height, int pitch);
typedef AudioCallback = void Function(Int16List samples, int frames);
typedef InputPollCallback = void Function();

/// Libretro core wrapper
class LibretroCore {
  late LibretroBindings _bindings;
  bool _initialized = false;
  bool _gameLoaded = false;

  // System info
  String _coreName = '';
  String _coreVersion = '';
  int _baseWidth = 240;
  int _baseHeight = 160;
  double _geometryAspectRatio = 4 / 3;
  double _fps = 60.0;
  double _sampleRate = 32768.0;

  // Framebuffer (kept for non-native display fallback)
  Pointer<Uint8>? _framebuffer;
  Uint8List? _displayBuffer;
  int _framebufferSize = 0;

  // Input state (used by updateInput for legacy callers)
  final Map<int, bool> _inputState = {};

  Pointer<Utf8>? _saveDirectoryNative;

  /// FBNeo path-only loads keep [retro_game_info.path] for the whole session.
  Pointer<Utf8>? _romPathNative;

  EmulatorCoreConfig? _activeConfig;

  /// Get core info
  String get coreName => _coreName;
  String get coreVersion => _coreVersion;
  int get baseWidth => _baseWidth;
  int get baseHeight => _baseHeight;
  double get geometryAspectRatio => _geometryAspectRatio;
  double get fps => _fps;
  double get sampleRate => _sampleRate;
  bool get isInitialized => _initialized;
  bool get isGameLoaded => _gameLoaded;

  /// Native function pointer for retro_run – passed to the native game loop.
  Pointer<NativeFunction<retro_run_native>> get retroRunPtr =>
      _bindings.retroRunPtr;

  LibretroBindings get bindings => _bindings;

  int get serializeStateSize => _bindings.retroSerializeSize();

  /// Replace all hot-path libretro callbacks with pure-C implementations that
  /// are safe to call from a non-Dart thread. Call this AFTER retro_load_game.
  /// Install pure-C libretro callbacks. Safe to call from any thread.
  /// The C environment callback handles SET_PIXEL_FORMAT and GET_SAVE_DIRECTORY
  /// internally, so no Dart code is ever invoked on the native emulation thread.
  void switchToNativeCallbacks() {
    _bindings.retroSetVideoRefresh(emu_loop.getVideoCb());
    _bindings.retroSetAudioSample(emu_loop.getAudioSingleCb());
    _bindings.retroSetAudioSampleBatch(emu_loop.getAudioBatchCb());
    _bindings.retroSetInputPoll(emu_loop.getInputPollCb());
    _bindings.retroSetInputState(emu_loop.getInputStateCb());
    _bindings.retroSetEnvironment(emu_loop.getEnvCb());
  }

  /// Writes frames directly into this buffer (avoids an extra copy on the Dart side).
  void bindDisplayBuffer(Uint8List buffer) {
    _displayBuffer = buffer;
    _framebufferSize = buffer.length;
  }

  void unbindDisplayBuffer() {
    _displayBuffer = null;
  }

  /// Initialize the core
  bool initialize(String corePath) {
    try {
      _bindings = LibretroBindings(corePath);
      // Install pure-C callbacks BEFORE retro_init so the core never sees
      // Dart trampolines. The C environment callback handles SET_PIXEL_FORMAT
      // and GET_SAVE_DIRECTORY; all hot-path callbacks are safe for any thread.
      switchToNativeCallbacks();
      _bindings.retroInit();
      _initialized = true;

      // Query basic system info (name, version)
      _queryBasicInfo();

      return true;
    } catch (e) {
      print('Failed to initialize libretro core: $e');
      return false;
    }
  }

  void _queryBasicInfo() {
    final info = calloc<retro_system_info>();
    _bindings.retroGetSystemInfo(info);
    _coreName = info.ref.library_name.toDartString();
    _coreVersion = info.ref.library_version.toDartString();
    calloc.free(info);
  }

  /// Query AV info after game is loaded
  void _queryAvInfo() {
    final avInfo = calloc<retro_system_av_info>();
    _bindings.retroGetSystemAvInfo(avInfo);
    _baseWidth = avInfo.ref.geometry.base_width;
    _baseHeight = avInfo.ref.geometry.base_height;
    _geometryAspectRatio = avInfo.ref.geometry.aspect_ratio;
    if (_geometryAspectRatio <= 0 && _baseHeight > 0) {
      _geometryAspectRatio = _baseWidth / _baseHeight;
    }
    _fps = avInfo.ref.timing.fps;
    _sampleRate = avInfo.ref.timing.sample_rate;
    calloc.free(avInfo);

    logAudio(
      'retro_get_system_av_info: sampleRate=$_sampleRate fps=$_fps '
      'size=${_baseWidth}x$_baseHeight',
    );

    _framebufferSize = _baseWidth * _baseHeight * 4;
    if (_displayBuffer != null) {
      if (_displayBuffer!.length >= _framebufferSize) {
        return;
      }
      _displayBuffer = null;
    }

    if (_framebuffer != null) {
      calloc.free(_framebuffer!);
    }
    _framebuffer = calloc.allocate<Uint8>(_framebufferSize);
  }

  /// Load a ROM file using [config] (path-only for arcade / FBNeo).
  bool loadGame(String romPath, {required EmulatorCoreConfig config}) {
    if (!_initialized) return false;

    final file = File(romPath);
    if (!file.existsSync()) return false;

    _activeConfig = config;
    if (config.loadViaPathOnly) {
      return loadGameFromBytes(Uint8List(0), romPath, config: config);
    }

    final romBytes = file.readAsBytesSync();
    return loadGameFromBytes(romBytes, romPath, config: config);
  }

  /// Prepare libretro directories before [retro_load_game].
  Future<void> prepareForGame(String romPath, EmulatorCoreConfig config) async {
    _activeConfig = config;
    final saveDir = await StoragePathsService.getInGameSavesDirectory();
    if (_saveDirectoryNative != null) {
      malloc.free(_saveDirectoryNative!);
    }
    _saveDirectoryNative = saveDir.path.toNativeUtf8();
    emu_loop.setSaveDirectory(saveDir.path);

    final systemDir = await StoragePathsService.getSystemDirectory();
    emu_loop.setSystemDirectory(systemDir.path);

    final contentDir = await StoragePathsService.contentDirectoryForRom(
      romPath,
    );
    emu_loop.setContentDirectory(contentDir);
    if (config.system == EmulatorSystem.arcade) {
      print(
        'FBNeo paths: rom=$romPath system=${systemDir.path} content=$contentDir',
      );
    }
  }

  /// Prepare save directory path for libretro cores (battery saves).
  Future<void> prepareSaveDirectory() async {
    final dir = await StoragePathsService.getInGameSavesDirectory();
    if (_saveDirectoryNative != null) {
      malloc.free(_saveDirectoryNative!);
    }
    _saveDirectoryNative = dir.path.toNativeUtf8();
    emu_loop.setSaveDirectory(dir.path);
  }

  void _releaseRomPathNative() {
    if (_romPathNative != null) {
      malloc.free(_romPathNative!);
      _romPathNative = null;
    }
  }

  /// Load ROM from bytes (or path-only when [config.loadViaPathOnly]).
  bool loadGameFromBytes(
    Uint8List romBytes,
    String? path, {
    EmulatorCoreConfig? config,
  }) {
    if (!_initialized) return false;

    final active = config ?? _activeConfig;
    final pathOnly = active?.loadViaPathOnly ?? false;

    emu_loop.resetLibretroProbeSession();

    final gameInfo = calloc<retro_game_info>();
    Pointer<Utf8>? pathNative;
    Pointer<Uint8>? romData;

    if (pathOnly && path != null) {
      _releaseRomPathNative();
      pathNative = path.toNativeUtf8();
      _romPathNative = pathNative;
      gameInfo.ref.path = pathNative;
    } else if (path != null) {
      pathNative = path.toNativeUtf8();
      gameInfo.ref.path = pathNative;
    } else {
      gameInfo.ref.path = nullptr;
    }

    if (pathOnly && path != null) {
      gameInfo.ref.data = nullptr;
      gameInfo.ref.size = 0;
    } else {
      romData = calloc.allocate<Uint8>(romBytes.length);
      romData.asTypedList(romBytes.length).setAll(0, romBytes);
      gameInfo.ref.data = romData.cast<Void>();
      gameInfo.ref.size = romBytes.length;
    }
    gameInfo.ref.meta = nullptr;

    final result = _bindings.retroLoadGame(gameInfo);

    if (romData != null) {
      calloc.free(romData);
    }
    // Path-only cores (FBNeo) retain gameInfo.path until retro_unload_game.
    if (!pathOnly && pathNative != null) {
      malloc.free(pathNative);
    }
    calloc.free(gameInfo);

    _gameLoaded = result;

    if (result) {
      _queryAvInfo();
      _configureJoypadPorts();
    } else if (pathOnly) {
      _releaseRomPathNative();
    }

    return result;
  }

  /// Enable a libretro joypad on the given port (0 = P1, 1 = P2, …).
  void enableJoypadPort(int port) {
    if (!_initialized || !_gameLoaded) {
      return;
    }
    final nesPort2 = _activeConfig?.nesStylePort2Gamepad ?? false;
    _bindings.retroSetControllerPortDevice(
      port,
      nesPort2 && port == 1 ? RETRO_DEVICE_GAMEPAD : RETRO_DEVICE_JOYPAD,
    );
  }

  void configureMultiplayerJoypads() {
    enableJoypadPort(0);
    enableJoypadPort(1);
  }

  void _configureJoypadPorts() {
    configureMultiplayerJoypads();
  }

  /// Run one frame
  void runFrame() {
    if (!_initialized || !_gameLoaded) return;
    _bindings.retroRun();
  }

  /// Update input state
  void updateInput(Map<int, bool> state) {
    _inputState.clear();
    _inputState.addAll(state);
  }

  /// Save state
  Uint8List? saveState() {
    if (!_initialized || !_gameLoaded) return null;

    return emu_loop.runWithCoreLock(() {
      final size = _bindings.retroSerializeSize();
      if (size == 0) return null;

      final data = calloc.allocate<Uint8>(size);
      final success = _bindings.retroSerialize(data.cast<Void>(), size);

      if (success) {
        final result = Uint8List.fromList(data.asTypedList(size));
        calloc.free(data);
        return result;
      }

      calloc.free(data);
      return null;
    });
  }

  /// Load state
  bool loadState(Uint8List state, {void Function(String message)? onError}) {
    if (!_initialized || !_gameLoaded) {
      onError?.call('core not ready');
      return false;
    }

    final size = _bindings.retroSerializeSize();
    if (size == 0) {
      onError?.call('serialize size is 0');
      return false;
    }

    if (state.length != size) {
      onError?.call(
        'size mismatch: file=${state.length} bytes, core=$size bytes',
      );
      return false;
    }

    return emu_loop.runWithCoreLock(() {
      final data = calloc.allocate<Uint8>(size);
      data.asTypedList(size).setAll(0, state);

      final success = _bindings.retroUnserialize(data.cast<Void>(), size);
      calloc.free(data);

      if (!success) {
        onError?.call('retro_unserialize returned false');
      }

      return success;
    });
  }

  /// Reset the game
  void reset() {
    if (!_initialized || !_gameLoaded) return;
    emu_loop.runWithCoreLock(() {
      _bindings.retroReset();
    });
  }

  /// Unload game
  void unloadGame() {
    if (!_initialized || !_gameLoaded) return;
    emu_loop.runWithCoreLock(() {
      _bindings.retroUnloadGame();
    });
    _gameLoaded = false;
    _releaseRomPathNative();
  }

  /// Dispose resources
  void dispose() {
    if (_initialized) {
      emu_loop.flushAudioRing();
      if (_gameLoaded) {
        unloadGame();
      } else {
        _releaseRomPathNative();
      }
      _bindings.retroDeinit();
      _initialized = false;
    }

    if (_framebuffer != null) {
      calloc.free(_framebuffer!);
      _framebuffer = null;
    }
    _displayBuffer = null;

    if (_saveDirectoryNative != null) {
      malloc.free(_saveDirectoryNative!);
      _saveDirectoryNative = null;
    }
    _releaseRomPathNative();
  }
}
