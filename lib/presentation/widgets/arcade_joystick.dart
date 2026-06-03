import 'package:flutter/material.dart';

import '../../core/libretro/libretro_bindings.dart';

/// 8-way digital stick for arcade (maps to libretro d-pad directions).
class ArcadeJoystick extends StatefulWidget {
  const ArcadeJoystick({
    super.key,
    required this.size,
    required this.ringColor,
    required this.knobColor,
    required this.activeBorderColor,
    required this.onDirectionsChanged,
    required this.onDirectionsCleared,
    this.up = false,
    this.down = false,
    this.left = false,
    this.right = false,
  });

  final double size;
  final Color ringColor;
  final Color knobColor;
  final Color activeBorderColor;
  final ValueChanged<Map<int, bool>> onDirectionsChanged;
  final VoidCallback onDirectionsCleared;
  final bool up;
  final bool down;
  final bool left;
  final bool right;

  @override
  State<ArcadeJoystick> createState() => _ArcadeJoystickState();
}

class _ArcadeJoystickState extends State<ArcadeJoystick> {
  Offset _knobOffset = Offset.zero;
  int? _activePointer;

  static const _deadZone = 0.16;
  static const _axisThreshold = 0.34;

  void _handlePointer(Offset local, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final delta = local - center;
    final maxRadius = size.width * 0.34;
    final dist = delta.distance;
    final clamped = dist > maxRadius
        ? center + Offset.fromDirection(delta.direction, maxRadius)
        : local;
    final norm = (clamped - center) / maxRadius;

    setState(() {
      _knobOffset = clamped - center;
    });

    final directions = <int, bool>{
      RETRO_DEVICE_ID_JOYPAD_UP: false,
      RETRO_DEVICE_ID_JOYPAD_DOWN: false,
      RETRO_DEVICE_ID_JOYPAD_LEFT: false,
      RETRO_DEVICE_ID_JOYPAD_RIGHT: false,
    };

    if (dist >= maxRadius * _deadZone) {
      directions[RETRO_DEVICE_ID_JOYPAD_RIGHT] = norm.dx > _axisThreshold;
      directions[RETRO_DEVICE_ID_JOYPAD_LEFT] = norm.dx < -_axisThreshold;
      directions[RETRO_DEVICE_ID_JOYPAD_DOWN] = norm.dy > _axisThreshold;
      directions[RETRO_DEVICE_ID_JOYPAD_UP] = norm.dy < -_axisThreshold;
    }

    widget.onDirectionsChanged(directions);
  }

  void _clear() {
    _activePointer = null;
    setState(() => _knobOffset = Offset.zero);
    widget.onDirectionsCleared();
  }

  @override
  Widget build(BuildContext context) {
    final active = widget.up || widget.down || widget.left || widget.right;

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) {
        if (_activePointer != null) return;
        _activePointer = e.pointer;
        _handlePointer(e.localPosition, Size(widget.size, widget.size));
      },
      onPointerMove: (e) {
        if (_activePointer != e.pointer) return;
        _handlePointer(e.localPosition, Size(widget.size, widget.size));
      },
      onPointerUp: (e) {
        if (_activePointer == e.pointer) {
          _clear();
        }
      },
      onPointerCancel: (e) {
        if (_activePointer == e.pointer) {
          _clear();
        }
      },
      child: SizedBox(
        width: widget.size,
        height: widget.size,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: widget.size,
              height: widget.size,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: widget.ringColor,
                border: Border.all(
                  color: active
                      ? widget.activeBorderColor
                      : Colors.white.withValues(alpha: 0.12),
                  width: active ? 2.5 : 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
            ),
            Transform.translate(
              offset: _knobOffset,
              child: Container(
                width: widget.size * 0.42,
                height: widget.size * 0.42,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    colors: [
                      widget.knobColor.withValues(alpha: 0.98),
                      widget.knobColor.withValues(alpha: 0.75),
                    ],
                  ),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.22),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(
                        alpha: active ? 0.3 : 0.45,
                      ),
                      blurRadius: active ? 6 : 10,
                      offset: Offset(0, active ? 2 : 5),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
