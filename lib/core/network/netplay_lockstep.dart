import 'dart:async';
import 'dart:ffi';

import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import 'netplay_input_sync.dart';

/// Config broadcast when all players are loaded and lockstep begins.
class LockstepStartConfig {
  const LockstepStartConfig({
    required this.startFrame,
    required this.fps,
    required this.requiredSlots,
  });

  final int startFrame;
  final double fps;
  final List<int> requiredSlots;
}

/// Frame-perfect lockstep with a single frame clock on the host.
///
/// Guest reports `{slot, buttons}` without a frame number; the host attaches
/// them to its current frame, then publishes one authoritative bundle that
/// both cores consume identically.
class NetplayLockstepRunner {
  NetplayLockstepRunner({
    required this.localSlot,
    required this.isHost,
    required Set<int> requiredSlots,
    required this.retroRunPtr,
    required this.onSendInput,
    this.onFrameComplete,
    this.onFrameAdvanced,
  }) : _requiredSlots = Set<int>.from(requiredSlots);

  final int localSlot;
  final bool isHost;
  final Pointer<NativeFunction<Void Function()>> retroRunPtr;
  final void Function(int slot, int buttons) onSendInput;
  final void Function(int frame, Map<int, int> inputs)? onFrameComplete;
  final void Function()? onFrameAdvanced;

  int _frame = 0;
  int _localButtonMask = 0;
  bool _running = false;
  Timer? _tickTimer;
  Timer? _guestSendTimer;
  double _fps = 60.0;
  Set<int> _requiredSlots;
  int? _publishingFrame;

  /// Inputs collected for the current frame (host only).
  final Map<int, int> _frameInputs = {};
  final Map<int, int> _latestRemoteMask = {};

  void setRequiredSlots(Set<int> slots) {
    _requiredSlots = Set<int>.from(slots);
  }

  int get frame => _frame;
  bool get isRunning => _running;

  void start({required double fps, int startFrame = 0}) {
    _fps = fps > 0 ? fps : 60.0;
    _frame = startFrame;
    _running = true;
    _publishingFrame = null;
    _frameInputs.clear();
    _latestRemoteMask.clear();
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
    _frameInputs.clear();
    _latestRemoteMask.clear();
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
      _frameInputs[localSlot] = _localButtonMask;
      _tryPublishFrame();
    } else {
      _sendLocalInput();
    }
  }

  /// Host only: attach remote input to the host's current frame.
  void receiveRemoteInput(int slot, int buttons) {
    if (!isHost || !_running) {
      return;
    }
    if (slot <= 0 || slot == localSlot || !_requiredSlots.contains(slot)) {
      return;
    }
    _latestRemoteMask[slot] = buttons & 0xFFFF;
    _frameInputs[slot] = buttons & 0xFFFF;
    _tryPublishFrame();
  }

  /// Both sides: run one frame with the authoritative bundle from the host.
  void applyFrameBundle(int frame, Map<int, int> inputs) {
    if (!_running || frame != _frame) {
      _releasePublishLock(frame);
      return;
    }
    for (final slot in _requiredSlots) {
      if (!inputs.containsKey(slot)) {
        _releasePublishLock(frame);
        return;
      }
    }

    emu_loop.clearInputs();
    for (final entry in inputs.entries) {
      applyNetplayInputMask(netplaySlotToLibretroPort(entry.key), entry.value);
    }

    emu_loop.runSyncFrames(retroRunPtr, 1);
    _frameInputs.clear();
    _publishingFrame = null;
    _frame++;
    onFrameAdvanced?.call();
    if (!isHost) {
      _sendLocalInput();
    }
  }

  void _scheduleHostTick() {
    _tickTimer?.cancel();
    if (!_running || !isHost) {
      return;
    }
    final period = Duration(
      microseconds: (1000000 / _fps).round().clamp(1, 1000000),
    );
    _tickTimer = Timer.periodic(period, (_) => _onHostTick());
    _onHostTick();
  }

  void _scheduleGuestSend() {
    _guestSendTimer?.cancel();
    if (!_running || isHost) {
      return;
    }
    final period = Duration(
      microseconds: (1000000 / _fps).round().clamp(1, 1000000),
    );
    _guestSendTimer = Timer.periodic(period, (_) => _sendLocalInput());
  }

  void _onHostTick() {
    if (!_running || !isHost) {
      return;
    }
    _frameInputs[localSlot] = _localButtonMask;
    for (final slot in _requiredSlots) {
      if (slot == localSlot) {
        continue;
      }
      final latest = _latestRemoteMask[slot];
      if (latest != null) {
        _frameInputs[slot] = latest;
      }
    }
    _tryPublishFrame();
  }

  void _tryPublishFrame() {
    if (!isHost || !_running || _publishingFrame == _frame) {
      return;
    }
    for (final slot in _requiredSlots) {
      if (!_frameInputs.containsKey(slot)) {
        return;
      }
    }

    _publishingFrame = _frame;
    onFrameComplete?.call(_frame, Map<int, int>.from(_frameInputs));
  }

  void _releasePublishLock(int frame) {
    if (isHost && _publishingFrame == frame) {
      _publishingFrame = null;
    }
  }

  void _sendLocalInput() {
    onSendInput(localSlot, _localButtonMask);
  }
}
