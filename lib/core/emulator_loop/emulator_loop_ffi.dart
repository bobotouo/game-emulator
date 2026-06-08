import 'dart:ffi' hide Size;
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import '../libretro/libretro_bindings.dart';

// ── Save directory ──────────────────────────────────────────────────────────
typedef _SetSaveDirNative = Void Function(Pointer<Utf8>);
typedef _SetSaveDirDart = void Function(Pointer<Utf8>);

void setSaveDirectory(String path) {
  _setNativePath('emulator_loop_set_save_directory', path);
}

void setSystemDirectory(String path) {
  _setNativePath('emulator_loop_set_system_directory', path);
}

void setContentDirectory(String path) {
  _setNativePath('emulator_loop_set_content_directory', path);
}

void _setNativePath(String symbol, String path) {
  final setDir = emuLoopLib.lookupFunction<_SetSaveDirNative, _SetSaveDirDart>(
    symbol,
  );
  final ptr = path.toNativeUtf8(allocator: malloc);
  try {
    setDir(ptr);
  } finally {
    malloc.free(ptr);
  }
}

typedef _ResetPortsNative = Void Function();
typedef _ResetPortsDart = void Function();
final _resetControllerPorts = emuLoopLib
    .lookupFunction<_ResetPortsNative, _ResetPortsDart>(
      'emulator_loop_reset_controller_ports',
    );

typedef _GetPortsNative = Uint32 Function();
typedef _GetPortsDart = int Function();
final _getControllerPorts = emuLoopLib
    .lookupFunction<_GetPortsNative, _GetPortsDart>(
      'emulator_loop_get_controller_ports',
    );

void resetControllerPortCount() => _resetControllerPorts();

/// Joypad ports reported by the core after [retro_load_game] (0 if unknown).
int getControllerPortCount() => _getControllerPorts();

/// Native library (same binary as game_texture on both platforms).
final DynamicLibrary emuLoopLib = () {
  if (Platform.isAndroid) return DynamicLibrary.open('libgame_texture.so');
  return DynamicLibrary.process();
}();

// ── Callback getter types ──────────────────────────────────────────────────
// Each getter returns the *address* of the corresponding pure-C callback
// function so Dart can pass it to retro_set_XXX.

typedef _GetVideoCbNative =
    Pointer<NativeFunction<retro_video_refresh_t>> Function();
typedef _GetAudioBatchCbNative =
    Pointer<NativeFunction<retro_audio_sample_batch_t>> Function();
typedef _GetAudioSingleCbNative =
    Pointer<NativeFunction<retro_audio_sample_t>> Function();
typedef _GetInputPollCbNative =
    Pointer<NativeFunction<retro_input_poll_t>> Function();
typedef _GetInputStateCbNative =
    Pointer<NativeFunction<retro_input_state_t>> Function();
typedef _GetEnvCbNative =
    Pointer<NativeFunction<retro_environment_t>> Function();

final _getVideoCb = emuLoopLib
    .lookupFunction<_GetVideoCbNative, _GetVideoCbNative>(
      'emulator_loop_video_cb',
    );
final _getAudioBatchCb = emuLoopLib
    .lookupFunction<_GetAudioBatchCbNative, _GetAudioBatchCbNative>(
      'emulator_loop_audio_batch_cb',
    );
final _getAudioSingleCb = emuLoopLib
    .lookupFunction<_GetAudioSingleCbNative, _GetAudioSingleCbNative>(
      'emulator_loop_audio_single_cb',
    );
final _getInputPollCb = emuLoopLib
    .lookupFunction<_GetInputPollCbNative, _GetInputPollCbNative>(
      'emulator_loop_input_poll_cb',
    );
final _getInputStateCb = emuLoopLib
    .lookupFunction<_GetInputStateCbNative, _GetInputStateCbNative>(
      'emulator_loop_input_state_cb',
    );
