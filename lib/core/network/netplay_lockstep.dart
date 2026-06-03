import 'dart:async';
import 'dart:ffi';

import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import 'netplay_input_sync.dart';

/// Fixed input delay for lockstep (frames to buffer before sim).
const int kDefaultNetplayInputDelayFrames = 3;

/// Config broadcast when all players are loaded and lockstep begins.
class LockstepStartConfig {
  const LockstepStartConfig({
    required this.startFrame,
    required this.fps,
    required this.requiredSlots,
    this.inputDelayFrames = kDefaultNetplayInputDelayFrames,
  });

  final int startFrame;
  final double fps;
  final List<int> requiredSlots;
  final int inputDelayFrames;
}

/// Host-authoritative lockstep with optional fixed input delay.
///
/// New samples are tagged at [_frame + inputDelayFrames]. The host keeps the
/// frame clock stable; if a remote sample misses its target frame, the
/// authoritative bundle repeats that player's last known input instead of
/// stalling every core.
class NetplayLockstepRunner {
  NetplayLockstepRunner({
    required this.localSlot,
    required this.isHost,
    required Set<int> requiredSlots,
    required this.retroRunPtr,
    required this.onSendInput,
    this.onFrameComplete,
    this.onFrameAdvanced,
    int inputDelayFrames = kDefaultNetplayInputDelayFrames,
  }) : _requiredSlots = Set<int>.from(requiredSlots),
       _inputDelayFrames = inputDelayFrames.clamp(0, 8);

  final int localSlot;
  final bool isHost;
  final Pointer<NativeFunction<Void Function()>> retroRunPtr;
  final void Function(int frame, int slot, int buttons) onSendInput;
  final void Function(int frame, Map<int, int> inputs)? onFrameComplete;
  final void Function()? onFrameAdvanced;
  int _inputDelayFrames;

  int _frame = 0;
  int _localButtonMask = 0;
  bool _running = false;
  Timer? _tickTimer;
  Timer? _guestSendTimer;
  double _fps = 60.0;
  int _speed = 1;
  Set<int> _requiredSlots;
  int? _publishingFrame;
  int _lastPublishedLocalMask = 0;

  /// frame index -> slot -> button mask (host scheduling).
  final Map<int, Map<int, int>> _scheduledInputs = {};
  final Map<int, Map<int, int>> _pendingFrameBundles = {};
  final Map<int, int> _latestRemoteMask = {};

  void setRequiredSlots(Set<int> slots) {
    _requiredSlots = Set<int>.from(slots);
  }

  void setInputDelayFrames(int frames) {
    if (_running) {
      return;
    }
    _inputDelayFrames = frames.clamp(0, 8);
  }

  int get frame => _frame;
  bool get isRunning => _running;
  int get inputDelayFrames => _inputDelayFrames;

  void setSpeed(int speed) {
    final next = speed.clamp(1, 3);
    if (_speed == next) {
      return;
    }
    _speed = next;
    if (!_running) {
      return;
    }
    if (isHost) {
      _scheduleHostTick();
    } else {
      _scheduleGuestSend();
    }
  }

  void start({required double fps, int startFrame = 0}) {
    _fps = fps > 0 ? fps : 60.0;
    _frame = startFrame;
    _running = true;
    _publishingFrame = null;
    _lastPublishedLocalMask = _localButtonMask;
    _scheduledInputs.clear();
    _pendingFrameBundles.clear();
    _latestRemoteMask.clear();

    emu_loop.stopNativeLoop();
    emu_loop.waitUntilEmulatorStopped();
    emu_loop.endNetplaySnapshots();

    for (final slot in _requiredSlots) {
      if (slot != localSlot) {
        _latestRemoteMask[slot] = 0;
      }
    }

    for (var f = 0; f < _inputDelayFrames; f++) {
      _seedBootstrapFrame(f);
    }

    if (isHost) {
      _scheduleHostTick();
    } else {
      _scheduleGuestSend();
      _sendLocalInput();
    }
  }

  void stop() {
    _running = false;
    _tickTimer?.cancel();
    _tickTimer = null;
    _guestSendTimer?.cancel();
    _guestSendTimer = null;
    _publishingFrame = null;
    _lastPublishedLocalMask = 0;
    _scheduledInputs.clear();
    _pendingFrameBundles.clear();
    _latestRemoteMask.clear();
    emu_loop.stopNativeLoop();
    emu_loop.waitUntilEmulatorStopped();
  }

  void updateLocalButtons(int mask) {
    final next = mask & 0xFFFF;
    if (next == _localButtonMask) {
      return;
    }
    _localButtonMask = next;
    if (!_running) {
      return;
    }
    if (isHost) {
      _scheduleInput(_frame + _inputDelayFrames, localSlot, _localButtonMask);
    } else {
      _sendLocalInput();
    }
  }

  /// Host only: attach remote input scheduled for a future frame.
  void receiveRemoteInput(int frame, int slot, int buttons) {
    if (!isHost || !_running) {
      return;
    }
    if (slot <= 0 || slot == localSlot || !_requiredSlots.contains(slot)) {
      return;
    }
    if (frame < _frame) {
      return;
    }
    buttons &= 0xFFFF;
    _scheduleInput(frame, slot, buttons);
  }

