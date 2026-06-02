import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'thumbnail_png.dart';
import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import 'emulator_core_resolver.dart';
import 'libretro_core.dart';
import 'libretro_core_registry.dart';
import 'libretro_session_lock.dart';
import 'rom_load_probe.dart';

/// Tuning for thumbnail frame search (background generation only).
class _CaptureProfile {
  const _CaptureProfile({
    required this.maxFrames,
    required this.scoreStartFrame,
    required this.minAverageLuminance,
    required this.minContrast,
    required this.minColorEntropy,
    required this.minEdgeDensity,
    required this.maxDarkPixelRatio,
    this.framesPerStep = 1,
    this.warmupBurstFrames = 0,
    this.extraFramesIfEmpty = 0,
    this.extraFramesPerStep = 1,
    this.topCandidates = 6,
    this.minQualityScore = 24,
  });

  final int maxFrames;
  final int scoreStartFrame;
  final int minAverageLuminance;
  final int minContrast;
  final double minColorEntropy;
  final double minEdgeDensity;
  final double maxDarkPixelRatio;
  final int framesPerStep;
  final int warmupBurstFrames;
  final int extraFramesIfEmpty;
  final int extraFramesPerStep;
  final int topCandidates;

  /// [_pickBestCandidate] must reach this unless using relaxed fallback only.
  final double minQualityScore;
}

/// Generates thumbnail images for ROMs by running the emulator briefly.
class ThumbnailGenerator {
  static Future<void> _encodeTail = Future.value();
  static const _maxThumbnailDim = 400;
  /// Lightweight load check for import (no thumbnail, minimal frames).
  static Future<RomLoadProbe> verifyLoadOnly(String romPath) {
    return LibretroSessionLock.runExclusive(() async {
      return _withCoreSession(romPath, (core, config) async {
        if (!core.loadGame(romPath, config: config)) {
          return RomLoadProbe(
            success: false,
            errorMessage: _loadFailureMessage(config.system),
          );
        }
        _advanceEmulation(core, 40);
        _flushProbeAudio();
        return const RomLoadProbe(success: true);
      });
    });
  }

  /// Full load + best-frame capture (background thumbnail queue).
  static Future<RomLoadProbe> captureThumbnail(
    String romPath,
    String gameId,
  ) {
    return LibretroSessionLock.runExclusive(() async {
      return _withCoreSession(romPath, (core, config) async {
        if (!core.loadGame(romPath, config: config)) {
          return RomLoadProbe(
            success: false,
            errorMessage: _loadFailureMessage(config.system),
          );
        }

        final frame = await _captureBestFrame(core, config.system);
        if (frame == null) {
          return const RomLoadProbe(success: true);
        }

        final thumbnailPath = await _saveThumbnail(
          frame.rgba,
          frame.width,
          frame.height,
          gameId,
        );
        return RomLoadProbe(success: true, thumbnailPath: thumbnailPath);
      });
    });
  }

  /// On-disk cache path: `{documents}/thumbnails/{gameId}.png`.
  static Future<String> thumbnailFilePath(String gameId) async {
    final appDir = await getApplicationDocumentsDirectory();
    return '${appDir.path}/thumbnails/$gameId.png';
  }

  /// Returns cached PNG path if it already exists (no core load).
  static Future<String?> resolveCachedPath(String gameId) async {
    final path = await thumbnailFilePath(gameId);
    if (await File(path).exists()) {
      return path;
    }
    return null;
  }

  /// Generate a thumbnail for a ROM file (skips work when [gameId].png exists).
  static Future<String?> generateThumbnail(
    String romPath,
    String gameId,
  ) async {
    final cached = await resolveCachedPath(gameId);
    if (cached != null) {
      return cached;
    }
    final probe = await captureThumbnail(romPath, gameId);
    return probe.thumbnailPath;
  }

  static Future<RomLoadProbe> _withCoreSession(
    String romPath,
    Future<RomLoadProbe> Function(LibretroCore core, EmulatorCoreConfig config)
        run,
  ) async {
    while (emu_loop.isLoopRunning()) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }

    String? leasedCorePath;
    LibretroCore? core;
    emu_loop.setPresentToTexture(false);
    try {
      final config = EmulatorCoreResolver.resolve(romPath);
      final corePath = await EmulatorCoreResolver.resolveCorePath(romPath);
      if (corePath == null) {
        final hint = Platform.isIOS
            ? '请先执行 ./scripts/build_all_cores.sh ios 并重新安装'
            : '请确认已编译并打包 libretro 核心';
        return RomLoadProbe(
          success: false,
          errorMessage:
              '找不到 ${config.nativeLibraryLabel} 模拟核心。$hint',
        );
      }

      leasedCorePath = corePath;
      try {
        core = LibretroCoreRegistry.acquire(corePath);
      } on StateError {
        return const RomLoadProbe(
          success: false,
          errorMessage: '模拟核心初始化失败',
        );
      }

      if (core.isGameLoaded) {
        core.unloadGame();
      }

      await core.prepareForGame(romPath, config);
      return await run(core, config);
    } catch (e) {
      return RomLoadProbe(
        success: false,
        errorMessage: '验证 ROM 时出错: $e',
      );
    } finally {
      _flushProbeAudio();
      if (leasedCorePath != null) {
        LibretroCoreRegistry.release(leasedCorePath);
      }
      emu_loop.resetLibretroProbeSession();
      emu_loop.setPresentToTexture(true);
    }
  }

  static String _loadFailureMessage(EmulatorSystem system) {
    if (system == EmulatorSystem.arcade) {
      return '无法加载该街机 ROM。请确认 ROM set 完整、版本匹配，'
          '且所需 BIOS 已在 system 目录（如 neogeo.zip）';
    }
    return '无法加载该 ROM 文件';
  }

  static _CaptureProfile _profileFor(EmulatorSystem system) {
    switch (system) {
      case EmulatorSystem.arcade:
        // iOS FBNeo often dupes frames via null video_refresh — score later / warm longer.
        final iosArcade = Platform.isIOS;
        return _CaptureProfile(
          maxFrames: iosArcade ? 320 : 260,
          scoreStartFrame: iosArcade ? 95 : 55,
          minAverageLuminance: 22,
          minContrast: 10,
          minColorEntropy: 2.6,
          minEdgeDensity: 6.0,
          maxDarkPixelRatio: 0.52,
          framesPerStep: 2,
          warmupBurstFrames: iosArcade ? 220 : 160,
          extraFramesIfEmpty: 120,
          extraFramesPerStep: 2,
          topCandidates: 10,
          minQualityScore: 30,
        );
      case EmulatorSystem.nes:
        return const _CaptureProfile(
          maxFrames: 520,
          scoreStartFrame: 65,
          minAverageLuminance: 16,
          minContrast: 7,
          minColorEntropy: 2.1,
          minEdgeDensity: 5.0,
          maxDarkPixelRatio: 0.62,
          framesPerStep: 2,
          warmupBurstFrames: 130,
          extraFramesIfEmpty: 200,
          extraFramesPerStep: 2,
          topCandidates: 8,
          minQualityScore: 26,
        );
      case EmulatorSystem.gba:
      case EmulatorSystem.gb:
        return const _CaptureProfile(
          maxFrames: 520,
          scoreStartFrame: 55,
          minAverageLuminance: 16,
          minContrast: 7,
          minColorEntropy: 2.3,
          minEdgeDensity: 5.2,
          maxDarkPixelRatio: 0.58,
          framesPerStep: 2,
          warmupBurstFrames: 55,
          extraFramesIfEmpty: 180,
          extraFramesPerStep: 2,
          topCandidates: 8,
          minQualityScore: 24,
        );
    }
  }

  static Future<({Uint8List rgba, int width, int height})?> _captureBestFrame(
    LibretroCore core,
    EmulatorSystem system,
  ) async {
    final profile = _profileFor(system);
    if (profile.warmupBurstFrames > 0) {
      _advanceEmulation(core, profile.warmupBurstFrames);
      _flushProbeAudio();
    }
    var result = _runCapturePass(core, profile);
    if (!_meetsQualityBar(result, profile) && profile.extraFramesIfEmpty > 0) {
      final extra = _CaptureProfile(
        maxFrames: profile.extraFramesIfEmpty,
        scoreStartFrame: 20,
        minAverageLuminance: profile.minAverageLuminance - 3,
        minContrast: profile.minContrast - 1,
        minColorEntropy: profile.minColorEntropy * 0.85,
        minEdgeDensity: profile.minEdgeDensity * 0.85,
        maxDarkPixelRatio: math.min(0.78, profile.maxDarkPixelRatio + 0.1),
        framesPerStep: profile.extraFramesPerStep,
        topCandidates: profile.topCandidates,
        minQualityScore: profile.minQualityScore * 0.7,
      );
      final extraResult = _runCapturePass(core, extra);
      if (_scoreOf(extraResult) > _scoreOf(result)) {
        result = extraResult;
      }
    }
    return _frameFromResult(result);
  }

  static void _advanceEmulation(LibretroCore core, int count) {
    if (count <= 0) {
      return;
    }
    // Always run on the Dart isolate; avoid native batch retro_run before deinit.
    for (var i = 0; i < count; i++) {
      core.runFrame();
    }
    _flushProbeAudio();
  }

  static void _flushProbeAudio() {
    while (true) {
      final drained = emu_loop.drainAudio(maxSamples: 8192);
      if (drained == null || drained.isEmpty) {
        break;
      }
    }
    emu_loop.flushAudioRing();
  }

  static bool _meetsQualityBar(
    ({Uint8List rgba, int width, int height, double score})? result,
    _CaptureProfile profile,
  ) {
    return result != null && result.score >= profile.minQualityScore;
  }

  static double _scoreOf(
    ({Uint8List rgba, int width, int height, double score})? result,
  ) =>
      result?.score ?? -1;

  static ({Uint8List rgba, int width, int height})? _frameFromResult(
    ({Uint8List rgba, int width, int height, double score})? result,
  ) {
    if (result == null || result.width == 0 || result.height == 0) {
      return null;
    }
    return (rgba: result.rgba, width: result.width, height: result.height);
  }

  static ({Uint8List rgba, int width, int height, double score})? _runCapturePass(
    LibretroCore core,
    _CaptureProfile profile,
  ) {
    final step = profile.framesPerStep < 1 ? 1 : profile.framesPerStep;
    final candidates = <_FrameCandidate>[];
    _FrameCandidate? bestRelaxed;
    var bestRelaxedScore = -1.0;
    List<int>? previousHist;
    var frameWidth = 0;
    var frameHeight = 0;
    var lastSerial = -1;

    for (var i = 0; i < profile.maxFrames; i++) {
      _advanceEmulation(core, step);
      final serial = emu_loop.lastFrameSerial();
      if (serial == lastSerial) {
        continue;
      }
      lastSerial = serial;
      final capture = emu_loop.captureLastFrame();
      if (capture == null) {
        continue;
      }
      frameWidth = capture.width;
      frameHeight = capture.height;
      if (i < profile.scoreStartFrame) {
        continue;
      }

      final metrics = _analyzeFrame(
        capture.rgba,
        capture.width,
        capture.height,
      );

      final timeline = (i - profile.scoreStartFrame + 1) /
          (profile.maxFrames - profile.scoreStartFrame + 1);

      if (_isAcceptableFallbackFrame(metrics)) {
        final relaxedScore = _informationScore(metrics);
        if (relaxedScore > bestRelaxedScore) {
          bestRelaxedScore = relaxedScore;
          bestRelaxed = _FrameCandidate(
            rgba: Uint8List.fromList(capture.rgba),
            width: capture.width,
            height: capture.height,
            score: relaxedScore,
            frameIndex: i,
            timeline: timeline,
          );
        }
      }

      if (!_isRichFrame(metrics, profile)) {
        previousHist = metrics.luminanceHist;
        continue;
      }

      final sceneChange = _sceneChangeBonus(previousHist, metrics.luminanceHist);
      previousHist = metrics.luminanceHist;
      // Favor mid/late window (past boot, before endless idle screens).
      final timelineBoost = 0.88 + 0.35 * _timelinePreference(timeline);

      final score =
          _informationScore(metrics) + sceneChange * timelineBoost;

      _pushCandidate(
        candidates,
        maxKeep: profile.topCandidates,
        candidate: _FrameCandidate(
          rgba: Uint8List.fromList(capture.rgba),
          width: capture.width,
          height: capture.height,
          score: score,
          frameIndex: i,
          timeline: timeline,
        ),
      );
    }

    final pick = _selectFrame(candidates, bestRelaxed, profile);
    if (pick == null || frameWidth == 0 || frameHeight == 0) {
      return null;
    }
    return (
      rgba: pick.rgba,
      width: pick.width,
      height: pick.height,
      score: pick.score,
    );
  }

  /// Prefer high-scoring strict frames; relaxed pool only when strict quality is low.
  static _FrameCandidate? _selectFrame(
    List<_FrameCandidate> candidates,
    _FrameCandidate? bestRelaxed,
    _CaptureProfile profile,
  ) {
    final strictBest = _pickBestCandidate(candidates);
    if (strictBest != null && strictBest.score >= profile.minQualityScore) {
      return strictBest;
    }
    if (bestRelaxed != null) {
      if (strictBest == null || bestRelaxed.score >= strictBest.score) {
        return bestRelaxed;
      }
    }
    return strictBest ?? bestRelaxed;
  }

  /// Backup pool when strict [_isRichFrame] filters reject a frame.
  static bool _isAcceptableFallbackFrame(_FrameMetrics metrics) {
    return metrics.averageLuminance >= 10 &&
        metrics.contrast >= 4 &&
        metrics.colorEntropy >= 1.4 &&
        metrics.edgeDensity >= 3.0 &&
        metrics.darkPixelRatio <= 0.85;
  }

  static void _pushCandidate(
    List<_FrameCandidate> list, {
    required int maxKeep,
    required _FrameCandidate candidate,
  }) {
    list.add(candidate);
    list.sort((a, b) => b.score.compareTo(a.score));
    if (list.length > maxKeep) {
      list.removeRange(maxKeep, list.length);
    }
  }

  /// Among top-scoring frames, prefer one with high detail in the sweet-spot timeline.
  static _FrameCandidate? _pickBestCandidate(List<_FrameCandidate> candidates) {
    if (candidates.isEmpty) {
      return null;
    }
    candidates.sort((a, b) => b.score.compareTo(a.score));
    final pool = candidates.take(math.min(5, candidates.length)).toList();
    var best = pool.first;
    var bestPick = -1.0;
    for (final c in pool) {
      final pick = c.score * (0.9 + 0.2 * _timelinePreference(c.timeline));
      if (pick > bestPick) {
        bestPick = pick;
        best = c;
      }
    }
    return best;
  }

  /// Peak around 55%–85% of the scoring window (title → gameplay band).
  static double _timelinePreference(double t) {
    final clamped = t.clamp(0.0, 1.0);
    final peak = 0.68;
    final spread = 0.38;
    final d = (clamped - peak).abs();
    return math.exp(-(d * d) / (2 * spread * spread));
  }

  static double _sceneChangeBonus(List<int>? prev, List<int> curr) {
    if (prev == null || prev.length != curr.length) {
      return 0;
    }
    var diff = 0;
    var total = 0;
    for (var i = 0; i < curr.length; i++) {
      diff += (curr[i] - prev[i]).abs();
      total += curr[i];
    }
    if (total <= 0) {
      return 0;
    }
    return (diff / total) * 18.0;
  }

  static bool _isRichFrame(_FrameMetrics metrics, _CaptureProfile profile) {
    return metrics.averageLuminance >= profile.minAverageLuminance &&
        metrics.contrast >= profile.minContrast &&
        metrics.colorEntropy >= profile.minColorEntropy &&
        metrics.edgeDensity >= profile.minEdgeDensity &&
        metrics.darkPixelRatio <= profile.maxDarkPixelRatio;
  }

  static double _informationScore(_FrameMetrics m) {
    return m.contrast * 3.8 +
        m.colorEntropy * 16.0 +
        m.edgeDensity * 6.0 +
        m.saturation * 1.0 +
        m.uniqueColorBins * 2.8 -
        m.darkPixelRatio * 100.0 -
        m.borderBlackRatio * 10.0;
  }

  /// Center-weighted frame analysis: entropy + edges + color spread.
  static _FrameMetrics _analyzeFrame(
    Uint8List rgbaData,
    int width,
    int height,
  ) {
    if (width <= 0 || height <= 0) {
      return _FrameMetrics.empty;
    }

    const stride = 2;
    final marginX = (width * 0.08).round();
    final marginY = (height * 0.08).round();
    final x0 = marginX;
    final x1 = width - marginX;
    final y0 = marginY;
    final y1 = height - marginY;

    final lumHist = List<int>.filled(32, 0);
    final colorHist = List<int>.filled(64, 0);

    var luminanceSum = 0.0;
    var luminanceSquares = 0.0;
    var saturationSum = 0.0;
    var edgeSum = 0.0;
    var darkCount = 0;
    var borderCount = 0;
    var borderDark = 0;
    var count = 0;

    double lumAt(int x, int y) {
      final o = (y * width + x) * 4;
      final r = rgbaData[o];
      final g = rgbaData[o + 1];
      final b = rgbaData[o + 2];
      return (r + g + b) / 3.0;
    }

    for (var y = 0; y < height; y += stride) {
      for (var x = 0; x < width; x += stride) {
        final o = (y * width + x) * 4;
        final r = rgbaData[o];
        final g = rgbaData[o + 1];
        final b = rgbaData[o + 2];
        final lum = (r + g + b) / 3.0;
        final maxC = math.max(r, math.max(g, b));
        final minC = math.min(r, math.min(g, b));

        final onBorder =
            x < marginX || x >= width - marginX || y < marginY || y >= height - marginY;
        if (onBorder) {
          borderCount++;
          if (lum < 28) {
            borderDark++;
          }
        }

        final inCenter = x >= x0 && x < x1 && y >= y0 && y < y1;
        if (!inCenter) {
          continue;
        }

        luminanceSum += lum;
        luminanceSquares += lum * lum;
        saturationSum += maxC - minC;
        if (lum < 24) {
          darkCount++;
        }

        final lumBin = (lum / 255.0 * 31).floor().clamp(0, 31);
        lumHist[lumBin]++;
        final colorBin =
            ((r >> 6) << 4) | ((g >> 6) << 2) | (b >> 6);
        colorHist[colorBin.clamp(0, 63)]++;

        if (x + stride < x1 && y + stride < y1) {
          final lumR = lumAt(x + stride, y);
          final lumD = lumAt(x, y + stride);
          edgeSum += (lum - lumR).abs() + (lum - lumD).abs();
        }

        count++;
      }
    }

    if (count == 0) {
      return _FrameMetrics.empty;
    }

    final average = luminanceSum / count;
    final variance = math.max(
      0.0,
      luminanceSquares / count - average * average,
    );
    final contrast = math.sqrt(variance);
    final saturation = saturationSum / count;
    final edgeDensity = edgeSum / count;
    final darkPixelRatio = darkCount / count;
    final borderBlackRatio =
        borderCount > 0 ? borderDark / borderCount : 0.0;

    var colorEntropy = 0.0;
    var uniqueColorBins = 0;
    for (final n in colorHist) {
      if (n == 0) {
        continue;
      }
      uniqueColorBins++;
      final p = n / count;
      colorEntropy -= p * math.log(p) / math.ln2;
    }

    return _FrameMetrics(
      averageLuminance: average,
      contrast: contrast,
      saturation: saturation,
      colorEntropy: colorEntropy,
      edgeDensity: edgeDensity,
      darkPixelRatio: darkPixelRatio,
      borderBlackRatio: borderBlackRatio,
      uniqueColorBins: uniqueColorBins,
      luminanceHist: lumHist,
    );
  }

  static ({Uint8List rgba, int width, int height}) _downscaleForThumbnail(
    Uint8List rgba,
    int width,
    int height,
  ) {
    if (width <= 0 || height <= 0) {
      return (rgba: rgba, width: width, height: height);
    }
    final longest = math.max(width, height);
    if (longest <= _maxThumbnailDim) {
      return (rgba: rgba, width: width, height: height);
    }

    final scale = _maxThumbnailDim / longest;
    final outW = math.max(1, (width * scale).round());
    final outH = math.max(1, (height * scale).round());
    final out = Uint8List(outW * outH * 4);

    for (var y = 0; y < outH; y++) {
      final srcYf = (y + 0.5) * height / outH - 0.5;
      for (var x = 0; x < outW; x++) {
        final srcXf = (x + 0.5) * width / outW - 0.5;
        final x0 = srcXf.floor().clamp(0, width - 1);
        final y0 = srcYf.floor().clamp(0, height - 1);
        final x1 = (x0 + 1).clamp(0, width - 1);
        final y1 = (y0 + 1).clamp(0, height - 1);
        final tx = srcXf - x0;
        final ty = srcYf - y0;
        final dst = (y * outW + x) * 4;
        for (var c = 0; c < 4; c++) {
          final p00 = rgba[(y0 * width + x0) * 4 + c];
          final p10 = rgba[(y0 * width + x1) * 4 + c];
          final p01 = rgba[(y1 * width + x0) * 4 + c];
          final p11 = rgba[(y1 * width + x1) * 4 + c];
          final top = p00 + (p10 - p00) * tx;
          final bottom = p01 + (p11 - p01) * tx;
          out[dst + c] = (top + (bottom - top) * ty).round().clamp(0, 255);
        }
        out[dst + 3] = 255;
      }
    }
    return (rgba: out, width: outW, height: outH);
  }

  static Future<String?> _saveThumbnail(
    Uint8List rgbaData,
    int width,
    int height,
    String gameId,
  ) async {
    final completer = Completer<String?>();
    _encodeTail = _encodeTail.then((_) async {
      try {
        completer.complete(
          await _saveThumbnailImpl(rgbaData, width, height, gameId),
        );
      } catch (e) {
        print('Error saving thumbnail: $e');
        if (!completer.isCompleted) {
          completer.complete(null);
        }
      }
    });
    return completer.future;
  }

  static Future<String?> _saveThumbnailImpl(
    Uint8List rgbaData,
    int width,
    int height,
    String gameId,
  ) async {
    final scaled = _downscaleForThumbnail(rgbaData, width, height);
    final pngBytes = await Isolate.run(
      () => encodeRgbaToPng(scaled.rgba, scaled.width, scaled.height),
    );
    if (pngBytes == null || pngBytes.isEmpty) {
      return null;
    }

    final appDir = await getApplicationDocumentsDirectory();
    final thumbnailDir = Directory('${appDir.path}/thumbnails');
    if (!await thumbnailDir.exists()) {
      await thumbnailDir.create(recursive: true);
    }

    final thumbnailPath = '${thumbnailDir.path}/$gameId.png';
    final existing = File(thumbnailPath);
    if (await existing.exists()) {
      return thumbnailPath;
    }

    await File(thumbnailPath).writeAsBytes(pngBytes, flush: true);
    return thumbnailPath;
  }

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

class _FrameCandidate {
  const _FrameCandidate({
    required this.rgba,
    required this.width,
    required this.height,
    required this.score,
    required this.frameIndex,
    required this.timeline,
  });

  final Uint8List rgba;
  final int width;
  final int height;
  final double score;
  final int frameIndex;
  final double timeline;
}

class _FrameMetrics {
  const _FrameMetrics({
    required this.averageLuminance,
    required this.contrast,
    required this.saturation,
    required this.colorEntropy,
    required this.edgeDensity,
    required this.darkPixelRatio,
    required this.borderBlackRatio,
    required this.uniqueColorBins,
    required this.luminanceHist,
  });

  static final empty = _FrameMetrics(
    averageLuminance: 0,
    contrast: 0,
    saturation: 0,
    colorEntropy: 0,
    edgeDensity: 0,
    darkPixelRatio: 1,
    borderBlackRatio: 1,
    uniqueColorBins: 0,
    luminanceHist: List<int>.filled(32, 0),
  );

  final double averageLuminance;
  final double contrast;
  final double saturation;
  final double colorEntropy;
  final double edgeDensity;
  final double darkPixelRatio;
  final double borderBlackRatio;
  final int uniqueColorBins;
  final List<int> luminanceHist;
}
