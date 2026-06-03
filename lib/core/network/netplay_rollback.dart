import 'dart:async';
import 'dart:ffi';

import 'package:flutter/foundation.dart';

import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import '../libretro/libretro_bindings.dart';
import 'netplay_input_sync.dart';

/// Default GGPO rollback window.
const int kGgpoRollbackFrames = 30;

/// Small local input delay gives remote inputs time to arrive before prediction.
const int kGgpoInputDelayFrames = 2;

/// Session config broadcast when all players are loaded (wire: LOCKSTEP_START).
class RollbackStartConfig {
  const RollbackStartConfig({
    required this.startFrame,
    required this.fps,
    required this.requiredSlots,
    this.maxRollbackFrames = kGgpoRollbackFrames,
  });

  final int startFrame;
  final double fps;
  final List<int> requiredSlots;
  final int maxRollbackFrames;
}

/// GGPO-style rollback on a single core mutex: one [retro_run] per tick.
///
/// Does not use [startNativeLoop] (that raced with rollback unserialize and
/// crashed FCEUmm). Snapshots are taken on the same thread as [retro_run].
class NetplayRollbackRunner {
  NetplayRollbackRunner({
    required this.localSlot,
    required Set<int> requiredSlots,
    required this.retroRunPtr,
    required this.serializePtr,
    required this.restorePtr,
    required this.stateSize,
    required this.onSendInput,
    this.onFrameAdvanced,
    this.maxRollbackFrames = kGgpoRollbackFrames,
    this.inputDelayFrames = kGgpoInputDelayFrames,
  }) : _requiredSlots = Set<int>.from(requiredSlots);

  final int localSlot;
  final Pointer<NativeFunction<Void Function()>> retroRunPtr;
  final Pointer<NativeFunction<retro_serialize_native>> serializePtr;
  final Pointer<NativeFunction<retro_unserialize_native>> restorePtr;
  final int stateSize;
  final void Function(int frame, int slot, int buttons) onSendInput;
  final void Function()? onFrameAdvanced;
  final int maxRollbackFrames;
  final int inputDelayFrames;

  bool _running = false;
  bool _emulating = false;
  int? _pendingRollbackFrom;
  Timer? _tickTimer;
  double _fps = 60.0;
  int _speed = 1;
  Set<int> _requiredSlots;

  int _localButtonMask = 0;
  int _lastLocalMask = 0;
  DateTime? _lastRollbackAt;

  final Map<int, Map<int, int>> _usedInputsByFrame = {};
  final Map<int, Map<int, int>> _confirmedInputsByFrame = {};
  final Map<int, int> _localInputsByFrame = {};
  final Map<int, int> _lastRemoteMask = {};

  int get frame => emu_loop.netplaySimFrame();
  bool get isRunning => _running;

  void setRequiredSlots(Set<int> slots) {
    _requiredSlots = Set<int>.from(slots);
    for (final slot in _requiredSlots) {
      if (slot != localSlot) {
        _lastRemoteMask.putIfAbsent(slot, () => 0);
      }
    }
  }

  void setSpeed(int speed) {
    _speed = speed.clamp(1, 3);
    if (_running) {
      _scheduleTick();
    }
  }

  void start({required double fps, int startFrame = 0}) {
    _fps = fps > 0 ? fps : 60.0;
    _running = true;
    _emulating = false;
    _pendingRollbackFrom = null;
    _lastRollbackAt = null;
    _lastLocalMask = _localButtonMask;
    _usedInputsByFrame.clear();
    _confirmedInputsByFrame.clear();
    _localInputsByFrame.clear();
    _lastRemoteMask.clear();
    for (final slot in _requiredSlots) {
      if (slot != localSlot) {
        _lastRemoteMask[slot] = 0;
      }
    }

    if (stateSize <= 0) {
      debugPrint('NetplayRollbackRunner: invalid serialize size');
      _running = false;
      return;
    }

    emu_loop.stopNativeLoop();
    emu_loop.waitUntilEmulatorStopped();

    emu_loop.endNetplaySnapshots();
    emu_loop.beginNetplaySnapshots(
      serialize: serializePtr.cast(),
      restore: restorePtr.cast(),
      stateSize: stateSize,
      maxFrames: maxRollbackFrames,
    );
    if (startFrame > 0) {
      emu_loop.netplaySetSimFrame(startFrame);
    }

    _scheduleTick();
  }

  void stop() {
    _running = false;
    _emulating = false;
    _pendingRollbackFrom = null;
    _tickTimer?.cancel();
    _tickTimer = null;
    emu_loop.stopNativeLoop();
    emu_loop.waitUntilEmulatorStopped();
    emu_loop.endNetplaySnapshots();
    _usedInputsByFrame.clear();
    _confirmedInputsByFrame.clear();
    _localInputsByFrame.clear();
    _lastRemoteMask.clear();
  }

  void updateLocalButtons(int mask) {
    _localButtonMask = mask & 0xFFFF;
    if (_running && !_emulating) {
      _scheduleLocalInput(emu_loop.netplaySimFrame() + inputDelayFrames);
    }
  }

  void receiveRemoteInput(int frame, int slot, int buttons) {
    if (!_running || slot == localSlot || !_requiredSlots.contains(slot)) {
      return;
    }
    buttons &= 0xFFFF;
    _lastRemoteMask[slot] = buttons;
    _setConfirmed(frame, slot, buttons);

    final sim = emu_loop.netplaySimFrame();
    if (frame >= sim) {
      return;
    }

    final used = _usedMask(frame, slot);
    if (used != null && used == buttons) {
      return;
    }

    if (sim - frame > maxRollbackFrames) {
      return;
    }

    _queueRollback(fromFrame: frame);
  }

