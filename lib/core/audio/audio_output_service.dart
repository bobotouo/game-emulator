import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter_soloud/flutter_soloud.dart';

import 'audio_debug.dart';
import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;

/// Streams libretro PCM to platform audio.
/// Android: SoLoud + AAudio — engine stays alive; ops are serialized to avoid races.
class AudioOutputService {
  AudioOutputService._();

  static final AudioOutputService instance = AudioOutputService._();

  AudioSource? _stream;
  SoundHandle? _handle;
  bool _ready = false;
  bool _shuttingDown = false;
  bool _mutedByError = false;
  bool _playing = false;
  bool _paused = false;
  bool _useNativeAudio = false;
  double _sampleRate = 32768;
  double _volume = 1;
  double _speed = 1;

  /// Serializes init/stop/restart so exit + re-enter cannot overlap AAudio calls.
  Future<void> _opChain = Future.value();

  bool get isReady => _ready;
  bool get isPlaying => _playing;
  bool get usesNativeAudio => _useNativeAudio;

  Future<T> _enqueue<T>(Future<T> Function() action) {
    final run = _opChain.then((_) => action());
    _opChain = run.then((_) {}, onError: (_) {});
    return run;
  }

  /// Call once from [main] on Android so the first game does not cold-start AAudio.
  static Future<void> warmUpEngine() async {
    if (!Platform.isAndroid) return;
    if (SoLoud.instance.isInitialized) return;
    try {
      await SoLoud.instance.init(
        sampleRate: 48000,
        channels: Channels.stereo,
      );
      logAudio('SoLoud warmUpEngine ok');
    } catch (error, stackTrace) {
      debugPrint('AudioOutputService warmUpEngine: $error\n$stackTrace');
    }
  }

  void beginShutdown() {
    _shuttingDown = true;
    _ready = false;
    _playing = false;
  }

  Future<void> initialize({
    required double sampleRate,
    double volume = 1,
  }) {
    return _enqueue(() async {
      _shuttingDown = false;
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
      await _disposeStream();

      if (Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 80));
      }

      if (_shuttingDown) return;

      if (!SoLoud.instance.isInitialized) {
        await SoLoud.instance.init(
          sampleRate: _sampleRate.round().clamp(8000, 192000),
          channels: Channels.stereo,
        );
      }

      if (_shuttingDown) return;

      _startStream();
      _ready = _stream != null && _handle != null;
      _mutedByError = false;
    });
  }

  void _startStream() {
    if (_shuttingDown || _useNativeAudio) return;

    try {
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
    } catch (error, stackTrace) {
      debugPrint('AudioOutputService _startStream: $error\n$stackTrace');
      _stream = null;
      _handle = null;
      _playing = false;
      _ready = false;
    }
  }

  void setSpeed(double speed) {
    final next = speed.clamp(1.0, 5.0);
    if (_speed == next) return;
    _speed = next;
    if (_useNativeAudio) {
      emu_loop.setEmulationSpeed(next.round());
      return;
    }
    _applyPlaySpeed();
  }

  void _applyPlaySpeed() {
    if (_useNativeAudio || _shuttingDown) return;
    final handle = _handle;
    if (!_ready || handle == null || !_playing) return;

    try {
      SoLoud.instance.setRelativePlaySpeed(handle, _speed);
    } catch (_) {}
  }

  void addSamples(Int16List samples) {
    if (_useNativeAudio || _shuttingDown) return;
    final stream = _stream;
    if (!_ready || _mutedByError || stream == null || samples.isEmpty) {
      return;
    }

    final bytes = Uint8List.fromList(
      samples.buffer.asUint8List(
        samples.offsetInBytes,
        samples.lengthInBytes,
      ),
    );

    try {
      SoLoud.instance.addAudioDataStream(stream, bytes);
    } on SoLoudStreamEndedAlreadyCppException {
      // Do not restart AAudio on Android — causes SIGSEGV on some devices.
      _mutedByError = true;
      _ready = false;
    } on SoLoudPcmBufferFullCppException {
      // Drop when saturated.
    } catch (error, stackTrace) {
      _mutedByError = true;
      debugPrint('AudioOutputService addSamples: $error\n$stackTrace');
    }
  }

  Future<void> _disposeStream() async {
    final stream = _stream;
    final handle = _handle;

    _stream = null;
    _handle = null;
    _playing = false;
    _ready = false;

    if (stream == null && handle == null) return;

    try {
      if (handle != null) {
        await SoLoud.instance.stop(handle);
      }
      if (stream != null) {
        SoLoud.instance.setDataIsEnded(stream);
        await SoLoud.instance.disposeSource(stream);
      }
    } catch (error, stackTrace) {
      debugPrint('AudioOutputService dispose stream: $error\n$stackTrace');
    }
  }

  void setPaused(bool paused) {
    _paused = paused;
    if (_useNativeAudio) {
      emu_loop.setNativeAudioPaused(paused);
      return;
    }
    final handle = _handle;
    if (_shuttingDown || !_ready || handle == null) return;

    try {
      SoLoud.instance.setPause(handle, paused);
    } catch (_) {}
  }

  Future<void> stop() {
    return _enqueue(() async {
      beginShutdown();

      if (_useNativeAudio) {
        emu_loop.stopNativeAudio();
        _useNativeAudio = false;
        _paused = false;
        return;
      }

      emu_loop.flushAudioRing();
      await _disposeStream();

      if (Platform.isAndroid) {
        await Future<void>.delayed(const Duration(milliseconds: 120));
      }

      // Keep SoLoud engine alive — deinit + rapid play() crashes AAudio on vivo.
      _paused = false;
      _shuttingDown = false;
      _mutedByError = false;
    });
  }

  Future<void> dispose() async {
    await stop();
  }
}