final _getEnvCb = emuLoopLib.lookupFunction<_GetEnvCbNative, _GetEnvCbNative>(
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
final _setPixelFmt = emuLoopLib.lookupFunction<_SetFmtNative, _SetFmtDart>(
  'emulator_loop_set_pixel_format',
);

void setPixelFormat(int format) => _setPixelFmt(format);

// ── Loop control ───────────────────────────────────────────────────────────
typedef _StartNative =
    Void Function(Pointer<NativeFunction<Void Function()>>, Double);
typedef _StartDart =
    void Function(Pointer<NativeFunction<Void Function()>>, double);
final _startLoop = emuLoopLib.lookupFunction<_StartNative, _StartDart>(
  'emulator_loop_start',
);

void startNativeLoop(
  Pointer<NativeFunction<Void Function()>> retroRunPtr,
  double fps,
) => _startLoop(retroRunPtr, fps);

// ── Netplay rollback snapshots (C ring; same thread as retro_run) ───────────
typedef _SnapshotNative = Bool Function(Pointer<Void>, UintPtr);
typedef _SnapshotDart = bool Function(Pointer<Void>, int);

typedef _NetplayBeginNative =
    Void Function(
      Pointer<NativeFunction<_SnapshotNative>>,
      Pointer<NativeFunction<_SnapshotNative>>,
      UintPtr,
      Int32,
    );
typedef _NetplayBeginDart =
    void Function(
      Pointer<NativeFunction<_SnapshotNative>>,
      Pointer<NativeFunction<_SnapshotNative>>,
      int,
      int,
    );
final _netplayBegin = emuLoopLib
    .lookupFunction<_NetplayBeginNative, _NetplayBeginDart>(
      'emulator_loop_netplay_begin',
    );

typedef _NetplayEndNative = Void Function();
typedef _NetplayEndDart = void Function();
final _netplayEnd = emuLoopLib
    .lookupFunction<_NetplayEndNative, _NetplayEndDart>(
      'emulator_loop_netplay_end',
    );

typedef _NetplayLoadNative = Bool Function(Uint64);
typedef _NetplayLoadDart = bool Function(int);
final _netplayLoad = emuLoopLib
    .lookupFunction<_NetplayLoadNative, _NetplayLoadDart>(
      'emulator_loop_netplay_load_frame',
    );

typedef _NetplaySimFrameNative = Uint64 Function();
typedef _NetplaySimFrameDart = int Function();
final _netplaySimFrame = emuLoopLib
    .lookupFunction<_NetplaySimFrameNative, _NetplaySimFrameDart>(
      'emulator_loop_netplay_sim_frame',
    );

typedef _NetplaySetSimNative = Void Function(Uint64);
typedef _NetplaySetSimDart = void Function(int);
final _netplaySetSimFrame = emuLoopLib
    .lookupFunction<_NetplaySetSimNative, _NetplaySetSimDart>(
      'emulator_loop_netplay_set_sim_frame',
    );

void beginNetplaySnapshots({
  required Pointer<NativeFunction<_SnapshotNative>> serialize,
  required Pointer<NativeFunction<_SnapshotNative>> restore,
  required int stateSize,
  required int maxFrames,
}) {
  _netplayBegin(serialize, restore, stateSize, maxFrames);
}

void endNetplaySnapshots() => _netplayEnd();

bool netplayLoadFrame(int frame) => _netplayLoad(frame);

int netplaySimFrame() => _netplaySimFrame();

void netplaySetSimFrame(int frame) => _netplaySetSimFrame(frame);

// ── gpSP serial netpacket bridge ──────────────────────────────────────────
typedef _SetGpspSerialModeNative = Void Function(Pointer<Utf8>);
typedef _SetGpspSerialModeDart = void Function(Pointer<Utf8>);
final _setGpspSerialMode = emuLoopLib
    .lookupFunction<_SetGpspSerialModeNative, _SetGpspSerialModeDart>(
      'emulator_loop_set_gpsp_serial_mode',
    );

void setGpspSerialMode(String mode) {
  final normalized = switch (mode) {
    'disabled' => 'disabled',
    'rfu' => 'rfu',
    'mul_poke' => 'mul_poke',
    'mul_aw1' => 'mul_aw1',
    'mul_aw2' => 'mul_aw2',
    _ => 'auto',
  };
  final ptr = normalized.toNativeUtf8(allocator: malloc);
  try {
    _setGpspSerialMode(ptr);
  } finally {
    malloc.free(ptr);
  }
}

typedef _NetpacketAvailableNative = Bool Function();
typedef _NetpacketAvailableDart = bool Function();
final _netpacketAvailable = emuLoopLib
    .lookupFunction<_NetpacketAvailableNative, _NetpacketAvailableDart>(
      'emulator_loop_netpacket_available',
    );

typedef _NetpacketStartNative = Void Function(Uint16);
typedef _NetpacketStartDart = void Function(int);
final _netpacketStart = emuLoopLib
    .lookupFunction<_NetpacketStartNative, _NetpacketStartDart>(
      'emulator_loop_netpacket_start',
    );

typedef _NetpacketStopNative = Void Function();
typedef _NetpacketStopDart = void Function();
final _netpacketStop = emuLoopLib
    .lookupFunction<_NetpacketStopNative, _NetpacketStopDart>(
      'emulator_loop_netpacket_stop',
    );

typedef _NetpacketConnectNative = Bool Function(Uint16);
typedef _NetpacketConnectDart = bool Function(int);
final _netpacketConnect = emuLoopLib
    .lookupFunction<_NetpacketConnectNative, _NetpacketConnectDart>(
      'emulator_loop_netpacket_connect',
    );

typedef _NetpacketDisconnectNative = Void Function(Uint16);
typedef _NetpacketDisconnectDart = void Function(int);
final _netpacketDisconnect = emuLoopLib
    .lookupFunction<_NetpacketDisconnectNative, _NetpacketDisconnectDart>(
      'emulator_loop_netpacket_disconnect',
    );

typedef _NetpacketReadNative =
    Int32 Function(Pointer<Uint16>, Pointer<Int32>, Pointer<Uint8>, Int32);
typedef _NetpacketReadDart =
    int Function(Pointer<Uint16>, Pointer<Int32>, Pointer<Uint8>, int);
final _netpacketRead = emuLoopLib
    .lookupFunction<_NetpacketReadNative, _NetpacketReadDart>(
      'emulator_loop_netpacket_read',
    );

typedef _NetpacketPushNative = Void Function(Pointer<Uint8>, Int32, Uint16);
typedef _NetpacketPushDart = void Function(Pointer<Uint8>, int, int);
final _netpacketPush = emuLoopLib
    .lookupFunction<_NetpacketPushNative, _NetpacketPushDart>(
      'emulator_loop_netpacket_push',
    );

class GbaNetpacket {
  const GbaNetpacket({
    required this.targetClientId,
    required this.flags,
    required this.bytes,
  });

  final int targetClientId;
  final int flags;
  final Uint8List bytes;
}

const int gbaNetpacketBroadcast = 0xFFFF;
const int _gbaNetpacketMaxBytes = 65536;
final Pointer<Uint8> _gbaNetpacketBuf = calloc<Uint8>(_gbaNetpacketMaxBytes);
final Pointer<Uint16> _gbaNetpacketTarget = calloc<Uint16>();
final Pointer<Int32> _gbaNetpacketFlags = calloc<Int32>();

bool isGbaNetpacketAvailable() => _netpacketAvailable();

void startGbaNetpacketSession(int localClientId) {
  _netpacketStart(localClientId.clamp(0, gbaNetpacketBroadcast).toInt());
}

void stopGbaNetpacketSession() => _netpacketStop();

bool connectGbaNetpacketClient(int clientId) =>
    _netpacketConnect(clientId.clamp(0, gbaNetpacketBroadcast).toInt());

void disconnectGbaNetpacketClient(int clientId) =>
    _netpacketDisconnect(clientId.clamp(0, gbaNetpacketBroadcast).toInt());

GbaNetpacket? readGbaNetpacket() {
  final size = _netpacketRead(
    _gbaNetpacketTarget,
    _gbaNetpacketFlags,
    _gbaNetpacketBuf,
    _gbaNetpacketMaxBytes,
  );
  if (size <= 0) {
    return null;
  }
  return GbaNetpacket(
    targetClientId: _gbaNetpacketTarget.value,
    flags: _gbaNetpacketFlags.value,
    bytes: Uint8List.fromList(_gbaNetpacketBuf.asTypedList(size)),
  );
}

void pushGbaNetpacket(Uint8List bytes, {required int sourceClientId}) {
  if (bytes.isEmpty) {
    return;
  }
  final size = bytes.length.clamp(0, _gbaNetpacketMaxBytes);
  final ptr = malloc<Uint8>(size);
  try {
    ptr.asTypedList(size).setAll(0, bytes.take(size));
    _netpacketPush(
      ptr,
      size,
      sourceClientId.clamp(0, gbaNetpacketBroadcast).toInt(),
    );
  } finally {
    malloc.free(ptr);
  }
}

typedef _RunFramesNative =
    Void Function(Pointer<NativeFunction<Void Function()>>, Uint32);
typedef _RunFramesDart =
    void Function(Pointer<NativeFunction<Void Function()>>, int);
final _runFrames = emuLoopLib.lookupFunction<_RunFramesNative, _RunFramesDart>(
  'emulator_loop_run_frames',
);

/// One frame under the global core mutex (netplay / rollback).
typedef _AdvanceNative =
    Void Function(Pointer<NativeFunction<Void Function()>>);
typedef _AdvanceDart = void Function(Pointer<NativeFunction<Void Function()>>);
final _advanceFrame = emuLoopLib.lookupFunction<_AdvanceNative, _AdvanceDart>(
  'emulator_loop_advance_frame',
);

void advanceEmulatorFrame(
  Pointer<NativeFunction<Void Function()>> retroRunPtr,
) {
  _advanceFrame(retroRunPtr);
}

typedef _WaitStoppedNative = Bool Function();
typedef _WaitStoppedDart = bool Function();
final _waitUntilStopped = emuLoopLib
    .lookupFunction<_WaitStoppedNative, _WaitStoppedDart>(
      'emulator_loop_wait_until_stopped',
    );

bool waitUntilEmulatorStopped() => _waitUntilStopped();

/// Run [count] frames (mutex-serialized). Do not use while [startNativeLoop] runs.
void runSyncFrames(
  Pointer<NativeFunction<Void Function()>> retroRunPtr,
  int count,
) {
  if (count <= 0) return;
  for (var i = 0; i < count; i++) {
    advanceEmulatorFrame(retroRunPtr);
  }
}

typedef _VoidNative = Void Function();
typedef _VoidDart = void Function();
final stopNativeLoop = emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
  'emulator_loop_stop',
);

