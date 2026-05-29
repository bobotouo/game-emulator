import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../libretro/libretro_bindings.dart';

// ── Save directory ──────────────────────────────────────────────────────────
typedef _SetSaveDirNative = Void Function(Pointer<Utf8>);
typedef _SetSaveDirDart = void Function(Pointer<Utf8>);
final _setSaveDir =
    emuLoopLib.lookupFunction<_SetSaveDirNative, _SetSaveDirDart>(
      'emulator_loop_set_save_directory',
    );

void setSaveDirectory(String path) {
  final ptr = path.toNativeUtf8(allocator: malloc);
  try {
    _setSaveDir(ptr);
  } finally {
    malloc.free(ptr);
  }
}

/// Native library (same binary as game_texture on both platforms).
final DynamicLibrary emuLoopLib = () {
  if (Platform.isAndroid) return DynamicLibrary.open('libgame_texture.so');
  return DynamicLibrary.process();
}();

// ── Callback getter types ──────────────────────────────────────────────────
// Each getter returns the *address* of the corresponding pure-C callback
// function so Dart can pass it to retro_set_XXX.

typedef _GetVideoCbNative
    = Pointer<NativeFunction<retro_video_refresh_t>> Function();
typedef _GetAudioBatchCbNative
    = Pointer<NativeFunction<retro_audio_sample_batch_t>> Function();
typedef _GetAudioSingleCbNative
    = Pointer<NativeFunction<retro_audio_sample_t>> Function();
typedef _GetInputPollCbNative
    = Pointer<NativeFunction<retro_input_poll_t>> Function();
typedef _GetInputStateCbNative
    = Pointer<NativeFunction<retro_input_state_t>> Function();
typedef _GetEnvCbNative
    = Pointer<NativeFunction<retro_environment_t>> Function();

final _getVideoCb =
    emuLoopLib.lookupFunction<_GetVideoCbNative, _GetVideoCbNative>(
      'emulator_loop_video_cb',
    );
final _getAudioBatchCb =
    emuLoopLib.lookupFunction<_GetAudioBatchCbNative, _GetAudioBatchCbNative>(
      'emulator_loop_audio_batch_cb',
    );
final _getAudioSingleCb =
    emuLoopLib.lookupFunction<_GetAudioSingleCbNative, _GetAudioSingleCbNative>(
      'emulator_loop_audio_single_cb',
    );
final _getInputPollCb =
    emuLoopLib.lookupFunction<_GetInputPollCbNative, _GetInputPollCbNative>(
      'emulator_loop_input_poll_cb',
    );
final _getInputStateCb =
    emuLoopLib.lookupFunction<_GetInputStateCbNative, _GetInputStateCbNative>(
      'emulator_loop_input_state_cb',
    );
final _getEnvCb =
    emuLoopLib.lookupFunction<_GetEnvCbNative, _GetEnvCbNative>(
      'emulator_loop_environment_cb',
    );

/// Returns pure-C callbacks that can be passed to retro_set_XXX.
Pointer<NativeFunction<retro_video_refresh_t>> getVideoCb() => _getVideoCb();
Pointer<NativeFunction<retro_audio_sample_batch_t>> getAudioBatchCb() =>
    _getAudioBatchCb();
Pointer<NativeFunction<retro_audio_sample_t>> getAudioSingleCb() =>
    _getAudioSingleCb();
Pointer<NativeFunction<retro_input_poll_t>> getInputPollCb() =>
    _getInputPollCb();
Pointer<NativeFunction<retro_input_state_t>> getInputStateCb() =>
    _getInputStateCb();
Pointer<NativeFunction<retro_environment_t>> getEnvCb() => _getEnvCb();

// ── Pixel format ───────────────────────────────────────────────────────────
typedef _SetFmtNative = Void Function(Int32);
typedef _SetFmtDart = void Function(int);
final _setPixelFmt =
    emuLoopLib.lookupFunction<_SetFmtNative, _SetFmtDart>(
      'emulator_loop_set_pixel_format',
    );

void setPixelFormat(int format) => _setPixelFmt(format);

// ── Loop control ───────────────────────────────────────────────────────────
typedef _StartNative =
    Void Function(Pointer<NativeFunction<Void Function()>>, Double);
typedef _StartDart =
    void Function(Pointer<NativeFunction<Void Function()>>, double);
final _startLoop =
    emuLoopLib.lookupFunction<_StartNative, _StartDart>('emulator_loop_start');

void startNativeLoop(
  Pointer<NativeFunction<Void Function()>> retroRunPtr,
  double fps,
) => _startLoop(retroRunPtr, fps);

typedef _RunFramesNative =
    Void Function(Pointer<NativeFunction<Void Function()>>, Uint32);
typedef _RunFramesDart =
    void Function(Pointer<NativeFunction<Void Function()>>, int);
