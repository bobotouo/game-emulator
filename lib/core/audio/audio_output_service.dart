import 'dart:typed_data';

import 'package:flutter_soloud/flutter_soloud.dart';

/// Streams libretro PCM samples to the platform audio output.
class AudioOutputService {
  AudioSource? _stream;
  SoundHandle? _handle;
  bool _ready = false;
  bool _mutedByError = false;
  bool _playing = false;
  bool _paused = false;
  double _sampleRate = 32768;
  double _coreFps = 59.73;
  double _volume = 1;
  double _speed = 1;
  int _bufferedBeforePlay = 0;
  int _startPlaybackBytes = 4096;

  bool get isReady => _ready;
  bool get isPlaying => _playing;

  Future<void> initialize({
    required double sampleRate,
    double fps = 59.73,
    double volume = 1,
  }) async {
    _sampleRate = sampleRate;
    _coreFps = fps;
    _volume = volume;

    final samplesPerFrame = (_sampleRate / _coreFps).round().clamp(1, 8192);
    _startPlaybackBytes = samplesPerFrame * 4 * 2;

    if (_ready) return;

    if (!SoLoud.instance.isInitialized) {
      await SoLoud.instance.init();
    }

    _stream = _createStream();
    _ready = true;
    _mutedByError = false;
    _playing = false;
    _bufferedBeforePlay = 0;
  }

  AudioSource _createStream() {
    _stream = SoLoud.instance.setBufferStream(
      maxBufferSizeDuration: const Duration(milliseconds: 800),
      bufferingType: BufferingType.released,
      bufferingTimeNeeds: 0.05,
      sampleRate: _sampleRate.round(),
      channels: Channels.stereo,
      format: BufferType.s16le,
    );
    return _stream!;
  }

  void setSpeed(double speed) {
    _speed = speed.clamp(1.0, 5.0);
    _applyPlaySpeed();
  }

  void _applyPlaySpeed() {
    final handle = _handle;
    if (!_ready || handle == null || !_playing) return;

    try {
      SoLoud.instance.setRelativePlaySpeed(handle, _speed);
    } catch (_) {}
  }

  void addSamples(Int16List samples) {
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
      if (!_playing) {
        _bufferedBeforePlay += bytes.length;
        if (_bufferedBeforePlay >= _startPlaybackBytes) {
          _handle = SoLoud.instance.play(
            stream,
            volume: _volume,
            paused: _paused,
          );
          _playing = true;
          _applyPlaySpeed();
        }
      }
    } on SoLoudStreamEndedAlreadyCppException {
      _restartStream();
    } on SoLoudPcmBufferFullCppException {
      // Drop saturated chunks instead of spamming logs or blocking emulation.
    } catch (_) {
      _mutedByError = true;
    }
  }

  void _restartStream() {
    _stream = _createStream();
    _handle = null;
    _playing = false;
    _bufferedBeforePlay = 0;
  }

  void setPaused(bool paused) {
    _paused = paused;
    final handle = _handle;
    if (!_ready || handle == null) return;

    try {
      SoLoud.instance.setPause(handle, paused);
    } catch (_) {}
  }

  /// Immediately stop playback and discard buffered audio.
  Future<void> stop() async {
    final stream = _stream;
    final handle = _handle;

    _playing = false;
    _paused = false;
    _bufferedBeforePlay = 0;
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