final _coreLock = emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
  'emulator_loop_core_lock',
);

final _coreUnlock = emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
  'emulator_loop_core_unlock',
);

T runWithCoreLock<T>(T Function() action) {
  _coreLock();
  try {
    return action();
  } finally {
    _coreUnlock();
  }
}

typedef _PausedNative = Void Function(Bool);
typedef _PausedDart = void Function(bool);
final setLoopPaused = emuLoopLib.lookupFunction<_PausedNative, _PausedDart>(
  'emulator_loop_set_paused',
);

typedef _IsRunNative = Bool Function();
typedef _IsRunDart = bool Function();
final isLoopRunning = emuLoopLib.lookupFunction<_IsRunNative, _IsRunDart>(
  'emulator_loop_is_running',
);

// ── Input ──────────────────────────────────────────────────────────────────
typedef _SetInputNative = Void Function(Int32, Bool);
typedef _SetInputDart = void Function(int, bool);
final setInputBit = emuLoopLib.lookupFunction<_SetInputNative, _SetInputDart>(
  'emulator_loop_set_input_bit',
);

final clearInputs = emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
  'emulator_loop_clear_inputs',
);

typedef _SetPortInputNative = Void Function(Uint32, Uint64);
typedef _SetPortInputDart = void Function(int, int);
final setPortInputMask = emuLoopLib
    .lookupFunction<_SetPortInputNative, _SetPortInputDart>(
      'emulator_loop_set_port_input_mask',
    );

