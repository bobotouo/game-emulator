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
  static const int _streamMaxBufferBytes = 1024 * 1024 * 8;

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
    if (kDebugMode) return;
    if (SoLoud.instance.isInitialized) return;
    try {
      await SoLoud.instance.init(sampleRate: 48000, channels: Channels.stereo);
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

  Future<void> initialize({required double sampleRate, double volume = 1}) {
    return _enqueue(() async {
      _shuttingDown = false;
      _sampleRate = sampleRate;
      _volume = volume;
      _speed = 1;

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
        maxBufferSizeBytes: _streamMaxBufferBytes,
        bufferingType: BufferingType.preserved,
        bufferingTimeNeeds: 0.05,
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
    } catch (error, stackTrace) {
      debugPrint('AudioOutputService _startStream: $error\n$stackTrace');
      _stream = null;
      _handle = null;
      _playing = false;
      _ready = false;
    }
  }

  void setSpeed(double speed) {
    final next = speed.clamp(1.0, 3.0);
    if (_speed == next) return;
    _speed = next;
    if (_useNativeAudio) {
      emu_loop.setEmulationSpeed(next.round());
      return;
    }
  }

  void addSamples(Int16List samples) {
    if (_useNativeAudio || _shuttingDown) return;
    final stream = _stream;
    if (!_ready || _mutedByError || stream == null || samples.isEmpty) {
      return;
    }

    final outputSamples = _speed > 1.0
        ? _thinFastForwardSamples(samples)
        : samples;
    final bytes = Uint8List.fromList(
      outputSamples.buffer.asUint8List(
        outputSamples.offsetInBytes,
        outputSamples.lengthInBytes,
      ),
    );

    try {
      SoLoud.instance.addAudioDataStream(stream, bytes);
    } on SoLoudStreamEndedAlreadyCppException {
      _restartStreamAfterError();
    } on SoLoudPcmBufferFullCppException {
      _resetPreservedStream();
    } catch (error, stackTrace) {
      _mutedByError = true;
      debugPrint('AudioOutputService addSamples: $error\n$stackTrace');
    }
  }

  Int16List _thinFastForwardSamples(Int16List samples) {
    final step = _speed.round().clamp(1, 3);
    if (step <= 1 || samples.length < 4) {
      return samples;
    }

    final inputFrames = samples.length ~/ 2;
    final outputFrames = (inputFrames + step - 1) ~/ step;
    final output = Int16List(outputFrames * 2);
    var out = 0;
    for (var frame = 0; frame < inputFrames; frame += step) {
      var left = 0;
      var right = 0;
      var count = 0;
      for (var i = 0; i < step && frame + i < inputFrames; i++) {
        final input = (frame + i) * 2;
        left += samples[input];
        right += samples[input + 1];
        count++;
      }
      output[out++] = left ~/ count;
      output[out++] = right ~/ count;
    }
    return output;
  }

  void _resetPreservedStream() {
    final stream = _stream;
    if (stream == null || _shuttingDown || _useNativeAudio) {
      return;
    }
    try {
      SoLoud.instance.resetBufferStream(stream);
    } catch (_) {
      _restartStreamAfterError();
    }
  }

  void _restartStreamAfterError() {
    if (_shuttingDown || _useNativeAudio) {
      return;
    }
    try {
      final stream = _stream;
      final handle = _handle;
      _stream = null;
      _handle = null;
      _playing = false;
      _ready = false;
      if (handle != null) {
        unawaited(SoLoud.instance.stop(handle));
      }
      if (stream != null) {
        unawaited(SoLoud.instance.disposeSource(stream));
      }
      _startStream();
      _ready = _stream != null && _handle != null;
      _mutedByError = !_ready;
    } catch (error, stackTrace) {
      _mutedByError = true;
      debugPrint('AudioOutputService restart stream: $error\n$stackTrace');
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
