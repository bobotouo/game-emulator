import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Loads the GBA display fragment shader once for all [GBADisplay] instances.
class GbaDisplayShader {
  GbaDisplayShader._();

  static ui.FragmentProgram? _program;
  static Future<void>? _loading;

  static Future<void> ensureLoaded() {
    return _loading ??= ui.FragmentProgram.fromAsset(
      'shaders/gba_display.frag',
    ).then((program) {
      _program = program;
    });
  }

  static ui.FragmentShader createShader() {
    final program = _program;
    if (program == null) {
      throw StateError('GbaDisplayShader.ensureLoaded() must complete first');
    }
    return program.fragmentShader();
  }
}

/// Notifies only the display layer to repaint, avoiding full widget rebuilds.
class _DisplayRepaint extends ChangeNotifier {
  void repaint() => notifyListeners();
}

/// Holds the latest RGBA frame copied from the libretro core.
class FrameBufferManager extends ChangeNotifier {
  final int width;
  final int height;
  late Uint8List _pixels;

  FrameBufferManager({required this.width, required this.height}) {
    _pixels = Uint8List(width * height * 4);
  }

  Uint8List get pixels => _pixels;

  /// Copy core output into a stable buffer, then notify the display once.
  void updateFrom(Uint8List src) {
    if (src.length != _pixels.length) {
      _pixels = Uint8List(src.length);
    }
    _pixels.setRange(0, src.length, src);
    notifyListeners();
  }
}

/// Video renderer using Impeller fragment shader for GBA display.
class GBADisplay extends StatefulWidget {
  final FrameBufferManager frameBuffer;
  final int width;
  final int height;
  final double? displayAspectRatio;
  final bool stretch;
  final double brightness;
  final double scanlineStrength;

  const GBADisplay({
    super.key,
    required this.frameBuffer,
    required this.width,
    required this.height,
    this.displayAspectRatio,
    this.stretch = false,
    this.brightness = 1,
    this.scanlineStrength = 0,
  });

  @override
  State<GBADisplay> createState() => _GBADisplayState();
}

class _GBADisplayState extends State<GBADisplay> {
  ui.Image? _image;
  ui.FragmentShader? _shader;
  bool _shaderReady = false;
  bool _decoding = false;
  bool _pending = false;
  final _repaint = _DisplayRepaint();

  @override
  void initState() {
    super.initState();
    widget.frameBuffer.addListener(_onFrameAvailable);
    _loadShader();
  }

  Future<void> _loadShader() async {
    await GbaDisplayShader.ensureLoaded();
    if (!mounted) {
      return;
    }
    setState(() {
      _shader = GbaDisplayShader.createShader();
      _shaderReady = true;
    });
  }

  @override
  void didUpdateWidget(covariant GBADisplay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.frameBuffer != widget.frameBuffer) {
      oldWidget.frameBuffer.removeListener(_onFrameAvailable);
      widget.frameBuffer.addListener(_onFrameAvailable);
    }
    if (oldWidget.brightness != widget.brightness ||
        oldWidget.scanlineStrength != widget.scanlineStrength) {
      _repaint.repaint();
    }
  }

  @override
  void dispose() {
    widget.frameBuffer.removeListener(_onFrameAvailable);
    _shader?.dispose();
    _image?.dispose();
    super.dispose();
  }

  void _onFrameAvailable() {
    if (!mounted) {
      return;
    }
    if (_decoding) {
      _pending = true;
      return;
    }
    _decodeNext();
  }

  void _decodeNext() {
    _decoding = true;
    do {
      _pending = false;
      final image = ui.decodeImageFromPixelsSync(
        widget.frameBuffer.pixels,
        widget.width,
        widget.height,
        ui.PixelFormat.rgba8888,
      );
      if (!mounted) {
        image.dispose();
        _decoding = false;
        return;
      }
      _image?.dispose();
      _image = image;
      _repaint.repaint();
    } while (_pending && mounted);
    _decoding = false;
  }

  @override
  Widget build(BuildContext context) {
    if (!_shaderReady || _shader == null) {
      return const ColoredBox(color: Colors.black);
    }

    final paint = RepaintBoundary(
      child: ListenableBuilder(
        listenable: _repaint,
        builder: (context, child) {
          return CustomPaint(
            painter: _GBAShaderPainter(
              image: _image,
              shader: _shader!,
              brightness: widget.brightness,
              scanlineStrength: widget.scanlineStrength,
            ),
            child: child,
          );
        },
        child: const SizedBox.expand(),
      ),
    );

    if (widget.stretch) {
      return paint;
    }

    return AspectRatio(
      aspectRatio: widget.displayAspectRatio ?? widget.width / widget.height,
      child: paint,
    );
  }
}

class _GBAShaderPainter extends CustomPainter {
  final ui.Image? image;
  final ui.FragmentShader shader;
  final double brightness;
  final double scanlineStrength;

  _GBAShaderPainter({
    required this.image,
    required this.shader,
    required this.brightness,
    required this.scanlineStrength,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (image == null) {
      canvas.drawRect(
        Rect.fromLTWH(0, 0, size.width, size.height),
        Paint()..color = Colors.black,
      );
      return;
    }

    shader
      ..setFloat(0, size.width)
      ..setFloat(1, size.height)
      ..setFloat(2, brightness.clamp(0.5, 1.5))
      ..setFloat(3, scanlineStrength.clamp(0.0, 1.0))
      ..setImageSampler(0, image!);

    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..shader = shader,
    );
  }

  @override
  bool shouldRepaint(covariant _GBAShaderPainter oldDelegate) {
    return oldDelegate.image != image ||
        oldDelegate.brightness != brightness ||
        oldDelegate.scanlineStrength != scanlineStrength;
  }
}
