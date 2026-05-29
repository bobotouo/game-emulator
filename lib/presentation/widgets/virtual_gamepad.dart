import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../core/haptics/haptic_service.dart';
import '../../core/libretro/libretro_bindings.dart';

/// Input update callback
typedef InputUpdateCallback = void Function(Map<int, bool> state);

class VirtualGamepad extends StatefulWidget {
  final InputUpdateCallback? onInputUpdate;
  final bool overlay;

  const VirtualGamepad({super.key, this.onInputUpdate, this.overlay = false});

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  static const double _joystickSize = 108;
  static const double _joystickTravel = 28;
  static const double _joystickThreshold = 13;

  final Map<int, bool> _inputState = {};
  Offset _joystickOffset = Offset.zero;

  void _updateInput(int button, bool pressed) {
    if (pressed) {
      _triggerButtonFeedback(button);
    }
    setState(() {
      _inputState[button] = pressed;
    });
    widget.onInputUpdate?.call(Map.from(_inputState));
  }

  void _triggerButtonFeedback(int button) {
    switch (button) {
      case RETRO_DEVICE_ID_JOYPAD_A:
      case RETRO_DEVICE_ID_JOYPAD_B:
        HapticService.instance.buttonPress();
        break;
      default:
        HapticService.instance.selectionClick();
        break;
    }
  }

  void _updateDirectionalInput(Offset offset) {
    final updates = {
      RETRO_DEVICE_ID_JOYPAD_UP: offset.dy < -_joystickThreshold,
      RETRO_DEVICE_ID_JOYPAD_DOWN: offset.dy > _joystickThreshold,
      RETRO_DEVICE_ID_JOYPAD_LEFT: offset.dx < -_joystickThreshold,
      RETRO_DEVICE_ID_JOYPAD_RIGHT: offset.dx > _joystickThreshold,
    };

    var changed = false;
    updates.forEach((button, pressed) {
      if (_inputState[button] != pressed) {
        changed = true;
      }
    });

    setState(() {
      _joystickOffset = offset;
      _inputState.addAll(updates);
    });

    if (changed) {
      HapticService.instance.selectionClick();
      widget.onInputUpdate?.call(Map.from(_inputState));
    }
  }

  void _handleJoystickPosition(Offset localPosition) {
    final center = const Offset(_joystickSize / 2, _joystickSize / 2);
    final rawOffset = localPosition - center;
    final distance = rawOffset.distance;
    final clampedOffset = distance > _joystickTravel
        ? rawOffset * (_joystickTravel / distance)
        : rawOffset;

    _updateDirectionalInput(clampedOffset);
  }