typedef _SetInputForPortNative = Void Function(Uint32, Int32, Bool);
typedef _SetInputForPortDart = void Function(int, int, bool);
final setInputBitForPort = emuLoopLib
    .lookupFunction<_SetInputForPortNative, _SetInputForPortDart>(
      'emulator_loop_set_input_bit_for_port',
    );

// ── Audio ring buffer ──────────────────────────────────────────────────────
typedef _AvailNative = Int32 Function();
typedef _AvailDart = int Function();
final audioAvailable = emuLoopLib.lookupFunction<_AvailNative, _AvailDart>(
  'emulator_loop_audio_available',
);

typedef _ReadNative = Int32 Function(Pointer<Int16>, Int32);
typedef _ReadDart = int Function(Pointer<Int16>, int);
final _audioRead = emuLoopLib.lookupFunction<_ReadNative, _ReadDart>(
  'emulator_loop_audio_read',
);

/// Pre-allocated scratch buffer (avoids GC pressure per drain call).
const int _audioScratchSamples = 16384;
final Pointer<Int16> _audioBuf = calloc<Int16>(_audioScratchSamples);

/// Drain up to [maxSamples] int16 samples from the ring buffer.
/// Returns a copy so the next drain cannot race with SoLoud on another thread.
Int16List? drainAudio({int maxSamples = 4096}) {
  final avail = audioAvailable();
  if (avail <= 0) return null;
  final n = avail.clamp(0, maxSamples.clamp(0, _audioScratchSamples));
  final read = _audioRead(_audioBuf, n);
  if (read <= 0) return null;
  return Int16List.fromList(_audioBuf.asTypedList(read));
}

