import 'dart:ui';

/// PlayStation 风格十字键：四臂等宽；内侧尖角锐利，外侧平直段两角微圆。
class DpadGeometry {
  DpadGeometry._();

  static const double viewSize = 120;
  static const Offset center = Offset(60, 60);

  static const double armWidth = 32;
  static const double armHalf = armWidth / 2;
  static const double gap = 6;
  static const double tipHalf = armHalf;
  static const double armReach = 22;

  /// 仅外缘（背对中心尖角）两角的圆角半径。
  static const double cornerRadius = 4;

  static const double _yBevelUp = 38;
  static const double _yBevelDown = 82;
  static const double _xBevelLeft = 38;
  static const double _xBevelRight = 82;

  static Path upPath() {
    final l = center.dx - tipHalf;
    final r = center.dx + tipHalf;
    final cr = cornerRadius;

    return Path()
      ..moveTo(center.dx, center.dy - gap)
      ..lineTo(l, _yBevelUp)
      ..lineTo(l, cr)
      ..quadraticBezierTo(l, 0, l + cr, 0)
      ..lineTo(r - cr, 0)
      ..quadraticBezierTo(r, 0, r, cr)
      ..lineTo(r, _yBevelUp)
      ..close();
  }

  static Path downPath() {
    final l = center.dx - tipHalf;
    final r = center.dx + tipHalf;
    final cr = cornerRadius;
    final bottom = viewSize;

    return Path()
      ..moveTo(center.dx, center.dy + gap)
      ..lineTo(l, _yBevelDown)
      ..lineTo(l, bottom - cr)
      ..quadraticBezierTo(l, bottom, l + cr, bottom)
      ..lineTo(r - cr, bottom)
      ..quadraticBezierTo(r, bottom, r, bottom - cr)
      ..lineTo(r, _yBevelDown)
      ..close();
  }

  static Path leftPath() {
    final t = center.dy - tipHalf;
    final b = center.dy + tipHalf;
    final cr = cornerRadius;

    return Path()
      ..moveTo(center.dx - gap, center.dy)
      ..lineTo(_xBevelLeft, t)
      ..lineTo(cr, t)
      ..quadraticBezierTo(0, t, 0, t + cr)
      ..lineTo(0, b - cr)
      ..quadraticBezierTo(0, b, cr, b)
      ..lineTo(_xBevelLeft, b)
      ..close();
  }

  static Path rightPath() {
    final t = center.dy - tipHalf;
    final b = center.dy + tipHalf;
    final cr = cornerRadius;
    final right = viewSize;

    return Path()
      ..moveTo(center.dx + gap, center.dy)
      ..lineTo(_xBevelRight, t)
      ..lineTo(right - cr, t)
      ..quadraticBezierTo(right, t, right, t + cr)
      ..lineTo(right, b - cr)
      ..quadraticBezierTo(right, b, right - cr, b)
      ..lineTo(_xBevelRight, b)
      ..close();
  }

  static Path crossOutline() {
    var outline = upPath();
    outline = Path.combine(PathOperation.union, outline, downPath());
    outline = Path.combine(PathOperation.union, outline, leftPath());
    outline = Path.combine(PathOperation.union, outline, rightPath());
    return outline;
  }

  static DpadDirections directionsAt(Offset local, double size) {
    final scale = size / viewSize;
    final p = Offset(local.dx / scale, local.dy / scale);

    final fromPath = DpadDirections(
      up: upPath().contains(p),
      down: downPath().contains(p),
      left: leftPath().contains(p),
      right: rightPath().contains(p),
    );
    if (fromPath.any) {
      return fromPath;
    }

    final dx = p.dx - center.dx;
    final dy = p.dy - center.dy;

    if (dx * dx + dy * dy < gap * gap * 4) {
      return const DpadDirections();
    }

    final absDx = dx.abs();
    final absDy = dy.abs();

    return DpadDirections(
      up: dy < 0 && absDy > absDx * 0.414,
      down: dy > 0 && absDy > absDx * 0.414,
      left: dx < 0 && absDx > absDy * 0.414,
      right: dx > 0 && absDx > absDy * 0.414,
    );
  }
}

class DpadDirections {
  const DpadDirections({
    this.up = false,
    this.down = false,
    this.left = false,
    this.right = false,
  });

  final bool up;
  final bool down;
  final bool left;
  final bool right;

  bool get any => up || down || left || right;
}
