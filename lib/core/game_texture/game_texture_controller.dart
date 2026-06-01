import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:ffi/ffi.dart';

import 'game_texture_bindings.dart';

/// Registers a platform [Texture] and uploads RGBA frames via native FFI (no Dart decode).
class GameTextureController {
  static const MethodChannel _channel = MethodChannel('game_texture');
  static Future<void> _lifecycle = Future.value();

  static bool get isSupported => Platform.isIOS || Platform.isAndroid;

  int? textureId;
  int _width = 0;
  int _height = 0;

  bool get isReady => textureId != null && _width > 0 && _height > 0;

  Future<void> create(int width, int height) async {
    await _runExclusive(() async {
      final oldId = textureId;
      textureId = null;
      _width = 0;
      _height = 0;
      if (oldId != null) {
        await _channel.invokeMethod<void>('disposeTexture', {'textureId': oldId});
      }
      final id = await _channel.invokeMethod<int>('createTexture', {
        'width': width,
        'height': height,
      });
      if (id == null) {
        throw StateError('createTexture returned null');
      }
      textureId = id;
      _width = width;
      _height = height;
    });
  }

  Future<void> recreate(int width, int height) async {
    if (width == _width && height == _height && isReady) {
      return;
    }
    await create(width, height);
  }

  /// Upload from a Dart-owned RGBA buffer.
  void presentFrameBytes(Uint8List rgba, int width, int height) {
    final id = textureId;
    if (id == null || width <= 0 || height <= 0) {
      return;
    }
    if (width != _width || height != _height) {
      return;
    }

    final ptr = calloc<Uint8>(rgba.length);
    try {
      ptr.asTypedList(rgba.length).setAll(0, rgba);
      presentFrame(ptr, width, height);
    } finally {
      calloc.free(ptr);
    }
  }

  /// Upload from native [src] (bound display buffer, tight RGBA rows).
  void presentFrame(Pointer<Uint8> src, int width, int height) {
    final id = textureId;
    if (id == null || width <= 0 || height <= 0) {
      return;
    }
    if (width != _width || height != _height) {
      return;
    }

    final pitch = width * 4;
    // Upload + notify Flutter: native code calls textureFrameAvailable / scheduleFrame.
    gameTextureUpload(src, width, height, pitch);
  }

  Future<void> dispose() async {
    await _runExclusive(() async {
      final id = textureId;
      textureId = null;
      _width = 0;
      _height = 0;
      if (id != null) {
        await _channel.invokeMethod<void>('disposeTexture', {'textureId': id});
      }
    });
  }

  static Future<void> _runExclusive(Future<void> Function() action) {
    final next = _lifecycle.then((_) => action());
    _lifecycle = next.catchError((_) {});
    return next;
  }
}
