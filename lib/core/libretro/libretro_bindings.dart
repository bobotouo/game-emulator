import 'dart:ffi';
import 'package:ffi/ffi.dart';

// Libretro API version
const int RETRO_API_VERSION = 1;

// Pixel formats
const int RETRO_PIXEL_FORMAT_0RGB1555 = 0;
const int RETRO_PIXEL_FORMAT_XRGB8888 = 1;
const int RETRO_PIXEL_FORMAT_RGB565 = 2;

// Input device types
const int RETRO_DEVICE_JOYPAD = 0;
const int RETRO_DEVICE_ANALOG = 5;

// Joypad buttons
const int RETRO_DEVICE_ID_JOYPAD_B = 0;
const int RETRO_DEVICE_ID_JOYPAD_Y = 1;
const int RETRO_DEVICE_ID_JOYPAD_SELECT = 2;
const int RETRO_DEVICE_ID_JOYPAD_START = 3;
const int RETRO_DEVICE_ID_JOYPAD_UP = 4;
const int RETRO_DEVICE_ID_JOYPAD_DOWN = 5;
const int RETRO_DEVICE_ID_JOYPAD_LEFT = 6;
const int RETRO_DEVICE_ID_JOYPAD_RIGHT = 7;
const int RETRO_DEVICE_ID_JOYPAD_A = 8;
const int RETRO_DEVICE_ID_JOYPAD_X = 9;
const int RETRO_DEVICE_ID_JOYPAD_L = 10;
const int RETRO_DEVICE_ID_JOYPAD_R = 11;

// Environment commands
const int RETRO_ENVIRONMENT_SET_PIXEL_FORMAT = 10;
const int RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS = 11;
const int RETRO_ENVIRONMENT_GET_RUMBLE_INTERFACE = 23;
const int RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY = 31;
const int RETRO_ENVIRONMENT_SET_CONTROLLER_INFO = 35;

// Rumble effects
const int RETRO_RUMBLE_STRONG = 0;
const int RETRO_RUMBLE_WEAK = 1;

// Structures
final class retro_game_info extends Struct {
  external Pointer<Utf8> path;
  external Pointer<Void> data;
  @Size()
  external int size;
  external Pointer<Utf8> meta;
}

final class retro_system_info extends Struct {
  external Pointer<Utf8> library_name;
  external Pointer<Utf8> library_version;
  external Pointer<Utf8> valid_extensions;
  @Bool()
  external bool need_fullpath;
  @Bool()
  external bool block_extract;
}

final class retro_system_av_info extends Struct {
  external retro_game_geometry geometry;
  external retro_system_timing timing;
}

final class retro_game_geometry extends Struct {
  @Uint32()
  external int base_width;
  @Uint32()
  external int base_height;
  @Uint32()
  external int max_width;
  @Uint32()
  external int max_height;
  @Float()
  external double aspect_ratio;
}

final class retro_system_timing extends Struct {
  @Double()
  external double fps;
  @Double()
  external double sample_rate;
}

final class retro_rumble_interface extends Struct {
  external Pointer<
      NativeFunction<
          Int32 Function(Uint32 port, Uint32 effect, Uint16 strength)>> set_rumble_state;
}

// Callback types
typedef retro_environment_t = Uint32 Function(Uint32 cmd, Pointer<Void> data);
typedef RetroEnvironment = int Function(int cmd, Pointer<Void> data);

typedef retro_video_refresh_t =
    Void Function(Pointer<Void> data, Uint32 width, Uint32 height, Size pitch);
typedef RetroVideoRefresh =
    void Function(Pointer<void> data, int width, int height, int pitch);

typedef retro_audio_sample_t = Void Function(Int16 left, Int16 right);
typedef RetroAudioSample = void Function(int left, int right);

typedef retro_audio_sample_batch_t =
    Size Function(Pointer<Int16> data, Size frames);
typedef RetroAudioSampleBatch = int Function(Pointer<Int16> data, int frames);

typedef retro_input_poll_t = Void Function();
typedef RetroInputPoll = void Function();

typedef retro_input_state_t =
    Int16 Function(Uint32 port, Uint32 device, Uint32 index, Uint32 id);
