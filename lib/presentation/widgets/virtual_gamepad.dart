import 'package:flutter/material.dart';

import '../gamepad/gamepad_layout.dart';
import '../gamepad/gamepad_skin.dart';
import '../theme/app_theme.dart';
import '../../core/haptics/haptic_service.dart';
import '../../core/libretro/libretro_bindings.dart';
import 'arcade_joystick.dart';
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
  final Map<int, Set<int>> _arcadePointerButtons = {};

  double get _dpadSize {
    if (widget.layout.id == 'arcade') {
      return 96.0;
    }
    return widget.layout.compact ? 100.0 : 116.0;
  }

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
    final isArcade = widget.layout.id == 'arcade';
    final hPad = widget.overlay ? (isArcade ? 12.0 : 24.0) : 12.0;

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
    if (widget.layout.useJoystickVisual) {
      return ArcadeJoystick(
        size: _dpadSize,
        ringColor: _skin.barButtonFill.withValues(alpha: 0.96),
        knobColor: _skin.joystickInner,
        activeBorderColor: _skin.joystickActiveBorder,
        up: _inputState[RETRO_DEVICE_ID_JOYPAD_UP] == true,
        down: _inputState[RETRO_DEVICE_ID_JOYPAD_DOWN] == true,
        left: _inputState[RETRO_DEVICE_ID_JOYPAD_LEFT] == true,
        right: _inputState[RETRO_DEVICE_ID_JOYPAD_RIGHT] == true,
        onDirectionsChanged: _onDpadDirections,
        onDirectionsCleared: _clearDpad,
      );
    }

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
      final center = widget.layout.resolvedCenterStyle;
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildBarButton(
            label: widget.layout.centerLeftLabel,
            button: RETRO_DEVICE_ID_JOYPAD_SELECT,
            width: center.buttonWidth,
            height: center.buttonHeight,
          ),
          SizedBox(width: widget.layout.id == 'arcade' ? 10 : 12),
          _buildBarButton(
            label: widget.layout.centerRightLabel,
            button: RETRO_DEVICE_ID_JOYPAD_START,
            width: center.buttonWidth,
            height: center.buttonHeight,
          ),
        ],
      );
    }

    if (widget.layout.id == 'arcade') {
      final center = widget.layout.resolvedCenterStyle;
      return Transform.rotate(
        angle: center.tiltRadians,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildBarButton(
              label: widget.layout.centerLeftLabel,
              button: RETRO_DEVICE_ID_JOYPAD_SELECT,
              width: center.buttonWidth,
              height: center.buttonHeight,
            ),
            SizedBox(height: center.buttonSpacing),
            _buildBarButton(
              label: widget.layout.centerRightLabel,
              button: RETRO_DEVICE_ID_JOYPAD_START,
              width: center.buttonWidth,
              height: center.buttonHeight,
            ),
          ],
        ),
      );
    }

    final center = widget.layout.resolvedCenterStyle;
    return Transform.rotate(
      angle: center.tiltRadians,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildBarButton(
            label: widget.layout.centerLeftLabel,
            button: RETRO_DEVICE_ID_JOYPAD_SELECT,
            width: center.buttonWidth,
            height: center.buttonHeight,
          ),
          SizedBox(height: center.buttonSpacing),
          _buildBarButton(
            label: widget.layout.centerRightLabel,
            button: RETRO_DEVICE_ID_JOYPAD_START,
            width: center.buttonWidth,
            height: center.buttonHeight,
          ),
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

  Widget _buildBarButton({
    required String label,
    required int button,
    double? width,
    double? height,
  }) {
    final isPressed = _inputState[button] == true;
    width ??= label.length <= 1
        ? 56.0
        : label.length <= 2
        ? 56.0
        : 72.0;
    height ??= 24.0;
    final fontSize = label.length <= 1
        ? 11.0
        : label.runes.length > 4
        ? 9.0
        : 10.0;

    return GestureDetector(
      onTapDown: (_) => _updateInput(button, true),
      onTapUp: (_) => _updateInput(button, false),
      onTapCancel: () => _updateInput(button, false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 50),
        width: width,
        height: height,
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
            fontSize: fontSize,
            fontWeight: FontWeight.w700,
            color: _skin.barLabel.withValues(alpha: 0.82),
          ),
        ),
      ),
    );
  }

  Widget _buildActionButtons() {
    if (widget.layout.id == 'arcade') {
      return _buildArcadeFaceButtons();
    }
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
              label: widget.layout.labelForFace('B'),
              button: RETRO_DEVICE_ID_JOYPAD_B,
              diameter: size,
            ),
          ),
          Positioned(
            right: 0,
            top: 4,
            child: _buildActionButton(
              label: widget.layout.labelForFace('A'),
              button: RETRO_DEVICE_ID_JOYPAD_A,
              diameter: size,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFourFaceButtons() {
    final isArcade = widget.layout.id == 'arcade';
    final size = isArcade
        ? 50.0
        : widget.layout.compact
        ? 46.0
        : 52.0;
    final area = isArcade
        ? 142.0
        : widget.layout.compact
        ? 120.0
        : 132.0;
    final mid = area / 2 - size / 2;

    return SizedBox(
      width: area,
      height: area,
      child: Stack(
        children: [
          Positioned(
            top: 0,
            left: mid,
            child: _buildActionButton(
              label: widget.layout.labelForFace('Y'),
              button: RETRO_DEVICE_ID_JOYPAD_Y,
              diameter: size,
            ),
          ),
          Positioned(
            left: 0,
            top: mid,
            child: _buildActionButton(
              label: widget.layout.labelForFace('X'),
              button: RETRO_DEVICE_ID_JOYPAD_X,
              diameter: size,
            ),
          ),
          Positioned(
            right: 0,
            top: mid,
            child: _buildActionButton(
              label: widget.layout.labelForFace('A'),
              button: RETRO_DEVICE_ID_JOYPAD_A,
              diameter: size,
            ),
          ),
          Positioned(
            bottom: 0,
            left: mid,
            child: _buildActionButton(
              label: widget.layout.labelForFace('B'),
              button: RETRO_DEVICE_ID_JOYPAD_B,
              diameter: size,
            ),
          ),
        ],
      ),
    );
  }

  List<_ArcadeButtonSpec> _arcadeButtonSpecs(
    double size,
    double diameter,
    double offsetX,
  ) {
    final r = diameter / 2;
    return [
      _ArcadeButtonSpec(
        label: 'C',
        button: RETRO_DEVICE_ID_JOYPAD_Y,
        center: Offset(offsetX + r, r),
      ),
      _ArcadeButtonSpec(
        label: 'D',
        button: RETRO_DEVICE_ID_JOYPAD_X,
        center: Offset(offsetX + r + size * 0.42, r),
      ),
      _ArcadeButtonSpec(
        label: 'A',
        button: RETRO_DEVICE_ID_JOYPAD_B,
        center: Offset(offsetX + r, r + size * 0.38),
      ),
      _ArcadeButtonSpec(
        label: 'B',
        button: RETRO_DEVICE_ID_JOYPAD_A,
        center: Offset(offsetX + r + size * 0.42, r + size * 0.38),
      ),
    ];
  }

  Widget _buildArcadeFaceButtons() {
    const diameter = 48.0;
    const areaW = 150.0;
    const areaH = 108.0;
    const groupOffsetX = 18.0;
    final specs = _arcadeButtonSpecs(areaW, diameter, groupOffsetX);

    return Listener(
      behavior: HitTestBehavior.opaque,
      onPointerDown: (event) {
        _setArcadePointerButtons(
          event.pointer,
          _hitArcadeButtons(event.localPosition, specs, diameter),
        );
      },
      onPointerMove: (event) {
        _setArcadePointerButtons(
          event.pointer,
          _hitArcadeButtons(event.localPosition, specs, diameter),
        );
      },
      onPointerUp: (event) => _setArcadePointerButtons(event.pointer, const {}),
      onPointerCancel: (event) =>
          _setArcadePointerButtons(event.pointer, const {}),
      child: SizedBox(
        width: areaW,
        height: areaH,
        child: Stack(
          children: [
            for (final spec in specs)
              Positioned(
                left: spec.center.dx - diameter / 2,
                top: spec.center.dy - diameter / 2,
                child: _buildActionButtonVisual(
                  label: spec.label,
                  button: spec.button,
                  diameter: diameter,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Set<int> _hitArcadeButtons(
    Offset local,
    List<_ArcadeButtonSpec> specs,
    double diameter,
  ) {
    // Treat one touch as a finger pad, not a pin-point. Arcade players often
    // press one button while the finger edge covers adjacent buttons.
    final radius = diameter * 0.95;
    final buttons = <int>{};
    for (final spec in specs) {
      final distance = (local - spec.center).distance;
      if (distance <= radius) {
        buttons.add(spec.button);
      }
    }
    return buttons;
  }

  void _setArcadePointerButtons(int pointer, Set<int> buttons) {
    final old = _arcadePointerButtons[pointer] ?? const <int>{};
    if (_sameButtonSet(old, buttons)) return;

    _arcadePointerButtons.remove(pointer);
    for (final button in old.difference(buttons)) {
      if (!_isButtonHeldByAnotherArcadePointer(button)) {
        _updateInput(button, false);
      }
    }

    if (buttons.isNotEmpty) {
      _arcadePointerButtons[pointer] = Set<int>.from(buttons);
    }
    for (final button in buttons.difference(old)) {
      _updateInput(button, true);
    }
  }

  bool _isButtonHeldByAnotherArcadePointer(int button) {
    return _arcadePointerButtons.values.any((held) => held.contains(button));
  }

  bool _sameButtonSet(Set<int> a, Set<int> b) {
    if (a.length != b.length) return false;
    for (final value in a) {
      if (!b.contains(value)) return false;
    }
    return true;
  }

  ({Color base, Color dark, Color text})? _arcadeFacePalette(String label) {
    if (widget.layout.id != 'arcade') {
      return null;
    }
    switch (label) {
      case 'A':
        return (
          base: const Color(0xFFE53935),
          dark: const Color(0xFFB71C1C),
          text: Colors.white,
        );
      case 'B':
        return (
          base: const Color(0xFFFDD835),
          dark: const Color(0xFFF9A825),
          text: const Color(0xFF1A1400),
        );
      case 'C':
        return (
          base: const Color(0xFF43A047),
          dark: const Color(0xFF2E7D32),
          text: Colors.white,
        );
      case 'D':
        return (
          base: const Color(0xFF1E88E5),
          dark: const Color(0xFF1565C0),
          text: Colors.white,
        );
      default:
        return null;
    }
  }

  Widget _buildActionButton({
    required String label,
    required int button,
    required double diameter,
  }) {
    return GestureDetector(
      onTapDown: (_) => _updateInput(button, true),
      onTapUp: (_) => _updateInput(button, false),
      onTapCancel: () => _updateInput(button, false),
      child: _buildActionButtonVisual(
        label: label,
        button: button,
        diameter: diameter,
      ),
    );
  }

  Widget _buildActionButtonVisual({
    required String label,
    required int button,
    required double diameter,
  }) {
    final isPressed = _inputState[button] == true;
    final arcadePalette = _arcadeFacePalette(label);
    final baseColor = arcadePalette?.base ?? _skin.faceButtonColor(label);
    final darkColor = arcadePalette?.dark ?? _skin.faceButtonDark(label);
    final textColor = arcadePalette?.text ?? _skin.faceButtonText(label);
    final fontSize = widget.layout.id == 'arcade'
        ? 20.0
        : widget.layout.compact
        ? 18.0
        : 21.0;

    return SizedBox(
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
              colors: [baseColor.withValues(alpha: 0.98), baseColor, darkColor],
              stops: const [0.0, 0.48, 1.0],
            ),
            border: Border.all(color: Colors.white.withValues(alpha: 0.20)),
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
    );
  }
}

class _ArcadeButtonSpec {
  const _ArcadeButtonSpec({
    required this.label,
    required this.button,
    required this.center,
  });

  final String label;
  final int button;
  final Offset center;
}
