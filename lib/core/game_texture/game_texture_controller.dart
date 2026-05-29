import 'dart:ffi';
import 'dart:io';

import 'package:flutter/services.dart';

import 'game_texture_bindings.dart';

/// Registers a platform [Texture] and uploads RGBA frames via native FFI (no Dart decode).
class GameTextureController {
  static const MethodChannel _channel = MethodChannel('game_texture');

  static bool get isSupported => Platform.isIOS || Platform.isAndroid;

  int? textureId;
  int _width = 0;
  int _height = 0;

  bool get isReady => textureId != null && _width > 0 && _height > 0;

  Future<void> create(int width, int height) async {
    await dispose();
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
  }

  Future<void> recreate(int width, int height) async {
    if (width == _width && height == _height && isReady) {
      return;
    }
    await create(width, height);
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
    final id = textureId;
    textureId = null;
    _width = 0;
    _height = 0;
    if (id != null) {
      await _channel.invokeMethod<void>('disposeTexture', {'textureId': id});
    }
  }
}
