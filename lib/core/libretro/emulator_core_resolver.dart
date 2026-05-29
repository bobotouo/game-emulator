import 'dart:io';

/// Supported emulator system / libretro core family.
enum EmulatorSystem {
  gba('GBA', 'Game Boy Advance'),
  gb('GB', 'Game Boy / Color'),
  nes('NES', 'FC / NES');

  const EmulatorSystem(this.shortName, this.label);

  final String shortName;
  final String label;
}

/// Describes which libretro core and framebuffer to use for a ROM.
class EmulatorCoreConfig {
  const EmulatorCoreConfig({
    required this.system,
    required this.androidLibraryName,
    required this.iosLibraryName,
    required this.defaultWidth,
    required this.defaultHeight,
    required this.desktopFileNames,
  });

  final EmulatorSystem system;
  final String androidLibraryName;

  /// Primary libretro core filename bundled in the iOS app (Runner/Frameworks).
  final String iosLibraryName;
  final int defaultWidth;
  final int defaultHeight;

  /// Basenames searched on desktop / iOS (in order).
  final List<String> desktopFileNames;

  String get nativeLibraryLabel =>
      Platform.isAndroid ? androidLibraryName : iosLibraryName;

  double get nativeAspectRatio => defaultWidth / defaultHeight;
}

/// Maps ROM extensions to libretro cores and resolves native library paths.
class EmulatorCoreResolver {
  EmulatorCoreResolver._();

  static const nesExtensions = {'.nes', '.fds', '.unf', '.unif'};
  static const gbaExtensions = {'.gba'};
  static const gbExtensions = {'.gb', '.gbc'};

  static const _gba = EmulatorCoreConfig(
    system: EmulatorSystem.gba,
    androidLibraryName: 'libmgba_libretro.so',
    iosLibraryName: 'mgba_libretro_ios.dylib',
    defaultWidth: 240,
    defaultHeight: 160,
    desktopFileNames: [
      'mgba_libretro_ios.dylib',
      'mgba_libretro.dylib',
      'libmgba_libretro.dylib',
    ],
  );

  static const _nes = EmulatorCoreConfig(
    system: EmulatorSystem.nes,
    androidLibraryName: 'libfceumm_libretro.so',
    iosLibraryName: 'fceumm_libretro_ios.dylib',
    defaultWidth: 256,
    defaultHeight: 240,
    desktopFileNames: [
      'fceumm_libretro_ios.dylib',
      'fceumm_libretro.dylib',
      'libfceumm_libretro.dylib',
    ],
  );

  /// All ROM extensions allowed in the game library file picker.
  static List<String> get supportedRomExtensions => [
    ...gbaExtensions,
    ...gbExtensions,
    ...nesExtensions,
  ];

  static EmulatorCoreConfig resolve(String romPath) {
    final ext = _extensionOf(romPath);
    if (nesExtensions.contains(ext)) {
      return _nes;
    }
    if (gbaExtensions.contains(ext) || gbExtensions.contains(ext)) {
      return _gba;
    }
    throw UnsupportedError('不支持的 ROM 格式: $ext');
  }

  static Future<String?> resolveCorePath(String romPath) async {
    final config = resolve(romPath);
    return resolveCorePathForConfig(config);
  }

  static Future<String?> resolveCorePathForConfig(
    EmulatorCoreConfig config,
  ) async {
    if (Platform.isAndroid) {
      return config.androidLibraryName;
    }

    if (Platform.isIOS) {
      return _resolveIosCorePath(config);
    }

    final projectRoot = Directory.current.path;
    final searchDirs = [
      '$projectRoot/ios/Runner/Frameworks',
      '$projectRoot/build/libretro/macos',
      '$projectRoot/build/libretro/ios',
    ];

    for (final dir in searchDirs) {
      final path = await _resolveFromDirectory(dir, config.desktopFileNames);
      if (path != null) {
        return path;
      }
    }

    for (final name in config.desktopFileNames) {
      if (await File(name).exists()) {
        return name;
      }
    }

    return null;
  }

  static Future<String?> _resolveIosCorePath(EmulatorCoreConfig config) async {
    final roots = <String>{};
    var dir = File(Platform.resolvedExecutable).parent;

    // Walk up to Runner.app (or *.app) and collect Frameworks folders.
    for (var i = 0; i < 6; i++) {
      if (dir.path.endsWith('.app')) {
        roots.add('${dir.path}/Frameworks');
      }
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }

    roots.add('${File(Platform.resolvedExecutable).parent.path}/Frameworks');

    for (final root in roots) {
      final path = await _resolveFromDirectory(root, config.desktopFileNames);
      if (path != null) {
        return path;
      }
    }

    return null;
  }

  static Future<String?> _resolveFromDirectory(
    String dir,
    List<String> fileNames,
  ) async {
    for (final name in fileNames) {
      final path = '$dir/$name';
      if (await File(path).exists()) {
        return path;
      }
    }
    return null;
  }

  static String _extensionOf(String path) {
    final dot = path.lastIndexOf('.');
    if (dot < 0) {
      return '';
    }
    return path.substring(dot).toLowerCase();
  }
}
