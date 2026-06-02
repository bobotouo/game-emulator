import '../../core/libretro/emulator_core_resolver.dart';

/// Portrait center-column styling (Select/Start, COIN/START, etc.).
class GamepadCenterStyle {
  const GamepadCenterStyle({
    this.tiltRadians = -0.14,
    this.buttonSpacing = 10,
    this.buttonWidth = 72,
    this.buttonHeight = 24,
  });

  final double tiltRadians;
  final double buttonSpacing;
  final double buttonWidth;
  final double buttonHeight;
}

/// Which on-screen controls to show for a given core / game style.
class GamepadLayout {
  const GamepadLayout({
    required this.id,
    required this.name,
    this.showDpad = true,
    this.showSelectStart = true,
    this.showFaceAB = true,
    this.showFaceXY = false,
    this.showShoulders = false,
    this.compact = false,
    this.useJoystickVisual = false,
    this.centerButtonLabels,
    this.centerStyle,
    this.faceButtonLabels,
  });

  final String id;
  final String name;
  final bool showDpad;

  /// Round 8-way stick instead of cross D-pad (arcade).
  final bool useJoystickVisual;
  final bool showSelectStart;
  final bool showFaceAB;
  final bool showFaceXY;
  final bool showShoulders;
  final bool compact;

  /// Center bar labels, e.g. 投币 / 开始 (maps to Select / Start).
  final (String, String)? centerButtonLabels;

  final GamepadCenterStyle? centerStyle;

  /// Overrides face labels: two-button `B`,`A` or four-button `Y`,`X`,`A`,`B`.
  final List<String>? faceButtonLabels;

  String get centerLeftLabel => centerButtonLabels?.$1 ?? 'SELECT';
  String get centerRightLabel => centerButtonLabels?.$2 ?? 'START';

  GamepadCenterStyle get resolvedCenterStyle =>
      centerStyle ??
      GamepadCenterStyle(
        buttonSpacing: compact ? 8 : 10,
      );

  /// Retro face key used in [VirtualGamepad] builders.
  String labelForFace(String retroKey) {
    final overrides = faceButtonLabels;
    if (overrides == null || overrides.isEmpty) {
      return retroKey;
    }
    const fourOrder = ['Y', 'X', 'A', 'B'];
    const twoOrder = ['B', 'A'];
    final order = showFaceXY && showFaceAB ? fourOrder : twoOrder;
    final index = order.indexOf(retroKey);
    if (index < 0 || index >= overrides.length) {
      return retroKey;
    }
    return overrides[index];
  }

  List<String> get faceButtons {
    final buttons = <String>[];
    if (showFaceAB) {
      buttons.addAll(['B', 'A']);
    }
    if (showFaceXY) {
      buttons.insertAll(0, ['Y', 'X']);
    }
    return buttons;
  }
}

class GamepadLayouts {
  GamepadLayouts._();

  /// Game Boy / GBC: 十字键 + A/B + Select/Start
  static const gb = GamepadLayout(
    id: 'gb',
    name: 'GB / GBC',
    showDpad: true,
    showSelectStart: true,
    showFaceAB: true,
  );

  /// GBA: 十字键 + A/B + Select/Start + L/R
  static const gba = GamepadLayout(
    id: 'gba',
    name: 'GBA',
    showDpad: true,
    showSelectStart: true,
    showFaceAB: true,
    showShoulders: true,
  );

  static const gbaFull = GamepadLayout(
    id: 'gba_full',
    name: 'GBA（含肩键）',
    showDpad: true,
    showSelectStart: true,
    showFaceAB: true,
    showShoulders: true,
  );

  /// NES / FC: 十字键 + A/B + Select/Start
  static const nes = GamepadLayout(
    id: 'nes',
    name: 'NES',
    showDpad: true,
    showSelectStart: true,
    showFaceAB: true,
  );

  /// FBNeo 街机：摇杆 + A–D + COIN/START（Select=投币, Start=开始）
  static const arcade = GamepadLayout(
    id: 'arcade',
    name: '街机',
    showDpad: true,
    useJoystickVisual: true,
    showSelectStart: true,
    centerButtonLabels: ('COIN', 'START'),
    centerStyle: GamepadCenterStyle(
      tiltRadians: -0.22,
      buttonSpacing: 18,
      buttonWidth: 56,
      buttonHeight: 20,
    ),
    showFaceAB: true,
    showFaceXY: true,
    // Y=B, X=D, A=C, B=A (FBNeo Classic retropad)
    faceButtonLabels: ['B', 'D', 'C', 'A'],
  );

  /// SNES 等：十字键 + A/B/X/Y + 肩键
  static const snes = GamepadLayout(
    id: 'snes',
    name: 'SNES',
    showDpad: true,
    showSelectStart: true,
    showFaceAB: true,
    showFaceXY: true,
    showShoulders: true,
  );

  static const minimal = GamepadLayout(
    id: 'minimal',
    name: '精简',
    showDpad: true,
    showSelectStart: false,
    showFaceAB: true,
    compact: true,
  );

  static const all = [gb, gba, gbaFull, nes, arcade, snes, minimal];

  /// Picks controls from ROM / core system (when settings layout = 自动).
  static GamepadLayout forSystem(EmulatorSystem system) {
    switch (system) {
      case EmulatorSystem.gba:
        return gba;
      case EmulatorSystem.nes:
        return nes;
      case EmulatorSystem.gb:
        return gb;
      case EmulatorSystem.arcade:
        return arcade;
    }
  }

  static GamepadLayout byId(String id) {
    return all.firstWhere(
      (l) => l.id == id,
      orElse: () => gba,
    );
  }
}