  /// Both sides: run one frame with the authoritative bundle from the host.
  void applyFrameBundle(int frame, Map<int, int> inputs) {
    if (!_running) {
      _releasePublishLock(frame);
      return;
    }
    if (frame < _frame) {
      _releasePublishLock(frame);
      return;
    }
    if (frame > _frame) {
      _pendingFrameBundles[frame] = Map<int, int>.from(inputs);
      _prunePendingFrameBundles();
      return;
    }

    if (!_applyCurrentFrameBundle(frame, inputs)) {
      _releasePublishLock(frame);
      return;
    }
    _drainPendingFrameBundles();
  }

  bool _applyCurrentFrameBundle(int frame, Map<int, int> inputs) {
    if (frame != _frame) {
      return false;
    }
    for (final slot in _requiredSlots) {
      if (!inputs.containsKey(slot)) {
        return false;
      }
    }

    emu_loop.clearInputs();
    for (final entry in inputs.entries) {
      applyNetplayInputMask(netplaySlotToLibretroPort(entry.key), entry.value);
      if (entry.key == localSlot) {
        _lastPublishedLocalMask = entry.value & 0xFFFF;
      } else {
        _latestRemoteMask[entry.key] = entry.value & 0xFFFF;
      }
    }
    emu_loop.advanceEmulatorFrame(retroRunPtr);
    _scheduledInputs.remove(frame);
    _publishingFrame = null;
    _frame++;
    onFrameAdvanced?.call();
    if (!isHost) {
      _sendLocalInput();
    }
    return true;
  }

  void _drainPendingFrameBundles() {
    while (_running) {
      final inputs = _pendingFrameBundles.remove(_frame);
      if (inputs == null) {
        return;
      }
      if (!_applyCurrentFrameBundle(_frame, inputs)) {
        return;
      }
    }
  }

  void _prunePendingFrameBundles() {
    _pendingFrameBundles.removeWhere((frame, _) => frame < _frame);
    if (_pendingFrameBundles.length <= 12) {
      return;
    }
    final frames = _pendingFrameBundles.keys.toList()..sort();
    for (final frame in frames.take(_pendingFrameBundles.length - 12)) {
      _pendingFrameBundles.remove(frame);
    }
  }

  /// Ensures [_frame] has every required slot before publish (host).
  Map<int, int>? _inputsForPublishFrame(int frame) {
    final scheduled = _scheduledInputs.putIfAbsent(frame, () => <int, int>{});
    final out = <int, int>{};
    for (final slot in _requiredSlots) {
      if (slot == localSlot) {
        out[slot] = scheduled.putIfAbsent(
          slot,
          () => _lastPublishedLocalMask & 0xFFFF,
        );
      } else {
        out[slot] = scheduled[slot] ?? _latestRemoteMask[slot] ?? 0;
      }
    }
    return out;
  }

  void _seedBootstrapFrame(int frame) {
    if (frame < 0) {
      return;
    }
    final map = _scheduledInputs.putIfAbsent(frame, () => <int, int>{});
    map[localSlot] = _localButtonMask;
    for (final slot in _requiredSlots) {
      if (slot == localSlot) {
        continue;
      }
      map.putIfAbsent(slot, () => _latestRemoteMask[slot] ?? 0);
    }
  }

  void _scheduleInput(int frame, int slot, int buttons) {
    if (frame < 0) {
      return;
    }
    final map = _scheduledInputs.putIfAbsent(frame, () => <int, int>{});
    map[slot] = buttons & 0xFFFF;
  }

  void _scheduleHostTick() {
    _tickTimer?.cancel();
    if (!_running || !isHost) {
      return;
    }
    final effectiveFps = _fps * _speed;
    final period = Duration(
      microseconds: (1000000 / effectiveFps).round().clamp(1, 1000000),
    );
    _tickTimer = Timer.periodic(period, (_) => _onHostTick());
    _onHostTick();
  }

  void _scheduleGuestSend() {
    _guestSendTimer?.cancel();
    if (!_running || isHost) {
      return;
    }
    final effectiveFps = _fps * _speed;
    final period = Duration(
      microseconds: (1000000 / effectiveFps).round().clamp(1, 1000000),
    );
    _guestSendTimer = Timer.periodic(period, (_) => _sendLocalInput());
  }

  void _onHostTick() {
    if (!_running || !isHost) {
      return;
    }
    _scheduleInput(_frame + _inputDelayFrames, localSlot, _localButtonMask);
    _tryPublishFrame();
  }

  void _tryPublishFrame() {
    if (!isHost || !_running || _publishingFrame == _frame) {
      return;
    }
    final inputs = _inputsForPublishFrame(_frame);
    if (inputs == null) {
      return;
    }
    for (final slot in _requiredSlots) {
      if (!inputs.containsKey(slot)) {
        return;
      }
    }

    _publishingFrame = _frame;
    onFrameComplete?.call(_frame, inputs);
  }

  void _releasePublishLock(int frame) {
    if (isHost && _publishingFrame == frame) {
      _publishingFrame = null;
    }
  }

  void _sendLocalInput() {
    onSendInput(_frame + _inputDelayFrames, localSlot, _localButtonMask);
  }
}
