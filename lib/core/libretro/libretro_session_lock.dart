import 'dart:async';

/// Serializes libretro core load/unload across emulator and thumbnail generation.
/// Cores are not safe to initialize concurrently in one process.
class LibretroSessionLock {
  static Future<void> _tail = Future.value();

  static Future<T> runExclusive<T>(Future<T> Function() action) {
    final completer = Completer<T>();
    _tail = _tail.then((_) async {
      try {
        completer.complete(await action());
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }
}
