import 'dart:io';

/// Supported emulator system / libretro core family.
enum EmulatorSystem {
  gba('GBA', 'Game Boy Advance'),
  gb('GB', 'Game Boy / Color'),
  nes('NES', 'FC / NES'),
  arcade('Arcade', '街机 / FBNeo');

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
    this.loadViaPathOnly = false,
    this.nesStylePort2Gamepad = false,
  });

  final EmulatorSystem system;
  final String androidLibraryName;

  /// Primary libretro core filename bundled in the iOS app (Runner/Frameworks).
  final String iosLibraryName;
  final int defaultWidth;
  final int defaultHeight;

  /// Basenames searched on desktop / iOS (in order).
  final List<String> desktopFileNames;

  /// Arcade cores (FBNeo) load ROM sets from disk path, not memory buffers.
  final bool loadViaPathOnly;

  /// fceumm needs port 1 as RETRO_DEVICE_GAMEPAD (513) for 2P co-op.
  final bool nesStylePort2Gamepad;

  String get nativeLibraryLabel =>
      Platform.isAndroid ? androidLibraryName : iosLibraryName;

  double get nativeAspectRatio => defaultWidth / defaultHeight;
}

/// Maps ROM extensions to libretro cores and resolves native library paths.
class EmulatorCoreResolver {
  EmulatorCoreResolver._();

  static const nesExtensions = {'.nes', '.fc', '.fds', '.unf', '.unif'};
  static const gbaExtensions = {'.gba'};
  static const arcadeExtensions = {'.zip', '.7z'};

  static const _gba = EmulatorCoreConfig(
    system: EmulatorSystem.gba,
    androidLibraryName: 'libgpsp_libretro.so',
    iosLibraryName: 'gpsp_libretro_ios.dylib',
    defaultWidth: 240,
    defaultHeight: 160,
    desktopFileNames: [
      'gpsp_libretro_ios.dylib',
      'gpsp_libretro.dylib',
      'libgpsp_libretro.dylib',
      'libgpsp_libretro.so',
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
      'libfceumm_libretro.so',
    ],
    nesStylePort2Gamepad: true,
  );

  static const _fbneo = EmulatorCoreConfig(
    system: EmulatorSystem.arcade,
    androidLibraryName: 'libfbneo_libretro.so',
    iosLibraryName: 'fbneo_libretro_ios.dylib',
    defaultWidth: 384,
    defaultHeight: 224,
    desktopFileNames: [
      'fbneo_libretro_ios.dylib',
      'fbneo_libretro.dylib',
      'libfbneo_libretro.so',
    ],
    loadViaPathOnly: true,
  );

  /// All ROM extensions allowed in the game library file picker.
  static List<String> get supportedRomExtensions => [
    ...gbaExtensions,
    ...nesExtensions,
    ...arcadeExtensions,
  ];

  static EmulatorCoreConfig resolve(
    String romPath, {
    String? fallbackExtension,
  }) {
    var ext = _extensionOf(romPath);
    if (!_isKnownExtension(ext) && fallbackExtension != null) {
      final normalized = fallbackExtension.trim().toLowerCase();
      if (normalized.isNotEmpty) {
        ext = normalized.startsWith('.') ? normalized : '.$normalized';
      }
    }
    if (nesExtensions.contains(ext)) {
      return _nes;
    }
    if (arcadeExtensions.contains(ext)) {
      return _fbneo;
    }
    if (gbaExtensions.contains(ext)) {
      return _gba;
    }
    throw UnsupportedError('不支持的 ROM 格式: $ext');
  }

  static bool _isKnownExtension(String ext) {
    return nesExtensions.contains(ext) ||
        gbaExtensions.contains(ext) ||
        arcadeExtensions.contains(ext);
  }

  /// Lowercase extension including dot, e.g. `.zip`.
  static String extensionFromPath(String path) => _extensionOf(path);

  /// Whether [path] has a supported ROM extension.
  static bool isSupportedRomPath(String path) =>
      _isKnownExtension(extensionFromPath(path));

  /// Resolve platform from stored [extension] (with or without leading dot).
  static EmulatorSystem systemForExtension(String extension) {
    final ext = extension.trim().toLowerCase();
    final normalized = ext.startsWith('.') ? ext : '.$ext';
    return resolve('game$normalized').system;
  }

  /// Human-readable list for import errors / empty states.
  static String get supportedFormatsHint =>
      'GBA (.gba)、FC/NES (.nes/.fc 等)、街机（FBNeo ROM set 的 .zip/.7z）';

  static Future<String?> resolveCorePath(
    String romPath, {
    String? fallbackExtension,
  }) async {
    final config = resolve(romPath, fallbackExtension: fallbackExtension);
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
