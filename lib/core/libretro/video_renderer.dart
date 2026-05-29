import 'dart:ffi' hide Size;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../game_texture/game_texture_controller.dart';

/// Holds the latest RGBA frame copied from the libretro core.
class FrameBufferManager extends ChangeNotifier {
  int width;
  int height;
  late Uint8List _pixels;
  Pointer<Uint8>? _nativePixels;
  final bool _nativeAllocation;
  Uint8List? _uploadSnapshot;
  bool _hasPendingFrame = false;
  bool _notifyScheduled = false;

  FrameBufferManager({
    required this.width,
    required this.height,
    bool nativeAllocation = false,
  }) : _nativeAllocation = nativeAllocation {
    _allocateBuffer();
  }

  Uint8List get pixels => _pixels;

  /// Native heap pointer for FFI texture upload (when [nativeAllocation] is true).
  Pointer<Uint8>? get nativePixels => _nativePixels;

  void disposeBuffer() {
    if (_nativePixels != null) {
      calloc.free(_nativePixels!);
      _nativePixels = null;
    }
  }

  void _allocateBuffer() {
    disposeBuffer();
    final byteCount = width * height * 4;
    if (_nativeAllocation) {
      _nativePixels = calloc<Uint8>(byteCount);
      _pixels = _nativePixels!.asTypedList(byteCount);
    } else {
      _pixels = Uint8List(byteCount);
      _nativePixels = null;
    }
    _uploadSnapshot = null;
  }

  /// Returns true when the backing store was reallocated.
  bool ensureSize(int newWidth, int newHeight) {
    if (newWidth == width && newHeight == height) {
      return false;
    }
    width = newWidth;
    height = newHeight;
    _allocateBuffer();
    return true;
  }

  /// Copy core output into a stable buffer, then notify the display once.
  void updateFrom(Uint8List src) {
    if (src.length != _pixels.length) {
      _pixels = Uint8List(src.length);
    }
    _pixels.setRange(0, src.length, src);
    markFrameUpdated();
  }

  /// Called when [LibretroCore.bindDisplayBuffer] wrote into [pixels].
  void markFrameUpdated() {
    _hasPendingFrame = true;
    if (_notifyScheduled) {
      return;
    }
    _notifyScheduled = true;
    SchedulerBinding.instance.scheduleFrameCallback((_) {
      _notifyScheduled = false;
      if (!_hasPendingFrame) {
        return;
      }
      _hasPendingFrame = false;
      notifyListeners();
    });
  }

  Uint8List snapshotForUpload() {
    final byteCount = width * height * 4;
    if (byteCount <= 0 || _pixels.length < byteCount) {
      return Uint8List(0);
    }
    if (_uploadSnapshot == null || _uploadSnapshot!.length != byteCount) {
      _uploadSnapshot = Uint8List(byteCount);
    }
    _uploadSnapshot!.setRange(0, byteCount, _pixels);
    return _uploadSnapshot!;
  }
}

/// Renders the core framebuffer at native resolution, then scales with GPU.
class GBADisplay extends StatefulWidget {
  final FrameBufferManager frameBuffer;
  final int width;
  final int height;
  final double? displayAspectRatio;
  final bool stretch;
  final double brightness;

  const GBADisplay({
    super.key,
    required this.frameBuffer,
    required this.width,
    required this.height,
    this.displayAspectRatio,
    this.stretch = false,
    this.brightness = 1,
  });

  @override
  State<GBADisplay> createState() => _GBADisplayState();
}

class _GBADisplayState extends State<GBADisplay> {
  ui.Image? _image;
  bool _decodeScheduled = false;
  int _frameGeneration = 0;
  final _repaint = _DisplayRepaintNotifier();

  @override
  void initState() {
    super.initState();
    widget.frameBuffer.addListener(_onFrameAvailable);
  }

