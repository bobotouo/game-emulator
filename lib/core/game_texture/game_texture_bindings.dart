import 'dart:ffi';
import 'dart:io';

final DynamicLibrary gameTextureLibrary = () {
  if (Platform.isAndroid) {
    return DynamicLibrary.open('libgame_texture.so');
  }
  return DynamicLibrary.process();
}();

typedef GameTextureUploadNative =
    Void Function(
      Pointer<Uint8> src,
      Int32 width,
      Int32 height,
      Int32 pitchBytes,
    );

typedef GameTextureUpload =
    void Function(Pointer<Uint8> src, int width, int height, int pitchBytes);

/// FFI entry: upload RGBA rows into the active platform texture.
final GameTextureUpload gameTextureUpload = gameTextureLibrary
    .lookupFunction<GameTextureUploadNative, GameTextureUpload>(
      'game_texture_upload_rgba',
    );
