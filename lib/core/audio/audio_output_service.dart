import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'audio_debug.dart';
import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;

/// Streams libretro PCM to platform audio.
/// iOS: AVAudioEngine pulls from the native ring buffer (Delta-style).
/// Other platforms: SoLoud via Dart timer drain.
class AudioOutputService {
  AudioSource? _stream;
  SoundHandle? _handle;
  bool _ready = false;
  bool _mutedByError = false;
  bool _playing = false;
  bool _paused = false;
  bool _useNativeAudio = false;
  double _sampleRate = 32768;
  double _volume = 1;
  double _speed = 1;
  bool get isReady => _ready;
  bool get isPlaying => _playing;
  bool get usesNativeAudio => _useNativeAudio;

  Future<void> initialize({
    required double sampleRate,
    double volume = 1,
  }) async {
    _sampleRate = sampleRate;
    _volume = volume;

    if (Platform.isIOS) {
      logAudio(
        'startNativeAudio: dart sampleRate=$sampleRate '
        'reported=${emu_loop.getReportedSampleRate()}',
      );
      emu_loop.startNativeAudio(sampleRate);
      _useNativeAudio = true;
      _ready = true;
      _playing = true;
      _mutedByError = false;
      return;
    }

    _useNativeAudio = false;

    if (_ready) {
      await _restartStream();
      return;
    }

    if (!SoLoud.instance.isInitialized) {
      await SoLoud.instance.init(
        sampleRate: _sampleRate.round().clamp(8000, 192000),
        channels: Channels.stereo,
      );
    }

    _startStream();
    _ready = true;
    _mutedByError = false;
  }

  void _startStream() {
    _stream = SoLoud.instance.setBufferStream(
      maxBufferSizeDuration: const Duration(milliseconds: 1200),
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.1,
      sampleRate: _sampleRate.round(),
      channels: Channels.stereo,
      format: BufferType.s16le,
    );

    _handle = SoLoud.instance.play(
      _stream!,
      volume: _volume,
      paused: _paused,
    );
    _playing = true;
    _applyPlaySpeed();
  }

  void setSpeed(double speed) {
    final next = speed.clamp(1.0, 5.0);
    if (_speed == next) return;
    _speed = next;
    if (_useNativeAudio) {
      // Speed is driven by native emulation + audio ring discard (iOS).
      emu_loop.setEmulationSpeed(next.round());
      return;
    }
    _applyPlaySpeed();
  }

  void _applyPlaySpeed() {
    if (_useNativeAudio) return;
    final handle = _handle;
    if (!_ready || handle == null || !_playing) return;

    try {
      SoLoud.instance.setRelativePlaySpeed(handle, _speed);
    } catch (_) {}
  }

  void addSamples(Int16List samples) {
    if (_useNativeAudio) return;
    final stream = _stream;
    if (!_ready || _mutedByError || stream == null || samples.isEmpty) {
      return;
    }

    final bytes = samples.buffer.asUint8List(
      samples.offsetInBytes,
      samples.lengthInBytes,
    );

    try {
      SoLoud.instance.addAudioDataStream(stream, bytes);
    } on SoLoudStreamEndedAlreadyCppException {
      _restartStream();
    } on SoLoudPcmBufferFullCppException {
      // Drop when saturated; emulation must not block.
    } catch (error, stackTrace) {
      _mutedByError = true;
      debugPrint('AudioOutputService error: $error\n$stackTrace');
    }
  }

  Future<void> _restartStream() async {
    final oldStream = _stream;
    final oldHandle = _handle;

    _stream = null;
    _handle = null;
    _playing = false;

    try {
      if (oldHandle != null) {
        await SoLoud.instance.stop(oldHandle);
      }
      if (oldStream != null) {
        SoLoud.instance.setDataIsEnded(oldStream);
        await SoLoud.instance.disposeSource(oldStream);
      }
    } catch (_) {}

    if (SoLoud.instance.isInitialized) {
      _startStream();
      _mutedByError = false;
    }
  }

  void setPaused(bool paused) {
    _paused = paused;
    if (_useNativeAudio) {
      emu_loop.setNativeAudioPaused(paused);
      return;
    }
    final handle = _handle;
    if (!_ready || handle == null) return;

    try {
      SoLoud.instance.setPause(handle, paused);
    } catch (_) {}
  }

  Future<void> stop() async {
    if (_useNativeAudio) {
      emu_loop.stopNativeAudio();
      _useNativeAudio = false;
      _ready = false;
      _playing = false;
      _paused = false;
      return;
    }

    final stream = _stream;
    final handle = _handle;

    _playing = false;
    _paused = false;
    _handle = null;

    try {
      if (handle != null) {
        await SoLoud.instance.stop(handle);
      }
      if (stream != null) {
        SoLoud.instance.setDataIsEnded(stream);
        await SoLoud.instance.disposeSource(stream);
      }
    } catch (_) {}

    _stream = null;
    _ready = false;
  }

  Future<void> dispose() async {
    await stop();
  }
}