  @override
  void didUpdateWidget(covariant GBADisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frameBuffer != widget.frameBuffer) {
      oldWidget.frameBuffer.removeListener(_onFrameAvailable);
      widget.frameBuffer.addListener(_onFrameAvailable);
    }
    if (oldWidget.brightness != widget.brightness) {
      _repaint.repaint();
    }
  }

  @override
  void dispose() {
    _frameGeneration++;
    widget.frameBuffer.removeListener(_onFrameAvailable);
    _image?.dispose();
    super.dispose();
  }

  void _onFrameAvailable() {
    if (!mounted) {
      return;
    }
    _frameGeneration++;
    if (_decodeScheduled) {
      return;
    }
    _decodeScheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _decodeScheduled = false;
      if (!mounted) {
        return;
      }
      _uploadLatestFrame(_frameGeneration);
    });
  }

  void _uploadLatestFrame(int generation) {
    final fb = widget.frameBuffer;
    final width = fb.width;
    final height = fb.height;
    if (width <= 0 || height <= 0) {
      return;
    }

    final snapshot = fb.snapshotForUpload();
    if (snapshot.isEmpty) {
      return;
    }

    if (!mounted || generation != _frameGeneration) {
      return;
    }

    final image = ui.decodeImageFromPixelsSync(
      snapshot,
      width,
      height,
      ui.PixelFormat.rgba8888,
    );

    if (!mounted || generation != _frameGeneration) {
      image.dispose();
      return;
    }

    _image?.dispose();
    _image = image;
    _repaint.repaint();
  }

  @override
  Widget build(BuildContext context) {
    final gameSize = Size(widget.width.toDouble(), widget.height.toDouble());

    // Paint only at native resolution (240×160 etc.), never per screen pixel.
    final nativeView = RepaintBoundary(
      child: ListenableBuilder(
        listenable: _repaint,
        builder: (context, child) {
          return CustomPaint(
            size: gameSize,
            painter: _NativeScalePainter(
              image: _image,
              brightness: widget.brightness,
            ),
          );
        },
      ),
    );

    final scaled = widget.stretch
        ? FittedBox(fit: BoxFit.fill, child: nativeView)
        : FittedBox(fit: BoxFit.contain, child: nativeView);

    if (widget.stretch) {
      return SizedBox.expand(child: scaled);
    }

    return AspectRatio(
      aspectRatio: widget.displayAspectRatio ?? widget.width / widget.height,
      child: scaled,
    );
  }
}

class _DisplayRepaintNotifier extends ChangeNotifier {
  void repaint() => notifyListeners();
}

class _NativeScalePainter extends CustomPainter {
  final ui.Image? image;
  final double brightness;

  _NativeScalePainter({required this.image, required this.brightness});

  @override
  void paint(Canvas canvas, Size size) {
    if (image == null) {
      canvas.drawRect(Offset.zero & size, Paint()..color = Colors.black);
      return;
    }

    final paint = Paint()..filterQuality = FilterQuality.none;
    final b = brightness.clamp(0.5, 1.5);
    if ((b - 1.0).abs() > 0.01) {
      paint.colorFilter = ColorFilter.matrix(<double>[
        b, 0, 0, 0, 0,
        0, b, 0, 0, 0,
        0, 0, b, 0, 0,
        0, 0, 0, 1, 0,
      ]);
    }

    canvas.drawImageRect(
      image!,
      Rect.fromLTWH(0, 0, image!.width.toDouble(), image!.height.toDouble()),
      Rect.fromLTWH(0, 0, size.width, size.height),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _NativeScalePainter oldDelegate) {
    return oldDelegate.image != image || oldDelegate.brightness != brightness;
  }
}

/// Flutter [Texture] backed by platform GPU buffer (iOS CVPixelBuffer / Android Surface).
class NativeGameDisplay extends StatelessWidget {
  final GameTextureController texture;
  final int width;
  final int height;
  final double? displayAspectRatio;
  final bool stretch;
  final double brightness;

  const NativeGameDisplay({
    super.key,
    required this.texture,
    required this.width,
    required this.height,
    this.displayAspectRatio,
    this.stretch = false,
    this.brightness = 1,
  });

  @override
  Widget build(BuildContext context) {
    final textureId = texture.textureId;
    if (textureId == null) {
      return const ColoredBox(color: Colors.black);
    }

    final gameSize = Size(width.toDouble(), height.toDouble());
    Widget view = Texture(textureId: textureId);

    final b = brightness.clamp(0.5, 1.5);
    if ((b - 1.0).abs() > 0.01) {
      view = ColorFiltered(
        colorFilter: ColorFilter.matrix(<double>[
          b, 0, 0, 0, 0,
          0, b, 0, 0, 0,
          0, 0, b, 0, 0,
          0, 0, 0, 1, 0,
        ]),
        child: view,
      );
    }

    final nativeView = SizedBox(width: gameSize.width, height: gameSize.height, child: view);

    final scaled = stretch
        ? FittedBox(fit: BoxFit.fill, child: nativeView)
        : FittedBox(fit: BoxFit.contain, child: nativeView);

    if (stretch) {
      return SizedBox.expand(child: scaled);
    }

    return AspectRatio(
      aspectRatio: displayAspectRatio ?? width / height,
      child: scaled,
    );
  }
}
