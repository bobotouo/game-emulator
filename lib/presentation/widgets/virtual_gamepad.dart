import 'package:flutter/material.dart';

import '../gamepad/gamepad_layout.dart';
import '../gamepad/gamepad_skin.dart';
import '../theme/app_theme.dart';
import '../../core/haptics/haptic_service.dart';
import '../../core/libretro/libretro_bindings.dart';
import 'cross_dpad.dart';

typedef InputUpdateCallback = void Function(Map<int, bool> state);

class VirtualGamepad extends StatefulWidget {
  final InputUpdateCallback? onInputUpdate;
  final bool overlay;
  final GamepadSkin skin;
  final GamepadLayout layout;

  const VirtualGamepad({
    super.key,
    this.onInputUpdate,
    this.overlay = false,
    this.skin = GamepadSkins.classic,
    this.layout = GamepadLayouts.gba,
  });

  @override
  State<VirtualGamepad> createState() => _VirtualGamepadState();
}

class _VirtualGamepadState extends State<VirtualGamepad> {
  final Map<int, bool> _inputState = {};

  double get _dpadSize => widget.layout.compact ? 100.0 : 116.0;

  GamepadSkin get _skin => widget.skin;

  void _notifyInput() {
    widget.onInputUpdate?.call(Map.from(_inputState));
  }