  void _resetJoystick() {
    _updateDirectionalInput(Offset.zero);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;

    return Container(
      padding: EdgeInsets.fromLTRB(
        widget.overlay ? 24 : 16,
        10,
        widget.overlay ? 24 : 16,
        (widget.overlay ? 10 : 24) + bottomInset,
      ),
      color: Colors.transparent,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: widget.overlay
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.center,
        children: [
          _buildJoystick(),
          _buildCenterButtons(),
          _buildActionButtons(),
        ],
      ),
    );
  }

  Widget _buildJoystick() {
    final isActive = _joystickOffset != Offset.zero;

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (details) {
        _handleJoystickPosition(details.localPosition);
      },
      onTapUp: (_) => _resetJoystick(),
      onTapCancel: _resetJoystick,
      onPanStart: (details) {
        _handleJoystickPosition(details.localPosition);
      },
      onPanUpdate: (details) => _handleJoystickPosition(details.localPosition),
      onPanEnd: (_) => _resetJoystick(),
      onPanCancel: _resetJoystick,
      child: SizedBox(
        width: _joystickSize,
        height: _joystickSize,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              width: _joystickSize,
              height: _joystickSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: const LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: [
                    AppColors.surfaceContainerHighest,
                    AppColors.surfaceContainer,
                    AppColors.surfaceContainerLowest,
                  ],
                ),
                border: Border.all(
                  color: isActive
                      ? AppColors.primary.withValues(alpha: 0.8)
                      : AppColors.outlineVariant,
                  width: 1.5,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.42),
                    blurRadius: 18,
                    offset: const Offset(0, 8),
                  ),
                  BoxShadow(
                    color: AppColors.primary.withValues(
                      alpha: isActive ? 0.22 : 0.08,
                    ),
                    blurRadius: 18,
                    spreadRadius: 1,
                  ),
                ],
              ),
            ),
            Container(
              width: 66,
              height: 66,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceContainerLow.withValues(alpha: 0.82),
                border: Border.all(
                  color: AppColors.outlineVariant.withValues(alpha: 0.7),
                ),
              ),
            ),
            Transform.translate(
              offset: _joystickOffset,
              child: Container(
                width: 46,
                height: 46,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: RadialGradient(
                    center: const Alignment(-0.35, -0.45),
                    radius: 0.95,
                    colors: [
                      AppColors.primary.withValues(alpha: 0.95),
                      AppColors.primaryContainer,
                      AppColors.surfaceContainerHighest,
                    ],
                    stops: const [0.0, 0.62, 1.0],
                  ),
                  border: Border.all(
                    color: AppColors.onPrimary.withValues(alpha: 0.18),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 8,
                      offset: const Offset(0, 5),
                    ),
                    BoxShadow(
                      color: AppColors.primary.withValues(alpha: 0.28),
                      blurRadius: 14,
                      spreadRadius: 1,
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

  Widget _buildCenterButtons() {
    if (widget.overlay) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildBarButton(
            label: 'SELECT',
            button: RETRO_DEVICE_ID_JOYPAD_SELECT,
          ),
          const SizedBox(width: 12),
          _buildBarButton(label: 'START', button: RETRO_DEVICE_ID_JOYPAD_START),
        ],
      );
    }

    return Transform.rotate(
      angle: -0.14,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildBarButton(
            label: 'SELECT',
            button: RETRO_DEVICE_ID_JOYPAD_SELECT,
          ),
          const SizedBox(height: 10),
          _buildBarButton(label: 'START', button: RETRO_DEVICE_ID_JOYPAD_START),
        ],
      ),
    );
  }

  Widget _buildBarButton({required String label, required int button}) {
    final isPressed = _inputState[button] == true;

    return GestureDetector(
      onTapDown: (_) {
        _updateInput(button, true);
      },
      onTapUp: (_) => _updateInput(button, false),
      onTapCancel: () => _updateInput(button, false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: 72,
        height: 24,
        alignment: Alignment.center,
        transform: Matrix4.translationValues(0, isPressed ? 1.5 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isPressed
              ? AppColors.surfaceContainerHighest
              : AppColors.surfaceBright.withValues(alpha: 0.96),
          border: Border.all(
            color: AppColors.onSurfaceVariant.withValues(
              alpha: isPressed ? 0.28 : 0.14,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 8,
            fontFamily: 'JetBrains Mono',
            fontWeight: FontWeight.w700,
            color: AppColors.onSurface.withValues(alpha: 0.82),
            letterSpacing: 0,
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    return SizedBox(
      width: 118,
      height: 112,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            bottom: 4,
            child: _buildActionButton(
              label: 'B',
              button: RETRO_DEVICE_ID_JOYPAD_B,
              baseColor: AppColors.secondary,
              darkColor: AppColors.secondaryContainer,
              textColor: AppColors.onSecondary,
            ),
          ),
          Positioned(
            right: 0,
            top: 4,
            child: _buildActionButton(
              label: 'A',
              button: RETRO_DEVICE_ID_JOYPAD_A,
              baseColor: AppColors.primary,
              darkColor: AppColors.primaryContainer,
              textColor: AppColors.onPrimary,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required int button,
    required Color baseColor,
    required Color darkColor,
    required Color textColor,
  }) {
    final isPressed = _inputState[button] == true;

    return GestureDetector(
      onTapDown: (_) {
        _updateInput(button, true);
      },
      onTapUp: (_) => _updateInput(button, false),
      onTapCancel: () => _updateInput(button, false),
      child: SizedBox(
        width: 56,
        height: 60,
        child: Transform.translate(
          offset: Offset(0, isPressed ? 2 : 0),
          child: Container(
            width: 56,
            height: 56,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                center: const Alignment(-0.35, -0.45),
                radius: 0.9,
                colors: [
                  baseColor.withValues(alpha: 0.98),
                  baseColor,
                  darkColor,
                ],
                stops: const [0.0, 0.48, 1.0],
              ),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.20),
                width: 1,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: isPressed ? 0.24 : 0.4),
                  blurRadius: isPressed ? 5 : 10,
                  offset: Offset(0, isPressed ? 3 : 6),
                ),
                BoxShadow(
                  color: baseColor.withValues(alpha: isPressed ? 0.12 : 0.20),
                  blurRadius: isPressed ? 8 : 14,
                  spreadRadius: 0,
                ),
              ],
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 21,
                fontFamily: 'Space Mono',
                fontWeight: FontWeight.w800,
                color: textColor.withValues(alpha: 0.96),
                letterSpacing: 0,
                shadows: [
                  Shadow(
                    color: Colors.black.withValues(alpha: 0.22),
                    offset: const Offset(0, 1),
                    blurRadius: 2,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
