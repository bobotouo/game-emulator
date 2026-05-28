import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';
import 'package:ffi/ffi.dart';
import '../haptics/haptic_service.dart';
import '../storage/storage_paths_service.dart';
import 'libretro_bindings.dart';

/// Callback for video frame output
typedef VideoCallback =
    void Function(Uint8List framebuffer, int width, int height, int pitch);

/// Callback for audio output
typedef AudioCallback = void Function(Int16List samples, int frames);

/// Callback for input polling
typedef InputPollCallback = void Function();

/// Global instance for FFI callbacks
LibretroCore? _globalInstance;

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
  double _fps = 60.0;
  double _sampleRate = 32768.0;

  // Framebuffer
  Pointer<Uint8>? _framebuffer;
  int _framebufferSize = 0;
  int _pixelFormat = RETRO_PIXEL_FORMAT_XRGB8888;

  // Callbacks
  VideoCallback? videoCallback;
  AudioCallback? audioCallback;
  InputPollCallback? inputPollCallback;

  // Input state
  final Map<int, bool> _inputState = {};

  // Native callback pointers (must be kept alive)
  late Pointer<NativeFunction<retro_environment_t>> _envCallback;
  late Pointer<NativeFunction<retro_video_refresh_t>> _videoRefreshCallback;
  late Pointer<NativeFunction<retro_audio_sample_t>> _audioSampleCallback;
  late Pointer<NativeFunction<retro_audio_sample_batch_t>> _audioBatchCallback;
  late Pointer<NativeFunction<retro_input_poll_t>> _inputPollCallbackNative;
  late Pointer<NativeFunction<retro_input_state_t>> _inputStateCallbackNative;
  late Pointer<
      NativeFunction<Int32 Function(Uint32 port, Uint32 effect, Uint16 strength)>>
  _rumbleCallbackNative;

  Pointer<Utf8>? _saveDirectoryNative;

  /// Get core info
  String get coreName => _coreName;
  String get coreVersion => _coreVersion;
  int get baseWidth => _baseWidth;
  int get baseHeight => _baseHeight;
  double get fps => _fps;
  double get sampleRate => _sampleRate;
  bool get isInitialized => _initialized;
  bool get isGameLoaded => _gameLoaded;

  /// Initialize the core
  bool initialize(String corePath) {
    try {
      _globalInstance = this;
      _bindings = LibretroBindings(corePath);
      _setupCallbacks();
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

  void _setupCallbacks() {
    // Environment callback
    _envCallback = Pointer.fromFunction<retro_environment_t>(
      _environmentCallback,
      0,
    );

    // Video refresh callback
    _videoRefreshCallback = Pointer.fromFunction<retro_video_refresh_t>(
      _videoRefreshCallbackFn,
    );

    // Audio single-sample callback
    _audioSampleCallback = Pointer.fromFunction<retro_audio_sample_t>(
      _audioSampleCallbackFn,
    );

    // Audio batch callback
    _audioBatchCallback = Pointer.fromFunction<retro_audio_sample_batch_t>(
      _audioSampleBatchCallback,
      0,
    );

    // Input poll callback
    _inputPollCallbackNative = Pointer.fromFunction<retro_input_poll_t>(
      _inputPollCallbackFn,
    );

    // Input state callback
    _inputStateCallbackNative = Pointer.fromFunction<retro_input_state_t>(
      _inputStateCallbackFn,
      0,
    );

    _rumbleCallbackNative = Pointer.fromFunction<
        Int32 Function(Uint32 port, Uint32 effect, Uint16 strength)>(
      _setRumbleStateFn,
      0,
    );

    // Register callbacks
    _bindings.retroSetEnvironment(_envCallback);
    _bindings.retroSetVideoRefresh(_videoRefreshCallback);
    _bindings.retroSetAudioSample(_audioSampleCallback);
    _bindings.retroSetAudioSampleBatch(_audioBatchCallback);
    _bindings.retroSetInputPoll(_inputPollCallbackNative);
    _bindings.retroSetInputState(_inputStateCallbackNative);
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
    _fps = avInfo.ref.timing.fps;
    _sampleRate = avInfo.ref.timing.sample_rate;
    calloc.free(avInfo);

    // Allocate a tight RGBA8888 framebuffer for Flutter.
    _framebufferSize = _baseWidth * _baseHeight * 4;
    if (_framebuffer != null) {
      calloc.free(_framebuffer!);
    }
    _framebuffer = calloc.allocate<Uint8>(_framebufferSize);
  }

  /// Load a ROM file
  bool loadGame(String romPath) {
    if (!_initialized) return false;

    final file = File(romPath);
    if (!file.existsSync()) return false;

    final romBytes = file.readAsBytesSync();
    return loadGameFromBytes(romBytes, romPath);
  }

  /// Prepare save directory path for libretro cores (battery saves).
  Future<void> prepareSaveDirectory() async {
    final dir = await StoragePathsService.getInGameSavesDirectory();
    if (_saveDirectoryNative != null) {
      malloc.free(_saveDirectoryNative!);
    }
    _saveDirectoryNative = dir.path.toNativeUtf8();
  }

  /// Load ROM from bytes
  bool loadGameFromBytes(Uint8List romBytes, String? path) {
    if (!_initialized) return false;

    final gameInfo = calloc<retro_game_info>();
    Pointer<Utf8>? pathNative;

    if (path != null) {
      pathNative = path.toNativeUtf8();
      gameInfo.ref.path = pathNative;
    } else {
      gameInfo.ref.path = nullptr;
    }

    // Allocate memory for ROM data
    final romData = calloc.allocate<Uint8>(romBytes.length);
    romData.asTypedList(romBytes.length).setAll(0, romBytes);

    gameInfo.ref.data = romData.cast<Void>();
    gameInfo.ref.size = romBytes.length;
    gameInfo.ref.meta = nullptr;

    final result = _bindings.retroLoadGame(gameInfo);

    calloc.free(romData);
    if (pathNative != null) {
      malloc.free(pathNative);
    }
    calloc.free(gameInfo);

    _gameLoaded = result;

    // Query AV info after game is loaded
    if (result) {
      _queryAvInfo();
    }

    return result;
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

    final data = calloc.allocate<Uint8>(size);
    data.asTypedList(size).setAll(0, state);

    final success = _bindings.retroUnserialize(data.cast<Void>(), size);
    calloc.free(data);

    if (!success) {
      onError?.call('retro_unserialize returned false');
    }

    return success;
  }

  /// Reset the game
  void reset() {
    if (!_initialized || !_gameLoaded) return;
    _bindings.retroReset();
  }

  /// Unload game
  void unloadGame() {
    if (!_initialized || !_gameLoaded) return;
    _bindings.retroUnloadGame();
    _gameLoaded = false;
  }

  /// Dispose resources
  void dispose() {
    if (_initialized) {
      if (_gameLoaded) {
        _bindings.retroUnloadGame();
      }
      _bindings.retroDeinit();
      _initialized = false;
    }

    if (_framebuffer != null) {
      calloc.free(_framebuffer!);
      _framebuffer = null;
    }

    if (_saveDirectoryNative != null) {
      malloc.free(_saveDirectoryNative!);
      _saveDirectoryNative = null;
    }

    _globalInstance = null;
  }

  // Static callbacks (FFI requires static functions)

  static int _environmentCallback(int cmd, Pointer<Void> data) {
    final instance = _globalInstance;

    if (cmd == RETRO_ENVIRONMENT_SET_PIXEL_FORMAT) {
      final requestedFormat = data.cast<Uint32>().value;
      if (requestedFormat == RETRO_PIXEL_FORMAT_XRGB8888 ||
          requestedFormat == RETRO_PIXEL_FORMAT_RGB565 ||
          requestedFormat == RETRO_PIXEL_FORMAT_0RGB1555) {
        instance?._pixelFormat = requestedFormat;
        return 1;
      }
      return 0;
    }

    if (cmd == RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE) {
      final iface = data.cast<retro_rumble_interface>();
      iface.ref.set_rumble_state = instance!._rumbleCallbackNative;
      return 1;
    }

    if (cmd == RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY) {
      final nativePath = instance?._saveDirectoryNative;
      if (nativePath == null) return 0;
      data.cast<Pointer<Utf8>>().value = nativePath;
      return 1;
    }

    return 0;
  }

  static int _setRumbleStateFn(int port, int effect, int strength) {
    HapticService.instance.gameRumble(
      strength,
      strong: effect == RETRO_RUMBLE_STRONG,
    );
    return 1;
  }

  static void _videoRefreshCallbackFn(
    Pointer<Void> data,
    int width,
    int height,
    int pitch,
  ) {
    final instance = _globalInstance;
    if (instance == null || instance._framebuffer == null) return;

    final outputSize = width * height * 4;
    if (outputSize <= instance._framebufferSize) {
      final output = instance._framebuffer!.asTypedList(outputSize);
      if (data != nullptr) {
        instance._copyFrameToRgba8888(data, width, height, pitch, output);
      }

      instance.videoCallback?.call(output, width, height, width * 4);
    }
  }

  void _copyFrameToRgba8888(
    Pointer<Void> data,
    int width,
    int height,
    int pitch,
    Uint8List output,
  ) {
    switch (_pixelFormat) {
      case RETRO_PIXEL_FORMAT_XRGB8888:
        _copyXrgb8888ToRgba8888(
          data.cast<Uint8>(),
          width,
          height,
          pitch,
          output,
        );
        break;
      case RETRO_PIXEL_FORMAT_RGB565:
        _copyRgb565ToRgba8888(data.cast<Uint8>(), width, height, pitch, output);
        break;
      case RETRO_PIXEL_FORMAT_0RGB1555:
        _copy0Rgb1555ToRgba8888(
          data.cast<Uint8>(),
          width,
          height,
          pitch,
          output,
        );
        break;
      default:
        output.fillRange(0, output.length, 0);
    }
  }

  void _copyXrgb8888ToRgba8888(
    Pointer<Uint8> data,
    int width,
    int height,
    int pitch,
    Uint8List output,
  ) {
    final input = data.asTypedList(height * pitch);
    var out = 0;
    for (var y = 0; y < height; y++) {
      var row = y * pitch;
      for (var x = 0; x < width; x++) {
        final pixel = row + x * 4;
        output[out++] = input[pixel + 2];
        output[out++] = input[pixel + 1];
        output[out++] = input[pixel];
        output[out++] = 0xFF;
      }
    }
  }

  void _copyRgb565ToRgba8888(
    Pointer<Uint8> data,
    int width,
    int height,
    int pitch,
    Uint8List output,
  ) {
    final input = data.asTypedList(height * pitch);
    var out = 0;
    for (var y = 0; y < height; y++) {
      var row = y * pitch;
      for (var x = 0; x < width; x++) {
        final pixel = row + x * 2;
        final value = input[pixel] | (input[pixel + 1] << 8);
        final r = (value >> 11) & 0x1F;
        final g = (value >> 5) & 0x3F;
        final b = value & 0x1F;
        output[out++] = (r << 3) | (r >> 2);
        output[out++] = (g << 2) | (g >> 4);
        output[out++] = (b << 3) | (b >> 2);
        output[out++] = 0xFF;
      }
    }
  }

  void _copy0Rgb1555ToRgba8888(
    Pointer<Uint8> data,
    int width,
    int height,
    int pitch,
    Uint8List output,
  ) {
    final input = data.asTypedList(height * pitch);
    var out = 0;
    for (var y = 0; y < height; y++) {
      var row = y * pitch;
      for (var x = 0; x < width; x++) {
        final pixel = row + x * 2;
        final value = input[pixel] | (input[pixel + 1] << 8);
        final r = (value >> 10) & 0x1F;
        final g = (value >> 5) & 0x1F;
        final b = value & 0x1F;
        output[out++] = (r << 3) | (r >> 2);
        output[out++] = (g << 3) | (g >> 2);
        output[out++] = (b << 3) | (b >> 2);
        output[out++] = 0xFF;
      }
    }
  }

  static int _audioSampleBatchCallback(Pointer<Int16> data, int frames) {
    final instance = _globalInstance;
    if (instance == null) return frames;

    // Copy audio data
    final samples = data.asTypedList(frames * 2);
    instance.audioCallback?.call(samples, frames);

    return frames;
  }

  static void _audioSampleCallbackFn(int left, int right) {
    final instance = _globalInstance;
    if (instance == null) return;

    instance.audioCallback?.call(Int16List.fromList([left, right]), 1);
  }

  static void _inputPollCallbackFn() {
    _globalInstance?.inputPollCallback?.call();
  }

  static int _inputStateCallbackFn(int port, int device, int index, int id) {
    final instance = _globalInstance;
    if (instance == null) return 0;

    // Return input state
    return instance._inputState[id] == true ? 1 : 0;
  }
}