// ── Frame counter ──────────────────────────────────────────────────────────
typedef _FrameCountNative = Uint64 Function();
typedef _FrameCountDart = int Function();
final _frameCount = emuLoopLib
    .lookupFunction<_FrameCountNative, _FrameCountDart>(
      'emulator_loop_frame_count',
    );

int nativeFrameCount() => _frameCount();

/// Frames actually shown via Flutter Texture (iOS CADisplayLink).
typedef _PresentedFramesNative = Uint64 Function();
typedef _PresentedFramesDart = int Function();
final _PresentedFramesDart? _presentedFramesLookup = Platform.isIOS
    ? emuLoopLib.lookupFunction<_PresentedFramesNative, _PresentedFramesDart>(
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
final _audioStart = emuLoopLib
    .lookupFunction<_AudioStartNative, _AudioStartDart>(
      'emulator_loop_audio_start',
    );

final _audioStop = emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
  'emulator_loop_audio_stop',
);

typedef _AudioPausedNative = Void Function(Bool);
typedef _AudioPausedDart = void Function(bool);
final _audioSetPaused = emuLoopLib
    .lookupFunction<_AudioPausedNative, _AudioPausedDart>(
      'emulator_loop_audio_set_paused',
    );

typedef _SetTargetRateNative = Void Function(Uint32);
typedef _SetTargetRateDart = void Function(int);
final _setTargetSampleRate = emuLoopLib
    .lookupFunction<_SetTargetRateNative, _SetTargetRateDart>(
      'emulator_loop_set_target_sample_rate',
    );

typedef _GetReportedRateNative = Double Function();
typedef _GetReportedRateDart = double Function();
final _getReportedSampleRate = emuLoopLib
    .lookupFunction<_GetReportedRateNative, _GetReportedRateDart>(
      'emulator_loop_get_reported_sample_rate',
    );

/// Cores can resample to this rate in [retro_load_game]. Call before loading ROM.
void setTargetSampleRate(int sampleRate) =>
    _setTargetSampleRate(sampleRate.clamp(8000, 192000));

double getReportedSampleRate() => _getReportedSampleRate();

final _audioFlush = emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
  'emulator_loop_audio_flush',
);

void flushAudioRing() => _audioFlush();

final _resetVideoState = emuLoopLib.lookupFunction<_VoidNative, _VoidDart>(
  'emulator_loop_reset_video_state',
);

/// Reset native state after a short libretro probe (thumbnail / import verify).
void resetLibretroProbeSession() {
  clearInputs();
  flushAudioRing();
  _resetVideoState();
  resetControllerPortCount();
  setEmulationSpeed(1);
}