  void _queueRollback({required int fromFrame}) {
    final pending = _pendingRollbackFrom;
    if (pending == null || fromFrame < pending) {
      _pendingRollbackFrom = fromFrame;
    }
    if (!_emulating) {
      _flushPendingRollback();
    }
  }

  void _flushPendingRollback() {
    final from = _pendingRollbackFrom;
    if (from == null || !_running) {
      return;
    }
    _pendingRollbackFrom = null;

    final now = DateTime.now();
    if (_lastRollbackAt != null &&
        now.difference(_lastRollbackAt!) < const Duration(milliseconds: 50)) {
      _pendingRollbackFrom = from;
      return;
    }
    _lastRollbackAt = now;

    _rollbackAndResimulate(fromFrame: from);
    if (_pendingRollbackFrom != null) {
      _flushPendingRollback();
    }
  }

  void _onTick() {
    if (!_running || _emulating) {
      return;
    }
    final runs = _speed;
    for (var i = 0; i < runs; i++) {
      if (!_running || _emulating) {
        return;
      }
      _advanceOneFrame();
    }
  }

  void _advanceOneFrame() {
    _emulating = true;
    try {
      final f = emu_loop.netplaySimFrame();
      _scheduleLocalInput(f + inputDelayFrames);
      final inputs = _buildInputsForFrame(f, predictRemote: true);
      _recordUsedInputs(f, inputs);
      _applyInputs(inputs);
      emu_loop.advanceEmulatorFrame(retroRunPtr);
      _pruneHistory();
      onFrameAdvanced?.call();
    } finally {
      _emulating = false;
      _flushPendingRollback();
    }
  }

  void _rollbackAndResimulate({required int fromFrame}) {
    if (!_running) {
      return;
    }

    _tickTimer?.cancel();
    emu_loop.stopNativeLoop();
    emu_loop.waitUntilEmulatorStopped();

    _emulating = true;
    try {
      final target = emu_loop.netplaySimFrame();
      if (!emu_loop.netplayLoadFrame(fromFrame)) {
        debugPrint(
          'NetplayRollbackRunner: netplayLoadFrame($fromFrame) failed',
        );
        return;
      }
      emu_loop.netplaySetSimFrame(fromFrame);
      emu_loop.setSilentFrameOutput(true);

      for (var f = fromFrame; f < target; f++) {
        final inputs = _buildInputsForFrame(f, predictRemote: false);
        _recordUsedInputs(f, inputs);
        _applyInputs(inputs);
        emu_loop.advanceEmulatorFrame(retroRunPtr);
      }
      _pruneHistory();
    } finally {
      emu_loop.setSilentFrameOutput(false);
      emu_loop.flushAudioRing();
      _emulating = false;
      if (_running) {
        _scheduleTick(runImmediately: false);
      }
    }
  }

  Map<int, int> _buildInputsForFrame(int frame, {required bool predictRemote}) {
    final inputs = <int, int>{};
    for (final slot in _requiredSlots) {
      if (slot == localSlot) {
        inputs[slot] = _localMask(frame);
        continue;
      }

      final confirmed = _confirmedMask(frame, slot);
      if (confirmed != null) {
        inputs[slot] = confirmed;
      } else if (predictRemote) {
        inputs[slot] = _lastRemoteMask[slot] ?? 0;
      } else {
        inputs[slot] = _usedMask(frame, slot) ?? _lastRemoteMask[slot] ?? 0;
      }
    }
    return inputs;
  }

  void _applyInputs(Map<int, int> inputs) {
    emu_loop.clearInputs();
    for (final entry in inputs.entries) {
      applyNetplayInputMask(netplaySlotToLibretroPort(entry.key), entry.value);
    }
  }

  void _recordUsedInputs(int frame, Map<int, int> inputs) {
    _usedInputsByFrame[frame] = Map<int, int>.from(inputs);
    final local = inputs[localSlot];
    if (local != null) {
      _lastLocalMask = local & 0xFFFF;
    }
  }

  void _scheduleLocalInput(int frame) {
    if (frame < 0) {
      return;
    }
    final mask = _localButtonMask & 0xFFFF;
    _localInputsByFrame[frame] = mask;
    onSendInput(frame, localSlot, mask);
  }

  int _localMask(int frame) {
    final scheduled = _localInputsByFrame[frame];
    if (scheduled != null) {
      return scheduled;
    }
    return _usedMask(frame, localSlot) ?? _lastLocalMask;
  }

  void _setConfirmed(int frame, int slot, int buttons) {
    final map = Map<int, int>.from(_confirmedInputsByFrame[frame] ?? {});
    map[slot] = buttons;
    _confirmedInputsByFrame[frame] = map;
  }

  int? _usedMask(int frame, int slot) => _usedInputsByFrame[frame]?[slot];

  int? _confirmedMask(int frame, int slot) =>
      _confirmedInputsByFrame[frame]?[slot];

  void _pruneHistory() {
    final minKeep = emu_loop.netplaySimFrame() - maxRollbackFrames;
    _usedInputsByFrame.removeWhere((frame, _) => frame < minKeep);
    _confirmedInputsByFrame.removeWhere((frame, _) => frame < minKeep);
    _localInputsByFrame.removeWhere((frame, _) => frame < minKeep);
  }

  void _scheduleTick({bool runImmediately = true}) {
    _tickTimer?.cancel();
    if (!_running) {
      return;
    }
    final period = Duration(
      microseconds: (1000000 / _fps).round().clamp(1, 1000000),
    );
    _tickTimer = Timer.periodic(period, (_) => _onTick());
    if (runImmediately) {
      _onTick();
    }
  }
}