typedef RetroInputState = int Function(int port, int device, int index, int id);

// Core function signatures
typedef retro_init_native = Void Function();
typedef retro_init_dart = void Function();

typedef retro_deinit_native = Void Function();
typedef retro_deinit_dart = void Function();

typedef retro_api_version_native = UnsignedInt Function();
typedef retro_api_version_dart = int Function();

typedef retro_get_system_info_native =
    Void Function(Pointer<retro_system_info> info);
typedef retro_get_system_info_dart =
    void Function(Pointer<retro_system_info> info);

typedef retro_get_system_av_info_native =
    Void Function(Pointer<retro_system_av_info> info);
typedef retro_get_system_av_info_dart =
    void Function(Pointer<retro_system_av_info> info);

typedef retro_set_environment_native =
    Void Function(Pointer<NativeFunction<retro_environment_t>> cb);
typedef retro_set_environment_dart =
    void Function(Pointer<NativeFunction<retro_environment_t>> cb);

typedef retro_set_video_refresh_native =
    Void Function(Pointer<NativeFunction<retro_video_refresh_t>> cb);
typedef retro_set_video_refresh_dart =
    void Function(Pointer<NativeFunction<retro_video_refresh_t>> cb);

typedef retro_set_audio_sample_native =
    Void Function(Pointer<NativeFunction<retro_audio_sample_t>> cb);
typedef retro_set_audio_sample_dart =
    void Function(Pointer<NativeFunction<retro_audio_sample_t>> cb);

typedef retro_set_audio_sample_batch_native =
    Void Function(Pointer<NativeFunction<retro_audio_sample_batch_t>> cb);
typedef retro_set_audio_sample_batch_dart =
    void Function(Pointer<NativeFunction<retro_audio_sample_batch_t>> cb);

typedef retro_set_input_poll_native =
    Void Function(Pointer<NativeFunction<retro_input_poll_t>> cb);
typedef retro_set_input_poll_dart =
    void Function(Pointer<NativeFunction<retro_input_poll_t>> cb);

typedef retro_set_input_state_native =
    Void Function(Pointer<NativeFunction<retro_input_state_t>> cb);
typedef retro_set_input_state_dart =
    void Function(Pointer<NativeFunction<retro_input_state_t>> cb);

typedef retro_load_game_native = Bool Function(Pointer<retro_game_info> game);
typedef retro_load_game_dart = bool Function(Pointer<retro_game_info> game);

typedef retro_run_native = Void Function();
typedef retro_run_dart = void Function();

typedef retro_unload_game_native = Void Function();
typedef retro_unload_game_dart = void Function();

typedef retro_reset_native = Void Function();
typedef retro_reset_dart = void Function();

typedef retro_serialize_size_native = Size Function();
typedef retro_serialize_size_dart = int Function();

typedef retro_serialize_native = Bool Function(Pointer<Void> data, Size size);
typedef retro_serialize_dart = bool Function(Pointer<Void> data, int size);

typedef retro_unserialize_native = Bool Function(Pointer<Void> data, Size size);
typedef retro_unserialize_dart = bool Function(Pointer<Void> data, int size);

typedef retro_set_controller_port_device_native =
    Void Function(Uint32 port, Uint32 device);
typedef retro_set_controller_port_device_dart =
    void Function(int port, int device);

typedef retro_get_memory_data_native = Pointer<Void> Function(Uint32 id);
typedef retro_get_memory_data_dart = Pointer<void> Function(int id);

typedef retro_get_memory_size_native = Size Function(Uint32 id);
typedef retro_get_memory_size_dart = int Function(int id);

/// Libretro core bindings
class LibretroBindings {
  late DynamicLibrary _lib;

