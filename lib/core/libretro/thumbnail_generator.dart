import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import 'libretro_core.dart';

/// Generates thumbnail images for GBA ROMs by running the emulator briefly
class ThumbnailGenerator {
  /// Generate a thumbnail for a ROM file
  /// Returns the path to the saved thumbnail image
  static Future<String?> generateThumbnail(
    String romPath,
    String gameId,
  ) async {
    try {
      print('Generating thumbnail for: $romPath');

      // Get the core path
      final corePath = await _getCorePath();
      if (corePath == null) {
        print('Core not found');
        return null;
      }

      // Initialize core
      final core = LibretroCore();
      if (!core.initialize(corePath)) {
        print('Failed to initialize core');
        return null;
      }

      // Load ROM
      if (!core.loadGame(romPath)) {
        print('Failed to load ROM');
        core.dispose();
        return null;
      }

      // Set up frame capture
      Uint8List? bestFrame;
      Uint8List? latestFrame;
      int frameWidth = 0;
      int frameHeight = 0;
      int frameIndex = 0;
      double bestScore = -1;

      core.videoCallback = (framebuffer, width, height, pitch) {
        if (width > 0 && height > 0) {
          latestFrame = Uint8List.fromList(framebuffer);
          frameWidth = width;
          frameHeight = height;

          if (frameIndex >= 90) {
            final score = _scoreFrame(framebuffer, width, height);
            if (score > bestScore) {
              bestScore = score;
              bestFrame = Uint8List.fromList(framebuffer);
            }
          }
        }
      };

      // Run long enough to get past boot logos, then keep the frame with the
      // most visible image content so transient black frames are ignored.
      for (int i = 0; i < 600; i++) {
        frameIndex = i;
        core.runFrame();
      }

      // Dispose core
      core.dispose();

      final capturedFrame = bestFrame ?? latestFrame;
      if (capturedFrame == null || frameWidth == 0 || frameHeight == 0) {
        print('No frame captured');
        return null;
      }

      // Save thumbnail
      final thumbnailPath = await _saveThumbnail(
        capturedFrame,
        frameWidth,
        frameHeight,
        gameId,
      );

      print('Thumbnail saved: $thumbnailPath');
      return thumbnailPath;
    } catch (e) {
      print('Error generating thumbnail: $e');
      return null;
    }
  }

  static double _scoreFrame(Uint8List rgbaData, int width, int height) {
    final totalPixels = width * height;
    var luminanceSum = 0.0;
    var luminanceSquares = 0.0;
    var saturationSum = 0.0;
    var count = 0;

    for (int pixel = 0; pixel < totalPixels; pixel += 16) {
      final offset = pixel * 4;
      final r = rgbaData[offset];
      final g = rgbaData[offset + 1];
      final b = rgbaData[offset + 2];
      final luminance = (r + g + b) / 3.0;
      final maxChannel = math.max(r, math.max(g, b));
      final minChannel = math.min(r, math.min(g, b));

      luminanceSum += luminance;
      luminanceSquares += luminance * luminance;
      saturationSum += maxChannel - minChannel;
      count++;
    }

    if (count == 0) return 0;

    final average = luminanceSum / count;
    final variance = math.max(
      0.0,
      luminanceSquares / count - average * average,
    );
    final contrast = math.sqrt(variance);
    final saturation = saturationSum / count;

    return average + contrast * 2 + saturation * 0.5;
  }

  /// Save frame data as PNG image
  static Future<String?> _saveThumbnail(
    Uint8List rgbaData,
    int width,
    int height,
    String gameId,
  ) async {
    try {
      // Get app documents directory
      final appDir = await getApplicationDocumentsDirectory();
      final thumbnailDir = Directory('${appDir.path}/thumbnails');

      if (!await thumbnailDir.exists()) {
        await thumbnailDir.create(recursive: true);
      }

      final thumbnailPath = '${thumbnailDir.path}/$gameId.png';

      // Convert RGBA to PNG using ui.Image
      final completer = Completer<ui.Image>();
      ui.decodeImageFromPixels(
        rgbaData,
        width,
        height,
        ui.PixelFormat.rgba8888,
        (image) => completer.complete(image),
      );

      final image = await completer.future;

      // Convert to byte data
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);

      if (byteData == null) {
        image.dispose();
        return null;
      }

      // Save to file
      final file = File(thumbnailPath);
      await file.writeAsBytes(byteData.buffer.asUint8List());

      image.dispose();

      return thumbnailPath;
    } catch (e) {
      print('Error saving thumbnail: $e');
      return null;
    }
  }

  /// Get the libretro core path
  static Future<String?> _getCorePath() async {
    if (Platform.isAndroid) {
      return 'libmgba_libretro.so';
    }

    final possiblePaths = [
      '${Directory.current.path}/assets/cores/mgba_libretro.dylib',
      '${Directory.current.path}/build/libretro/macos/mgba_libretro.dylib',
      '${Directory.current.path}/assets/cores/mgba_libretro.so',
      'mgba_libretro.dylib',
    ];

    for (final path in possiblePaths) {
      if (await File(path).exists()) {
        return path;
      }
    }

    return null;
  }

  /// Delete a thumbnail
  static Future<void> deleteThumbnail(String gameId) async {
    try {
      final appDir = await getApplicationDocumentsDirectory();
      final thumbnailPath = '${appDir.path}/thumbnails/$gameId.png';
      final file = File(thumbnailPath);
      if (await file.exists()) {
        await file.delete();
      }
    } catch (e) {
      print('Error deleting thumbnail: $e');
    }
  }
}