final _runFrames =
    emuLoopLib.lookupFunction<_RunFramesNative, _RunFramesDart>(
      'emulator_loop_run_frames',
    );

/// Run [count] frames on a native thread. Only safe before [startNativeLoop].
void runSyncFrames(
  Pointer<NativeFunction<Void Function()>> retroRunPtr,
  int count,
) {
  if (count <= 0) return;
  _runFrames(retroRunPtr, count);
}

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
final stopNativeLoop =
    emuLoopLib.lookupFunction<_VoidNative, _VoidDart>('emulator_loop_stop');

typedef _PausedNative = Void Function(Bool);
typedef _PausedDart = void Function(bool);
final setLoopPaused =
    emuLoopLib.lookupFunction<_PausedNative, _PausedDart>(
      'emulator_loop_set_paused',
    );

typedef _IsRunNative = Bool Function();
typedef _IsRunDart = bool Function();
final isLoopRunning =
    emuLoopLib.lookupFunction<_IsRunNative, _IsRunDart>(
      'emulator_loop_is_running',
    );

// ── Input ──────────────────────────────────────────────────────────────────
typedef _SetInputNative = Void Function(Int32, Bool);
typedef _SetInputDart = void Function(int, bool);
final setInputBit =
    emuLoopLib.lookupFunction<_SetInputNative, _SetInputDart>(
      'emulator_loop_set_input_bit',
    );

final clearInputs =
    emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
      'emulator_loop_clear_inputs',
    );

// ── Audio ring buffer ──────────────────────────────────────────────────────
typedef _AvailNative = Int32 Function();
typedef _AvailDart = int Function();
final audioAvailable =
    emuLoopLib.lookupFunction<_AvailNative, _AvailDart>(
      'emulator_loop_audio_available',
    );

typedef _ReadNative = Int32 Function(Pointer<Int16>, Int32);
typedef _ReadDart = int Function(Pointer<Int16>, int);
final _audioRead =
    emuLoopLib.lookupFunction<_ReadNative, _ReadDart>(
      'emulator_loop_audio_read',
    );

/// Pre-allocated scratch buffer (avoids GC pressure per drain call).
final Pointer<Int16> _audioBuf = calloc<Int16>(4096);

/// Drain up to [maxSamples] int16 samples from the ring buffer.
/// Returns a copy so the next drain cannot race with SoLoud on another thread.
Int16List? drainAudio({int maxSamples = 4096}) {
  final avail = audioAvailable();
  if (avail <= 0) return null;
  final n = avail.clamp(0, maxSamples);
  final read = _audioRead(_audioBuf, n);
  if (read <= 0) return null;
  return Int16List.fromList(_audioBuf.asTypedList(read));
}

// ── Frame counter ──────────────────────────────────────────────────────────
typedef _FrameCountNative = Uint64 Function();
typedef _FrameCountDart = int Function();
final _frameCount =
    emuLoopLib.lookupFunction<_FrameCountNative, _FrameCountDart>(
      'emulator_loop_frame_count',
    );

int nativeFrameCount() => _frameCount();

/// Frames actually shown via Flutter Texture (iOS CADisplayLink).
typedef _PresentedFramesNative = Uint64 Function();
typedef _PresentedFramesDart = int Function();
final _PresentedFramesDart? _presentedFramesLookup = Platform.isIOS
    ? emuLoopLib
        .lookupFunction<_PresentedFramesNative, _PresentedFramesDart>(
          'game_texture_ios_presented_frame_count',
        )
    : null;

int nativePresentedFrameCount() {
  final lookup = _presentedFramesLookup;
  if (lookup == null) return nativeFrameCount();
  return lookup();
}

// ── Native audio (iOS AVAudioEngine) ───────────────────────────────────────
typedef _AudioStartNative = Void Function(Double);
typedef _AudioStartDart = void Function(double);
final _audioStart =
    emuLoopLib.lookupFunction<_AudioStartNative, _AudioStartDart>(
      'emulator_loop_audio_start',
    );

final _audioStop =
    emuLoopLib.lookupFunction<_VoidNative, _VoidDart>('emulator_loop_audio_stop');

typedef _AudioPausedNative = Void Function(Bool);
typedef _AudioPausedDart = void Function(bool);
final _audioSetPaused =
    emuLoopLib.lookupFunction<_AudioPausedNative, _AudioPausedDart>(
      'emulator_loop_audio_set_paused',
    );

typedef _SetTargetRateNative = Void Function(Uint32);
typedef _SetTargetRateDart = void Function(int);
final _setTargetSampleRate =
    emuLoopLib.lookupFunction<_SetTargetRateNative, _SetTargetRateDart>(
      'emulator_loop_set_target_sample_rate',
    );