  // Core functions
  late retro_init_dart retroInit;
  late retro_deinit_dart retroDeinit;
  late retro_api_version_dart retroApiVersion;
  late retro_get_system_info_dart retroGetSystemInfo;
  late retro_get_system_av_info_dart retroGetSystemAvInfo;
  late retro_set_environment_dart retroSetEnvironment;
  late retro_set_video_refresh_dart retroSetVideoRefresh;
  late retro_set_audio_sample_dart retroSetAudioSample;
  late retro_set_audio_sample_batch_dart retroSetAudioSampleBatch;
  late retro_set_input_poll_dart retroSetInputPoll;
  late retro_set_input_state_dart retroSetInputState;
  late retro_load_game_dart retroLoadGame;
  late retro_run_dart retroRun;
  late retro_unload_game_dart retroUnloadGame;
  late retro_reset_dart retroReset;
  late retro_serialize_size_dart retroSerializeSize;
  late retro_serialize_dart retroSerialize;
  late retro_unserialize_dart retroUnserialize;
  late retro_set_controller_port_device_dart retroSetControllerPortDevice;
  late retro_get_memory_data_dart retroGetMemoryData;
  late retro_get_memory_size_dart retroGetMemorySize;

  LibretroBindings(String corePath) {
    _lib = DynamicLibrary.open(corePath);
    _bindFunctions();
  }

  void _bindFunctions() {
    retroInit = _lib.lookupFunction<retro_init_native, retro_init_dart>(
      'retro_init',
    );
    retroDeinit = _lib.lookupFunction<retro_deinit_native, retro_deinit_dart>(
      'retro_deinit',
    );
    retroApiVersion = _lib
        .lookupFunction<retro_api_version_native, retro_api_version_dart>(
          'retro_api_version',
        );
    retroGetSystemInfo = _lib
        .lookupFunction<
          retro_get_system_info_native,
          retro_get_system_info_dart
        >('retro_get_system_info');
    retroGetSystemAvInfo = _lib
        .lookupFunction<
          retro_get_system_av_info_native,
          retro_get_system_av_info_dart
        >('retro_get_system_av_info');
    retroSetEnvironment = _lib
        .lookupFunction<
          retro_set_environment_native,
          retro_set_environment_dart
        >('retro_set_environment');
    retroSetVideoRefresh = _lib
        .lookupFunction<
          retro_set_video_refresh_native,
          retro_set_video_refresh_dart
        >('retro_set_video_refresh');
    retroSetAudioSample = _lib
        .lookupFunction<
          retro_set_audio_sample_native,
          retro_set_audio_sample_dart
        >('retro_set_audio_sample');
    retroSetAudioSampleBatch = _lib
        .lookupFunction<
          retro_set_audio_sample_batch_native,
          retro_set_audio_sample_batch_dart
        >('retro_set_audio_sample_batch');
    retroSetInputPoll = _lib
        .lookupFunction<retro_set_input_poll_native, retro_set_input_poll_dart>(
          'retro_set_input_poll',
        );
    retroSetInputState = _lib
        .lookupFunction<
          retro_set_input_state_native,
          retro_set_input_state_dart
        >('retro_set_input_state');
    retroLoadGame = _lib
        .lookupFunction<retro_load_game_native, retro_load_game_dart>(
          'retro_load_game',
        );
    retroRun = _lib.lookupFunction<retro_run_native, retro_run_dart>(
      'retro_run',
    );
    retroUnloadGame = _lib
        .lookupFunction<retro_unload_game_native, retro_unload_game_dart>(
          'retro_unload_game',
        );
    retroReset = _lib.lookupFunction<retro_reset_native, retro_reset_dart>(
      'retro_reset',
    );
    retroSerializeSize = _lib
        .lookupFunction<retro_serialize_size_native, retro_serialize_size_dart>(
          'retro_serialize_size',
        );
    retroSerialize = _lib
        .lookupFunction<retro_serialize_native, retro_serialize_dart>(
          'retro_serialize',
        );
    retroUnserialize = _lib
        .lookupFunction<retro_unserialize_native, retro_unserialize_dart>(
          'retro_unserialize',
        );
    retroSetControllerPortDevice = _lib
        .lookupFunction<
          retro_set_controller_port_device_native,
          retro_set_controller_port_device_dart
        >('retro_set_controller_port_device');
    retroGetMemoryData = _lib
        .lookupFunction<
          retro_get_memory_data_native,
          retro_get_memory_data_dart
        >('retro_get_memory_data');
    retroGetMemorySize = _lib
        .lookupFunction<
          retro_get_memory_size_native,
          retro_get_memory_size_dart
        >('retro_get_memory_size');
  }
}