typedef _SetPresentNative = Void Function(Bool);
typedef _SetPresentDart = void Function(bool);
final _setPresentToTexture = emuLoopLib
    .lookupFunction<_SetPresentNative, _SetPresentDart>(
      'emulator_loop_set_present_to_texture',
    );

/// When false, [retro_run] only fills the thumbnail buffer (no Android Surface).
void setPresentToTexture(bool enable) => _setPresentToTexture(enable);

final _setSilentFrameOutput = emuLoopLib
    .lookupFunction<_SetPresentNative, _SetPresentDart>(
      'emulator_loop_set_silent_frame_output',
    );

/// Suppresses video/audio callback output during rollback resimulation.
void setSilentFrameOutput(bool enable) => _setSilentFrameOutput(enable);

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
final _setEmulationSpeed = emuLoopLib
    .lookupFunction<_SetSpeedNative, _SetSpeedDart>('emulator_loop_set_speed');

typedef _SetAudioSpeedNative = Void Function(Int32);
typedef _SetAudioSpeedDart = void Function(int);
final _setAudioPlaybackSpeed = Platform.isIOS
    ? emuLoopLib.lookupFunction<_SetAudioSpeedNative, _SetAudioSpeedDart>(
        'emulator_loop_audio_set_playback_speed',
      )
    : null;

/// Fast-forward: run [speed] retro_run calls per frame period (1–3).
void setEmulationSpeed(int speed) {
  final clamped = speed.clamp(1, 3);
  _setEmulationSpeed(clamped);
  _setAudioPlaybackSpeed?.call(clamped);
}

// ── Rumble events ─────────────────────────────────────────────────────────
typedef _RumbleSeqNative = Uint64 Function();
typedef _RumbleSeqDart = int Function();
final _rumbleSequence = emuLoopLib
    .lookupFunction<_RumbleSeqNative, _RumbleSeqDart>(
      'emulator_loop_rumble_sequence',
    );

typedef _RumbleStrengthNative = Uint32 Function();
typedef _RumbleStrengthDart = int Function();
final _rumbleStrong = emuLoopLib
    .lookupFunction<_RumbleStrengthNative, _RumbleStrengthDart>(
      'emulator_loop_rumble_strong',
    );
final _rumbleWeak = emuLoopLib
    .lookupFunction<_RumbleStrengthNative, _RumbleStrengthDart>(
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
final _lastFrame = emuLoopLib.lookupFunction<_LastFrameNative, _LastFrameDart>(
  'emulator_loop_last_frame',
);

/// Result of [captureLastFrame].
class FrameCapture {
  final Uint8List rgba;
  final int width;
  final int height;
  const FrameCapture(this.rgba, this.width, this.height);
}

const int _maxCapturedFrameBytes = 1024 * 1024 * 4;

typedef _FrameSerialNative = Uint64 Function();
typedef _FrameSerialDart = int Function();
final _lastFrameSerial = emuLoopLib
    .lookupFunction<_FrameSerialNative, _FrameSerialDart>(
      'emulator_loop_last_frame_serial',
    );

/// Bumps only when libretro delivers non-null video_refresh data.
int lastFrameSerial() => _lastFrameSerial();

/// Last rendered width/height (no pixel copy).
({int width, int height})? lastRenderedSize() {
  final wPtr = calloc<Int32>();
  final hPtr = calloc<Int32>();
  try {
    final ptr = _lastFrame(wPtr, hPtr);
    if (ptr == nullptr) {
      return null;
    }
    final w = wPtr.value;
    final h = hPtr.value;
    if (w <= 0 || h <= 0) {
      return null;
    }
    return (width: w, height: h);
  } finally {
    calloc.free(wPtr);
    calloc.free(hPtr);
  }
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
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return null;
    final byteCount = w * h * 4;
    if (byteCount <= 0 || byteCount > _maxCapturedFrameBytes) return null;
    // Copy because gConvBuf can be overwritten on the emulation thread.
    return FrameCapture(Uint8List.fromList(ptr.asTypedList(byteCount)), w, h);
  } finally {
    calloc.free(wPtr);
    calloc.free(hPtr);
  }
}