typedef _GetReportedRateNative = Double Function();
typedef _GetReportedRateDart = double Function();
final _getReportedSampleRate =
    emuLoopLib.lookupFunction<_GetReportedRateNative, _GetReportedRateDart>(
      'emulator_loop_get_reported_sample_rate',
    );

/// mGBA etc. resample to this rate in [retro_load_game]. Call before loading ROM.
void setTargetSampleRate(int sampleRate) =>
    _setTargetSampleRate(sampleRate.clamp(8000, 192000));

double getReportedSampleRate() => _getReportedSampleRate();

final _audioFlush =
    emuLoopLib.lookupFunction<_VoidNative, _VoidDart>('emulator_loop_audio_flush');

void flushAudioRing() => _audioFlush();

typedef _PrepareRateNative = Double Function(Double);
typedef _PrepareRateDart = double Function(double);
final _prepareAudioOutputRate = Platform.isIOS
    ? emuLoopLib.lookupFunction<_PrepareRateNative, _PrepareRateDart>(
        'emulator_loop_prepare_audio_output_rate',
      )
    : null;

/// iOS: open AVAudioSession before [retro_load_game]; returns actual Hz (e.g. 48000).
double prepareAudioOutputRate(double preferredHz) {
  final fn = _prepareAudioOutputRate;
  if (fn == null) {
    setTargetSampleRate(preferredHz.round());
    return preferredHz;
  }
  return fn(preferredHz);
}

void startNativeAudio(double sampleRate) => _audioStart(sampleRate);
void stopNativeAudio() => _audioStop();
void setNativeAudioPaused(bool paused) => _audioSetPaused(paused);

typedef _SetSpeedNative = Void Function(Int32);
typedef _SetSpeedDart = void Function(int);
final _setEmulationSpeed =
    emuLoopLib.lookupFunction<_SetSpeedNative, _SetSpeedDart>(
      'emulator_loop_set_speed',
    );

typedef _SetAudioSpeedNative = Void Function(Int32);
typedef _SetAudioSpeedDart = void Function(int);
final _setAudioPlaybackSpeed = Platform.isIOS
    ? emuLoopLib.lookupFunction<_SetAudioSpeedNative, _SetAudioSpeedDart>(
        'emulator_loop_audio_set_playback_speed',
      )
    : null;

/// Fast-forward: run [speed] retro_run calls per frame period (1–5).
void setEmulationSpeed(int speed) {
  final clamped = speed.clamp(1, 5);
  _setEmulationSpeed(clamped);
  _setAudioPlaybackSpeed?.call(clamped);
}

// ── Rumble events ─────────────────────────────────────────────────────────
typedef _RumbleSeqNative = Uint64 Function();
typedef _RumbleSeqDart = int Function();
final _rumbleSequence =
    emuLoopLib.lookupFunction<_RumbleSeqNative, _RumbleSeqDart>(
      'emulator_loop_rumble_sequence',
    );

typedef _RumbleStrengthNative = Uint32 Function();
typedef _RumbleStrengthDart = int Function();
final _rumbleStrong =
    emuLoopLib.lookupFunction<_RumbleStrengthNative, _RumbleStrengthDart>(
      'emulator_loop_rumble_strong',
    );
final _rumbleWeak =
    emuLoopLib.lookupFunction<_RumbleStrengthNative, _RumbleStrengthDart>(
      'emulator_loop_rumble_weak',
    );

int rumbleSequence() => _rumbleSequence();
int rumbleStrong() => _rumbleStrong();
int rumbleWeak() => _rumbleWeak();

// ── Last rendered frame (for thumbnail capture) ────────────────────────────
typedef _LastFrameNative =
    Pointer<Uint8> Function(Pointer<Int32>, Pointer<Int32>);
typedef _LastFrameDart =
    Pointer<Uint8> Function(Pointer<Int32>, Pointer<Int32>);
final _lastFrame =
    emuLoopLib.lookupFunction<_LastFrameNative, _LastFrameDart>(
      'emulator_loop_last_frame',
    );

/// Result of [captureLastFrame].
class FrameCapture {
  final Uint8List rgba;
  final int width;
  final int height;
  const FrameCapture(this.rgba, this.width, this.height);
}

/// Returns the last RGBA8888 frame as a copy, or null if none rendered yet.
FrameCapture? captureLastFrame() {
  final wPtr = calloc<Int32>();
  final hPtr = calloc<Int32>();
  try {
    final ptr = _lastFrame(wPtr, hPtr);
    if (ptr == nullptr) return null;
    final w = wPtr.value;
    final h = hPtr.value;
    if (w <= 0 || h <= 0) return null;
    // Copy because gConvBuf can be overwritten on the emulation thread.
    return FrameCapture(Uint8List.fromList(ptr.asTypedList(w * h * 4)), w, h);
  } finally {
    calloc.free(wPtr);
    calloc.free(hPtr);
  }
}
