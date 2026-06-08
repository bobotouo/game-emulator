import 'dart:async';
import 'dart:ffi';

import 'package:flutter/foundation.dart';

import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import '../libretro/libretro_bindings.dart';
import 'netplay_input_sync.dart';

/// Default GGPO rollback window.
const int kGgpoRollbackFrames = 8;

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
    this.sharedMenuFrames = 0,
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
  final int sharedMenuFrames;

  bool _running = false;
  bool _emulating = false;
  bool _ready = false;
  int? _pendingRollbackFrom;
  Timer? _tickTimer;
  double _fps = 60.0;
  int _speed = 1;
  Set<int> _requiredSlots;

  int _localButtonMask = 0;
  int _lastLocalMask = 0;
  int? _sharedMenuStopFrame;
  DateTime? _lastRollbackAt;
  DateTime? _lastStallResendAt;

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
    _ready = false;
    _pendingRollbackFrom = null;
    _lastRollbackAt = null;
    _lastStallResendAt = null;
    _sharedMenuStopFrame = null;
    _localButtonMask = 0;
    _lastLocalMask = 0;
    _usedInputsByFrame.clear();
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
    emu_loop.clearInputs();

    emu_loop.endNetplaySnapshots();
    emu_loop.beginNetplaySnapshots(
      serialize: serializePtr.cast(),
      restore: restorePtr.cast(),
      stateSize: stateSize,
      maxFrames: maxRollbackFrames,
    );
    emu_loop.netplaySetSimFrame(startFrame);

    _scheduleTick();
  }

  void stop() {
    _running = false;
    _emulating = false;
    _ready = false;
    _pendingRollbackFrom = null;
    _localButtonMask = 0;
    _lastLocalMask = 0;
    _tickTimer?.cancel();
    _tickTimer = null;
    emu_loop.stopNativeLoop();
    emu_loop.waitUntilEmulatorStopped();
    emu_loop.clearInputs();
    emu_loop.endNetplaySnapshots();
    _usedInputsByFrame.clear();
    _confirmedInputsByFrame.clear();
    _localInputsByFrame.clear();
    _lastRemoteMask.clear();
  }

  void updateLocalButtons(int mask) {
    _localButtonMask = mask & 0xFFFF;
    if (_running && !_emulating && _ready) {
      final frame = emu_loop.netplaySimFrame();
      _localInputsByFrame[frame] = _localButtonMask;
      _scheduleLocalInput(frame + inputDelayFrames);
    }
  }

  void receiveRemoteInput(int frame, int slot, int buttons) {
    if (slot == localSlot || !_requiredSlots.contains(slot)) {
      return;
    }
    buttons &= 0xFFFF;
    _lastRemoteMask[slot] = buttons;
    _setConfirmed(frame, slot, buttons);

    if (!_running) {
      return;
    }

    final sim = emu_loop.netplaySimFrame();
    if (frame >= sim) {
      return;
    }

    final used = _usedMask(frame, slot);
    if (used != null && used == buttons) {
      return;
    }

    if (sim - frame > maxRollbackFrames) {
      debugPrint(
        'NetplayRollbackRunner: late input dropped frame=$frame sim=$sim '
        'slot=$slot window=$maxRollbackFrames',
      );
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
    _ready = true;
    try {
      final f = emu_loop.netplaySimFrame();
      _scheduleLocalInput(f + inputDelayFrames);
      if (_shouldWaitForRemoteInput(f)) {
        _resendStalledInputs(f);
        return;
      }
      final inputs = _buildInputsForFrame(f, predictRemote: true);
      _recordUsedInputs(f, inputs);
      _applyInputs(inputs, frame: f, updateSharedMenuState: true);
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
        _applyInputs(inputs, frame: f, updateSharedMenuState: false);
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

      inputs[slot] = _remoteMaskForFrame(
        frame,
        slot,
        predictRemote: predictRemote,
      );
    }
    return inputs;
  }

  int _remoteMaskForFrame(int frame, int slot, {required bool predictRemote}) {
    final confirmed = _confirmedMask(frame, slot);
    if (confirmed != null) {
      return confirmed;
    }
    if (predictRemote) {
      return _lastRemoteMask[slot] ?? 0;
    }
    return _usedMask(frame, slot) ?? _lastRemoteMask[slot] ?? 0;
  }

  bool _shouldWaitForRemoteInput(int frame) {
    final waitThreshold = maxRollbackFrames + inputDelayFrames;
    for (final slot in _requiredSlots) {
      if (slot == localSlot) {
        continue;
      }
      if (_confirmedMask(frame, slot) == null) {
        final newest = _latestConfirmedFrameForSlot(slot);
        if (newest == null || frame - newest > waitThreshold) {
          return true;
        }
      }
    }
    return false;
  }

  int? _latestConfirmedFrameForSlot(int slot) {
    int? latest;
    for (final entry in _confirmedInputsByFrame.entries) {
      if (entry.value.containsKey(slot) &&
          (latest == null || entry.key > latest)) {
        latest = entry.key;
      }
    }
    return latest;
  }

  void _resendStalledInputs(int frame) {
    final now = DateTime.now();
    final last = _lastStallResendAt;
    if (last != null &&
        now.difference(last) < const Duration(milliseconds: 100)) {
      return;
    }
    _lastStallResendAt = now;
    for (var f = frame; f < frame + inputDelayFrames + 2; f++) {
      _scheduleLocalInput(f);
    }
  }

  void _applyInputs(
    Map<int, int> inputs, {
    required int frame,
    required bool updateSharedMenuState,
  }) {
    final applied = Map<int, int>.from(inputs);
    if (_shouldShareMenuControls(frame)) {
      var menuMask = 0;
      for (final mask in inputs.values) {
        menuMask |= mask & kNetplayMenuControlMask;
      }
      if (menuMask != 0) {
        applied[1] = (applied[1] ?? 0) | menuMask;
      }
      if (updateSharedMenuState &&
          _sharedMenuStopFrame == null &&
          ((inputs[1] ?? 0) & kNetplayMenuStartMask) != 0) {
        _sharedMenuStopFrame = frame + (_fps / 2).round().clamp(1, 60);
      }
    }
    _applyMenuStartEdges(applied, frame);

    emu_loop.clearInputs();
    for (final entry in applied.entries) {
      applyNetplayInputMask(netplaySlotToLibretroPort(entry.key), entry.value);
    }
  }

  bool _shouldShareMenuControls(int frame) {
    if (sharedMenuFrames <= 0 || frame > sharedMenuFrames) {
      return false;
    }
    final stopFrame = _sharedMenuStopFrame;
    return stopFrame == null || frame <= stopFrame;
  }

  void _applyMenuStartEdges(Map<int, int> inputs, int frame) {
    if (sharedMenuFrames <= 0 || frame > sharedMenuFrames) {
      return;
    }
    for (final entry in List<MapEntry<int, int>>.from(inputs.entries)) {
      final mask = entry.value;
      if ((mask & kNetplayMenuStartMask) == 0) {
        continue;
      }
      final previous = _usedInputsByFrame[frame - 1]?[entry.key] ?? 0;
      if ((previous & kNetplayMenuStartMask) != 0) {
        inputs[entry.key] = mask & ~kNetplayMenuStartMask;
      }
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