  void _updateInput(int button, bool pressed) {
    if (_inputState[button] == pressed) return;
    if (pressed) {
      _triggerButtonFeedback(button);
    }
    setState(() {
      _inputState[button] = pressed;
    });
    _notifyInput();
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

  void _clearDpad() {
    const ids = [
      RETRO_DEVICE_ID_JOYPAD_UP,
      RETRO_DEVICE_ID_JOYPAD_DOWN,
      RETRO_DEVICE_ID_JOYPAD_LEFT,
      RETRO_DEVICE_ID_JOYPAD_RIGHT,
    ];

    var changed = false;
    for (final id in ids) {
      if (_inputState[id] == true) {
        changed = true;
      }
      _inputState[id] = false;
    }
    if (!changed) return;
    setState(() {});
    _notifyInput();
  }

  void _onDpadDirections(Map<int, bool> directions) {
    var changed = false;
    for (final entry in directions.entries) {
      if (_inputState[entry.key] != entry.value) {
        changed = true;
        break;
      }
    }
    if (!changed) return;

    final anyNewPress = directions.entries.any(
      (e) => e.value && _inputState[e.key] != true,
    );

    setState(() {
      for (final entry in directions.entries) {
        _inputState[entry.key] = entry.value;
      }
    });

    if (anyNewPress) {
      HapticService.instance.selectionClick();
    }
    _notifyInput();
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.paddingOf(context).bottom;
    final hPad = widget.overlay ? 24.0 : 12.0;

    final controls = Padding(
      padding: EdgeInsets.fromLTRB(
        hPad,
        widget.overlay ? 10 : 0,
        hPad,
        (widget.overlay ? 10 : 4) + bottomInset,
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        crossAxisAlignment: widget.overlay
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.center,
        children: [
          if (widget.layout.showDpad)
            _buildDpad()
          else
            const SizedBox(width: 8),
          if (widget.layout.showSelectStart)
            _buildCenterButtons()
          else
            const SizedBox(width: 8),
          _buildActionButtons(),
        ],
      ),
    );

    if (widget.overlay) {
      return controls;
    }

    return ColoredBox(
      color: AppColors.background,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (widget.layout.showShoulders)
            Padding(
              padding: EdgeInsets.fromLTRB(hPad, 0, hPad, 40),
              child: _buildShoulderRow(),
            ),
          controls,
        ],
      ),
    );
  }

  Widget _buildShoulderRow() {
    return Row(
      children: [
        Expanded(
          child: Align(
            alignment: Alignment.centerLeft,
            child: _buildShoulderButton(
              label: 'L',
              button: RETRO_DEVICE_ID_JOYPAD_L,
            ),
          ),
        ),
        Expanded(
          child: Align(
            alignment: Alignment.centerRight,
            child: _buildShoulderButton(
              label: 'R',
              button: RETRO_DEVICE_ID_JOYPAD_R,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildDpad() {
    return CrossDpad(
      size: _dpadSize,
      idleColor: _skin.barButtonFill.withValues(alpha: 0.96),
      pressedColor: _skin.joystickActiveBorder,
      outlineColor: _skin.barLabel,
      up: _inputState[RETRO_DEVICE_ID_JOYPAD_UP] == true,
      down: _inputState[RETRO_DEVICE_ID_JOYPAD_DOWN] == true,
      left: _inputState[RETRO_DEVICE_ID_JOYPAD_LEFT] == true,
      right: _inputState[RETRO_DEVICE_ID_JOYPAD_RIGHT] == true,
      onDirectionsChanged: _onDpadDirections,
      onDirectionsCleared: _clearDpad,
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
          SizedBox(height: widget.layout.compact ? 8 : 10),
          _buildBarButton(label: 'START', button: RETRO_DEVICE_ID_JOYPAD_START),
        ],
      ),
    );
  }

  Widget _buildShoulderButton({required String label, required int button}) {
    final isPressed = _inputState[button] == true;
    final base = _skin.colorShoulder;
    final dark = _skin.colorShoulderDark;

    return GestureDetector(
      onTapDown: (_) => _updateInput(button, true),
      onTapUp: (_) => _updateInput(button, false),
      onTapCancel: () => _updateInput(button, false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 60),
        width: 76,
        height: 36,
        alignment: Alignment.center,
        transform: Matrix4.translationValues(0, isPressed ? 2 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: isPressed
                ? [dark, dark.withValues(alpha: 0.92)]
                : [base.withValues(alpha: 0.95), dark],
          ),
          border: Border.all(
            color: Colors.white.withValues(alpha: isPressed ? 0.22 : 0.14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isPressed ? 0.28 : 0.42),
              blurRadius: isPressed ? 6 : 10,
              offset: Offset(0, isPressed ? 2 : 5),
            ),
            BoxShadow(
              color: _skin.joystickActiveBorder.withValues(
                alpha: isPressed ? 0.15 : 0.08,
              ),
              blurRadius: 12,
            ),
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: _skin.barLabel.withValues(alpha: isPressed ? 0.95 : 0.88),
          ),
        ),
      ),
    );
  }

  Widget _buildBarButton({required String label, required int button}) {
    final isPressed = _inputState[button] == true;
    final width = label.length <= 1 ? 56.0 : 72.0;

    return GestureDetector(
      onTapDown: (_) => _updateInput(button, true),
      onTapUp: (_) => _updateInput(button, false),
      onTapCancel: () => _updateInput(button, false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: width,
        height: 24,
        alignment: Alignment.center,
        transform: Matrix4.translationValues(0, isPressed ? 1.5 : 0, 0),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          color: isPressed
              ? _skin.barButtonPressed
              : _skin.barButtonFill.withValues(alpha: 0.96),
          border: Border.all(
            color: _skin.barLabel.withValues(alpha: isPressed ? 0.28 : 0.14),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: isPressed ? 0.22 : 0.32),
              blurRadius: isPressed ? 4 : 6,
              offset: Offset(0, isPressed ? 1 : 3),
            ),
          ],
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: label.length <= 1 ? 11 : 8,
            fontWeight: FontWeight.w700,
            color: _skin.barLabel.withValues(alpha: 0.82),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    if (widget.layout.showFaceXY) {
      return _buildFourFaceButtons();
    }
    return _buildTwoFaceButtons();
  }

  Widget _buildTwoFaceButtons() {
    final size = widget.layout.compact ? 50.0 : 56.0;
    final areaW = widget.layout.compact ? 104.0 : 118.0;
    final areaH = widget.layout.compact ? 100.0 : 112.0;

    return SizedBox(
      width: areaW,
      height: areaH,
      child: Stack(
        children: [
          Positioned(
            left: 0,
            bottom: 4,
            child: _buildActionButton(
              label: 'B',
              button: RETRO_DEVICE_ID_JOYPAD_B,
              diameter: size,
            ),
          ),
          Positioned(
            right: 0,
            top: 4,
            child: _buildActionButton(
              label: 'A',
              button: RETRO_DEVICE_ID_JOYPAD_A,
              diameter: size,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFourFaceButtons() {
    final size = widget.layout.compact ? 46.0 : 52.0;
    final area = widget.layout.compact ? 120.0 : 132.0;

    return SizedBox(
      width: area,
      height: area,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: area / 2 - size / 2,
            child: _buildActionButton(
              label: 'Y',
              button: RETRO_DEVICE_ID_JOYPAD_Y,
              diameter: size,
            ),
          ),
          Positioned(
            left: 0,
            top: area / 2 - size / 2,
            child: _buildActionButton(
              label: 'X',
              button: RETRO_DEVICE_ID_JOYPAD_X,
              diameter: size,
            ),
          ),
          Positioned(
            right: 0,
            top: area / 2 - size / 2,
            child: _buildActionButton(
              label: 'A',
              button: RETRO_DEVICE_ID_JOYPAD_A,
              diameter: size,
            ),
          ),
          Positioned(
            bottom: 0,
            left: area / 2 - size / 2,
            child: _buildActionButton(
              label: 'B',
              button: RETRO_DEVICE_ID_JOYPAD_B,
              diameter: size,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildActionButton({
    required String label,
    required int button,
    required double diameter,
  }) {
    final isPressed = _inputState[button] == true;
    final baseColor = _skin.faceButtonColor(label);
    final darkColor = _skin.faceButtonDark(label);
    final textColor = _skin.faceButtonText(label);
    final fontSize = widget.layout.compact ? 18.0 : 21.0;

    return GestureDetector(
      onTapDown: (_) => _updateInput(button, true),
      onTapUp: (_) => _updateInput(button, false),
      onTapCancel: () => _updateInput(button, false),
      child: SizedBox(
        width: diameter,
        height: diameter + 4,
        child: Transform.translate(
          offset: Offset(0, isPressed ? 2 : 0),
          child: Container(
            width: diameter,
            height: diameter,
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
                ),
              ],
            ),
            child: Text(
              label,
              style: TextStyle(
                fontSize: fontSize,
                fontWeight: FontWeight.w800,
                color: textColor.withValues(alpha: 0.96),
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
