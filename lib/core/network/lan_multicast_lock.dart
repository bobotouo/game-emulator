import 'dart:io';

import 'package:flutter/services.dart';

/// Keeps Wi‑Fi multicast/broadcast working on Android while discovering rooms.
abstract final class LanMulticastLock {
  static const _channel = MethodChannel('lan_multicast_lock');

  static Future<void> acquire() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('acquire');
    } catch (_) {}
  }

  static Future<void> release() async {
    if (!Platform.isAndroid) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('release');
    } catch (_) {}
  }
}
