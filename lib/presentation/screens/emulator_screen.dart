import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../widgets/virtual_gamepad.dart';
import '../../core/libretro/video_renderer.dart';
import '../../core/libretro/emulator_service.dart';
import '../../core/audio/audio_output_service.dart';
import '../../core/settings/app_settings_service.dart';
import '../../core/storage/storage_paths_service.dart';

class EmulatorScreen extends StatefulWidget {
  final String romPath;
  final String? gameId;

  const EmulatorScreen({super.key, required this.romPath, this.gameId});

  @override
  State<EmulatorScreen> createState() => _EmulatorScreenState();
}

class _EmulatorScreenState extends State<EmulatorScreen> {
  // Emulator service
  final EmulatorService _emulatorService = EmulatorService();
  final AudioOutputService _audioOutputService = AudioOutputService();
  final AppSettingsService _settings = AppSettingsService.instance;

  // Frame buffer manager
  late FrameBufferManager _frameBufferManager;

  // State
  bool _isRunning = false;
  bool _isPaused = false;
  bool _isLoading = true;
  bool _isFullscreen = false;
  bool _showFullscreenNavigation = false;
  String? _errorMessage;
  double _fps = 0;
  String _gameName = '';
  String _displayAspectRatio = AppSettingsService.aspectOriginal;
  double _displayBrightness = 1;
  int _speed = 1;

  // FPS overlay refresh timer
  Timer? _fpsTimer;

  // Input state
  final Map<int, bool> _inputState = {};

  @override
  void initState() {
    super.initState();

    // Extract game name from ROM path
    _gameName = widget.romPath.split('/').last;
    final dotIndex = _gameName.lastIndexOf('.');
    if (dotIndex > 0) {
      _gameName = _gameName.substring(0, dotIndex);
    }

    // Initialize frame buffer manager (GBA resolution)
    _frameBufferManager = FrameBufferManager(width: 240, height: 160);
    unawaited(GbaDisplayShader.ensureLoaded());
    _syncSettings();
    _settings.addListener(_syncSettings);

    // Initialize emulator
    _initializeEmulator();
  }

  @override
  void dispose() {
    _fpsTimer?.cancel();
    _restorePortraitMode();
    _settings.removeListener(_syncSettings);
    _audioOutputService.dispose();
    _emulatorService.dispose();
    super.dispose();
  }

  Future<void> _initializeEmulator() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await StoragePathsService.ensureStorageAccess();

      // Check if ROM file exists
      final romFile = File(widget.romPath);
      if (!await romFile.exists()) {
        setState(() {
          _errorMessage = 'ROM文件不存在';
          _isLoading = false;
        });
        return;
      }

      // Get the libretro core path
      // For now, we'll use a placeholder path
      // In production, this should be bundled with the app
      final corePath = await _getCorePath();
      if (corePath == null) {
        setState(() {
          _errorMessage = '找不到模拟器核心文件';
          _isLoading = false;
        });
        return;
      }

      // Initialize emulator core
      print('Initializing emulator core: $corePath');
      final initialized = await _emulatorService.initialize(corePath);
      if (!initialized) {
        setState(() {
          _errorMessage = '初始化模拟器失败';
          _isLoading = false;
        });
        return;
      }
      print('Core initialized successfully');

      // Set up video callback
      _emulatorService.setVideoCallback((framebuffer, width, height, pitch) {
        _frameBufferManager.updateFrom(framebuffer);
      });

      // Set up audio callback
      _emulatorService.setAudioCallback((samples, frames) {
        _audioOutputService.addSamples(samples);
      });

      // Load ROM
      print('Loading ROM: ${widget.romPath}');
      final loaded = await _emulatorService.loadAndStart(
        widget.romPath,
        gameId: widget.gameId,
        startLoop: false,
      );
      if (!loaded) {
        setState(() {
          _errorMessage = '加载ROM失败';
          _isLoading = false;
        });
        return;
      }
      print('ROM loaded successfully');

      await _audioOutputService.initialize(
        sampleRate: _emulatorService.core?.sampleRate ?? 32768,
        fps: _emulatorService.core?.fps ?? 59.73,
      );

      _emulatorService.startGameLoop();

      setState(() {
        _isRunning = true;
        _isPaused = false;
        _isLoading = false;
      });

