import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:path_provider/path_provider.dart';
import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import 'emulator_core_resolver.dart';
import 'libretro_core.dart';

/// Generates thumbnail images for ROMs by running the emulator briefly.
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
      final corePath = await EmulatorCoreResolver.resolveCorePath(romPath);
      if (corePath == null) {
        final config = EmulatorCoreResolver.resolve(romPath);
        print(
          'Core not found (${config.nativeLibraryLabel}). '
          'On iOS run: ./scripts/build_all_cores.sh ios',
        );
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

      // Run long enough to get past boot logos. Frames are captured from the
      // C ring buffer (gConvBuf) after each retro_run call.
      Uint8List? bestFrame;
      Uint8List? latestFrame;
      int frameWidth = 0;
      int frameHeight = 0;
      double bestScore = -1;

      for (int i = 0; i < 600; i++) {
        core.runFrame();
        final capture = emu_loop.captureLastFrame();
        if (capture != null) {
          latestFrame = capture.rgba;
          frameWidth = capture.width;
          frameHeight = capture.height;
          if (i >= 90) {
            final score = _scoreFrame(capture.rgba, capture.width, capture.height);
            if (score > bestScore) {
              bestScore = score;
              bestFrame = capture.rgba;
            }
          }
        }
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
