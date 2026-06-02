import 'libretro_core.dart';

/// One live [LibretroCore] per native `.so` path.
///
/// FBNeo (and some libretro cores) cannot safely call [LibretroCore.dispose]
/// (`retro_deinit`) and [LibretroCore.initialize] (`retro_init`) again in the
/// same process. We keep cores alive and only [LibretroCore.unloadGame] between
/// thumbnail capture and gameplay sessions.
class LibretroCoreRegistry {
  LibretroCoreRegistry._();

  static final Map<String, _RegistryEntry> _entries = {};

  /// Returns an initialized core for [corePath], incrementing its lease count.
  static LibretroCore acquire(String corePath) {
    var entry = _entries[corePath];
    if (entry == null) {
      final core = LibretroCore();
      if (!core.initialize(corePath)) {
        throw StateError('Failed to initialize libretro core: $corePath');
      }
      entry = _RegistryEntry(core);
      _entries[corePath] = entry;
    }
    entry.refCount++;
    return entry.core;
  }

  /// Ends a lease; unloads any ROM but does not call `retro_deinit`.
  static void release(String corePath) {
    final entry = _entries[corePath];
    if (entry == null) {
      return;
    }
    entry.refCount--;
    if (entry.refCount < 0) {
      entry.refCount = 0;
    }
    if (entry.core.isGameLoaded) {
      entry.core.unloadGame();
    }
  }

  /// Full native teardown — only for tests or explicit app shutdown.
  static void disposeCore(String corePath) {
    final entry = _entries.remove(corePath);
    entry?.core.dispose();
  }

  static void disposeAll() {
    for (final path in _entries.keys.toList()) {
      disposeCore(path);
    }
  }
}

class _RegistryEntry {
  _RegistryEntry(this.core);

  final LibretroCore core;
  int refCount = 0;
}
