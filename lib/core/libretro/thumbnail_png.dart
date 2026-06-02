import 'dart:typed_data';

import 'package:image/image.dart' as img;

/// PNG-encodes RGBA8888 pixels (runs in [Isolate.run] from thumbnail pipeline).
Uint8List? encodeRgbaToPng(Uint8List rgba, int width, int height) {
  if (width <= 0 || height <= 0 || width > 2048 || height > 2048) {
    return null;
  }
  final expected = width * height * 4;
  if (rgba.length < expected) {
    return null;
  }

  final view = rgba.length == expected
      ? rgba
      : Uint8List.sublistView(rgba, 0, expected);
  final image = img.Image.fromBytes(
    width: width,
    height: height,
    bytes: view.buffer,
    bytesOffset: view.offsetInBytes,
    numChannels: 4,
    order: img.ChannelOrder.rgba,
  );
  return Uint8List.fromList(img.encodePng(image));
}
