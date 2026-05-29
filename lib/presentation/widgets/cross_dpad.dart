import 'package:flutter/material.dart';

import '../../core/libretro/libretro_bindings.dart';
import 'dpad_geometry.dart';

/// PlayStation-style cross D-pad ([DpadGeometry]); per-arm fill on press.
class CrossDpad extends StatelessWidget {
  final double size;
  final Color idleColor;
  final Color pressedColor;
  final Color? outlineColor;
  final bool up;
  final bool down;
  final bool left;
  final bool right;
  final ValueChanged<Map<int, bool>> onDirectionsChanged;
  final VoidCallback onDirectionsCleared;

  const CrossDpad({
    super.key,
    required this.size,
    required this.idleColor,
    required this.pressedColor,
    this.outlineColor,
    required this.up,
    required this.down,
    required this.left,
    required this.right,
    required this.onDirectionsChanged,
    required this.onDirectionsCleared,
  });

  static Map<int, bool> _retroMap(DpadDirections d) {
    return {
      RETRO_DEVICE_ID_JOYPAD_UP: d.up,
      RETRO_DEVICE_ID_JOYPAD_DOWN: d.down,
      RETRO_DEVICE_ID_JOYPAD_LEFT: d.left,
      RETRO_DEVICE_ID_JOYPAD_RIGHT: d.right,
    };
  }

  void _handlePointer(Offset local) {
    onDirectionsChanged(_retroMap(DpadGeometry.directionsAt(local, size)));
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (e) => _handlePointer(e.localPosition),
      onPointerMove: (e) => _handlePointer(e.localPosition),
      onPointerUp: (_) => onDirectionsCleared(),
      onPointerCancel: (_) => onDirectionsCleared(),
      child: SizedBox(
        width: size,
        height: size,
        child: CustomPaint(
          painter: _CrossDpadPainter(
            up: up,
            down: down,
            left: left,
            right: right,
            idleColor: idleColor,
            pressedColor: pressedColor,
            outlineColor: outlineColor,
          ),
        ),
      ),
    );
  }
}

class _CrossDpadPainter extends CustomPainter {
  _CrossDpadPainter({
    required this.up,
    required this.down,
    required this.left,
    required this.right,
    required this.idleColor,
    required this.pressedColor,
    this.outlineColor,
  });

  final bool up;
  final bool down;
  final bool left;
  final bool right;
  final Color idleColor;
  final Color pressedColor;
  final Color? outlineColor;

  @override
  void paint(Canvas canvas, Size size) {
    final scale = size.width / DpadGeometry.viewSize;
    canvas.scale(scale);

    _paintArm(canvas, DpadGeometry.upPath(), up);
    _paintArm(canvas, DpadGeometry.downPath(), down);
    _paintArm(canvas, DpadGeometry.leftPath(), left);
    _paintArm(canvas, DpadGeometry.rightPath(), right);

    final outline = outlineColor;
    if (outline != null) {
      canvas.drawPath(
        DpadGeometry.crossOutline(),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..color = outline.withValues(alpha: 0.35),
      );
    }
  }

  void _paintArm(Canvas canvas, Path path, bool pressed) {
    final fill = Paint()
      ..style = PaintingStyle.fill
      ..color = pressed ? pressedColor : idleColor;
    canvas.drawPath(path, fill);
  }

  @override
  bool shouldRepaint(covariant _CrossDpadPainter oldDelegate) {
    return oldDelegate.up != up ||
        oldDelegate.down != down ||
        oldDelegate.left != left ||
        oldDelegate.right != right ||
        oldDelegate.idleColor != idleColor ||
        oldDelegate.pressedColor != pressedColor ||
        oldDelegate.outlineColor != outlineColor;
  }
}
