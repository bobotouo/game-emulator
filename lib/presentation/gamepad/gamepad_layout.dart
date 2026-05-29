import '../../core/libretro/emulator_core_resolver.dart';

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
  });

  final String id;
  final String name;
  final bool showDpad;
  final bool showSelectStart;
  final bool showFaceAB;
  final bool showFaceXY;
  final bool showShoulders;
  final bool compact;

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

  static const all = [gb, gba, gbaFull, nes, snes, minimal];

  /// Picks controls from ROM / core system (when settings layout = 自动).
  static GamepadLayout forSystem(EmulatorSystem system) {
    switch (system) {
      case EmulatorSystem.gba:
        return gba;
      case EmulatorSystem.nes:
        return nes;
      case EmulatorSystem.gb:
        return gb;
    }
  }

  static GamepadLayout byId(String id) {
    return all.firstWhere(
      (l) => l.id == id,
      orElse: () => gba,
    );
  }
}