      // Update FPS periodically
      _fpsTimer?.cancel();
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          setState(() {
            _fps = _emulatorService.currentFps;
          });
        } else {
          timer.cancel();
        }
      });
    } catch (e) {
      setState(() {
        _errorMessage = '初始化失败: $e';
        _isLoading = false;
      });
    }
  }

  Future<String?> _getCorePath() async {
    // On Android, .so files in jniLibs can be loaded by name directly
    if (Platform.isAndroid) {
      return 'libmgba_libretro.so';
    }

    // Try to find the core file in common locations
    final possiblePaths = [
      // macOS
      '${Directory.current.path}/assets/cores/mgba_libretro.dylib',
      '${Directory.current.path}/build/libretro/macos/mgba_libretro.dylib',
      // Linux
      '${Directory.current.path}/assets/cores/mgba_libretro.so',
      '${Directory.current.path}/build/libretro/linux/mgba_libretro.so',
      // iOS (bundled)
      'mgba_libretro.dylib',
    ];

    for (final path in possiblePaths) {
      if (await File(path).exists()) {
        return path;
      }
    }

    return null;
  }

  void _onInputUpdate(Map<int, bool> state) {
    _inputState
      ..clear()
      ..addAll(state);
    _emulatorService.updateInput(state);
  }

  void _togglePause() {
    setState(() {
      _isPaused = !_isPaused;
    });
    if (_isPaused) {
      _emulatorService.pause();
      _audioOutputService.setPaused(true);
    } else {
      _emulatorService.resume();
      _audioOutputService.setPaused(false);
    }
  }

  Future<void> _exitGame() async {
    _emulatorService.pause();
    _emulatorService.setAudioCallback(null);
    await _audioOutputService.stop();
    await _emulatorService.autoSaveAndStop();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  void _cycleSpeed() {
    setState(() {
      _speed = _speed >= 5 ? 1 : _speed + 1;
    });
    _emulatorService.speed = _speed;
    _audioOutputService.setSpeed(_speed.toDouble());
  }

  void _reset() {
    _emulatorService.reset();
  }

  void _syncSettings() {
    if (!mounted) {
      _displayAspectRatio = _settings.displayAspectRatio;
      _displayBrightness = _settings.displayBrightness;
      return;
    }

    setState(() {
      _displayAspectRatio = _settings.displayAspectRatio;
      _displayBrightness = _settings.displayBrightness;
    });
  }

  Future<void> _enterFullscreen() async {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    if (mounted) {
      setState(() {
        _isFullscreen = true;
        _showFullscreenNavigation = false;
      });
    }
  }

  Future<void> _exitFullscreen() async {
    await _restorePortraitMode();

    if (mounted) {
      setState(() {
        _isFullscreen = false;
        _showFullscreenNavigation = false;
      });
    }
  }

  Future<void> _restorePortraitMode() async {
    await SystemChrome.setEnabledSystemUIMode(
      SystemUiMode.manual,
      overlays: SystemUiOverlay.values,
    );
    await SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (!didPop) {
          if (_isFullscreen) {
            _exitFullscreen();
            return;
          }
          _exitGame();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.surfaceContainerLowest,
        body: _isFullscreen ? _buildFullscreenBody() : _buildPortraitBody(),
      ),
    );
  }

  Widget _buildPortraitBody() {
    return SafeArea(
      child: Column(
        children: [
          _buildTopBar(context),
          Expanded(
            child: _isLoading
                ? _buildLoadingScreen()
                : _errorMessage != null
                ? _buildErrorScreen()
                : _buildGameScreen(),
          ),
          if (_isRunning) VirtualGamepad(onInputUpdate: _onInputUpdate),
        ],
      ),
    );
  }

  Widget _buildFullscreenBody() {
    return ColoredBox(
      color: Colors.black,
      child: Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () {
                setState(() {
                  _showFullscreenNavigation = !_showFullscreenNavigation;
                });
              },
              child: _isLoading
                  ? _buildLoadingScreen()
                  : _errorMessage != null
                  ? _buildErrorScreen()
                  : _buildFullscreenGameScreen(),
            ),
          ),
          if (_isRunning)
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: VirtualGamepad(
                overlay: true,
                onInputUpdate: _onInputUpdate,
              ),
            ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: IgnorePointer(
              ignoring: !_showFullscreenNavigation,
              child: AnimatedOpacity(
                duration: const Duration(milliseconds: 180),
                curve: Curves.easeOut,
                opacity: _showFullscreenNavigation ? 1 : 0,
                child: _buildFullscreenTopBar(context),
              ),
            ),
          ),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 8,
            right: MediaQuery.paddingOf(context).right + 10,
            child: _buildTransparentIconButton(
              icon: Icons.fullscreen_exit,
              tooltip: '退出全屏',
              onPressed: _exitFullscreen,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingScreen() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const CircularProgressIndicator(color: AppColors.primary),
          const SizedBox(height: 16),
          Text(
            '正在加载游戏...',
            style: Theme.of(
              context,
            ).textTheme.bodyLarge?.copyWith(color: AppColors.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorScreen() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.error_outline, size: 64, color: AppColors.error),
            const SizedBox(height: 16),
            Text('加载失败', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? '未知错误',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('返回'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopBar(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: AppColors.surfaceContainerLow,
      child: Row(
        children: [
          IconButton(
            icon: const Icon(Icons.arrow_back),
            onPressed: _exitGame,
            color: AppColors.onSurface,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _gameName,
              style: Theme.of(
                context,
              ).textTheme.bodyLarge?.copyWith(fontWeight: FontWeight.w600),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          // Action Buttons
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            onPressed: _togglePause,
            color: AppColors.onSurface,
          ),
          TextButton(
            onPressed: _cycleSpeed,
            child: Text(
              '${_speed}x',
              style: const TextStyle(
                color: AppColors.secondary,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert, color: AppColors.onSurface),
            onSelected: (value) {
              if (value == 'reset') {
                _reset();
              }
            },
            itemBuilder: (context) => [
              const PopupMenuItem(value: 'reset', child: Text('重置游戏')),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFullscreenTopBar(BuildContext context) {
    return SafeArea(
      bottom: false,
      child: Container(
        height: 52,
        padding: const EdgeInsets.only(left: 12, right: 58),
        color: Colors.black.withValues(alpha: 0.46),
        child: Row(
          children: [
            _buildTransparentIconButton(
              icon: Icons.arrow_back,
              tooltip: '返回',
              onPressed: _exitGame,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _gameName,
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: AppColors.onSurface,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            _buildTransparentIconButton(
              icon: _isPaused ? Icons.play_arrow : Icons.pause,
              tooltip: _isPaused ? '继续' : '暂停',
              onPressed: _togglePause,
            ),
            TextButton(
              onPressed: _cycleSpeed,
              child: Text(
                '${_speed}x',
                style: const TextStyle(
                  color: AppColors.secondary,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert, color: AppColors.onSurface),
              color: AppColors.surfaceContainerHigh,
              onSelected: (value) {
                if (value == 'reset') {
                  _reset();
                }
              },
              itemBuilder: (context) => [
                const PopupMenuItem(value: 'reset', child: Text('重置游戏')),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFpsBadge() {
    if (!_isRunning) return const SizedBox.shrink();

    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.38),
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          '${_fps.toStringAsFixed(0)} FPS${_speed > 1 ? ' · ${_speed}x' : ''}',
          style: TextStyle(
            fontSize: 10,
            fontFamily: 'monospace',
            fontWeight: FontWeight.w500,
            color: Colors.white.withValues(alpha: 0.82),
            height: 1.2,
          ),
        ),
      ),
    );
  }

  Widget _buildTransparentIconButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      icon: Icon(icon),
      tooltip: tooltip,
      onPressed: onPressed,
      color: AppColors.onSurface,
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.22),
        foregroundColor: AppColors.onSurface,
        minimumSize: const Size(40, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildGameScreen() {
    final display = _isDisplayStretched
        ? Positioned.fill(child: _buildDisplay())
        : Positioned.fill(child: Center(child: _buildDisplay()));

    return Container(
      margin: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.outlineVariant, width: 2),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.2),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Stack(
          fit: StackFit.expand,
          children: [
            display,
            Positioned(top: 6, right: 6, child: _buildFpsBadge()),
            Positioned(
              right: 8,
              bottom: 8,
              child: _buildTransparentIconButton(
                icon: Icons.fullscreen,
                tooltip: '全屏',
                onPressed: _enterFullscreen,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildFullscreenGameScreen() {
    if (_isDisplayStretched) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildDisplay(),
          Positioned(top: 6, left: 6, child: _buildFpsBadge()),
        ],
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final aspectRatio = _targetAspectRatio;
        final availableWidth = constraints.maxWidth;
        final availableHeight = constraints.maxHeight;
        final availableRatio = availableWidth / availableHeight;

        final displayWidth = availableRatio > aspectRatio
            ? availableHeight * aspectRatio
            : availableWidth;
        final displayHeight = availableRatio > aspectRatio
            ? availableHeight
            : availableWidth / aspectRatio;

        return Center(
          child: SizedBox(
            width: displayWidth,
            height: displayHeight,
            child: Stack(
              fit: StackFit.expand,
              children: [
                _buildDisplay(),
                Positioned(top: 6, left: 6, child: _buildFpsBadge()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDisplay() {
    return GBADisplay(
      frameBuffer: _frameBufferManager,
      width: 240,
      height: 160,
      displayAspectRatio: _targetAspectRatio,
      stretch: _isDisplayStretched,
      brightness: _displayBrightness,
    );
  }

  bool get _isDisplayStretched =>
      _displayAspectRatio == AppSettingsService.aspectStretch;

  double get _targetAspectRatio {
    switch (_displayAspectRatio) {
      case AppSettingsService.aspectFourThree:
        return 4 / 3;
      case AppSettingsService.aspectStretch:
      case AppSettingsService.aspectOriginal:
      default:
        return 240 / 160;
    }
  }
}
