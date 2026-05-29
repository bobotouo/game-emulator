import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';
import '../theme/system_ui.dart';
import '../gamepad/gamepad_layout.dart';
import '../gamepad/gamepad_skin.dart';
import '../widgets/virtual_gamepad.dart';
import '../../core/libretro/emulator_core_resolver.dart';
import '../../core/game_texture/game_texture_controller.dart';
import '../../core/libretro/video_renderer.dart';
import '../../core/libretro/emulator_service.dart';
import '../../core/audio/audio_debug.dart';
import '../../core/audio/audio_output_service.dart';
import '../../core/settings/app_settings_service.dart';
import '../../core/storage/storage_paths_service.dart';
import '../../core/haptics/haptic_service.dart';
import '../../core/emulator_loop/emulator_loop_ffi.dart' as emu_loop;

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
  final AudioOutputService _audioOutputService = AudioOutputService.instance;
  final AppSettingsService _settings = AppSettingsService.instance;

  // Frame buffer manager
  late FrameBufferManager _frameBufferManager;
  final GameTextureController _gameTexture = GameTextureController();
  final bool _useNativeTexture = GameTextureController.isSupported;
  late EmulatorCoreConfig _coreConfig;
  int _frameWidth = 240;
  int _frameHeight = 160;

  // State
  bool _isRunning = false;
  bool _isPaused = false;
  bool _isLoading = true;
  bool _isFullscreen = false;
  bool _showFullscreenNavigation = false;
  String? _errorMessage;
  final ValueNotifier<double> _fps = ValueNotifier(0);
  String _gameName = '';
  String _displayAspectRatio = AppSettingsService.aspectOriginal;
  double _displayBrightness = 1;
  int _speed = 1;

  // FPS overlay refresh timer
  Timer? _fpsTimer;
  // Audio drain: reads C ring buffer → SoLoud
  Timer? _audioDrainTimer;
  Timer? _rumblePollTimer;
  int _lastRumbleSequence = 0;

  // Input state
  final Map<int, bool> _inputState = {};

  bool _sessionEnded = false;

  @override
  void initState() {
    super.initState();

    // Extract game name from ROM path
    _gameName = widget.romPath.split('/').last;
    final dotIndex = _gameName.lastIndexOf('.');
    if (dotIndex > 0) {
      _gameName = _gameName.substring(0, dotIndex);
    }

    _coreConfig = EmulatorCoreResolver.resolve(widget.romPath);
    _frameWidth = _coreConfig.defaultWidth;
    _frameHeight = _coreConfig.defaultHeight;
    _frameBufferManager = FrameBufferManager(
      width: _frameWidth,
      height: _frameHeight,
      nativeAllocation: _useNativeTexture,
    );
    _syncSettings();
    _settings.addListener(_syncSettings);
    AppSystemUi.apply();

    // Initialize emulator
    _initializeEmulator();
  }

  void _cancelSessionTimers() {
    _fpsTimer?.cancel();
    _fpsTimer = null;
    _audioDrainTimer?.cancel();
    _audioDrainTimer = null;
    _rumblePollTimer?.cancel();
    _rumblePollTimer = null;
  }

  /// Stop timers → emulation → audio (order matters for SoLoud / AAudio).
  Future<void> _endSession({bool autoSave = true}) async {
    if (_sessionEnded) return;
    _sessionEnded = true;

    _cancelSessionTimers();
    _emulatorService.pause();

    if (autoSave) {
      await _emulatorService.autoSave();
    }

    _emulatorService.stop();
    emu_loop.flushAudioRing();
    await _audioOutputService.stop();
  }

  @override
  void dispose() {
    _cancelSessionTimers();
    _fps.dispose();
    _emulatorService.core?.unbindDisplayBuffer();
    _frameBufferManager.disposeBuffer();
    unawaited(_gameTexture.dispose());
    unawaited(_restorePortraitMode());
    _settings.removeListener(_syncSettings);
    if (!_sessionEnded) {
      _emulatorService.pause();
      _emulatorService.stop();
      emu_loop.flushAudioRing();
      unawaited(_audioOutputService.stop());
    }
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

      final corePath = await EmulatorCoreResolver.resolveCorePath(
        widget.romPath,
      );
      if (corePath == null) {
        setState(() {
          final hint = Platform.isIOS
              ? '请先执行 ./scripts/build_all_cores.sh ios 并重新安装 App'
              : '请确认已编译并打包 libretro 核心';
          _errorMessage =
              '找不到 ${_coreConfig.system.label} 模拟器核心（${_coreConfig.nativeLibraryLabel}）。$hint';
          _isLoading = false;
        });
        return;
      }

      // Initialize emulator core
      print('Initializing ${_coreConfig.system.label} core: $corePath');
      final initialized = await _emulatorService.initialize(corePath);
      if (!initialized) {
        setState(() {
          _errorMessage = '初始化模拟器失败';
          _isLoading = false;
        });
        return;
      }
      print('Core initialized successfully');

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

      _syncFrameDimensionsFromCore();
      _emulatorService.core?.bindDisplayBuffer(_frameBufferManager.pixels);

      if (_useNativeTexture) {
        await _gameTexture.create(_frameWidth, _frameHeight);
      }

      final coreRate = _emulatorService.core?.sampleRate ?? 0.0;
      final reported = Platform.isIOS ? emu_loop.getReportedSampleRate() : coreRate;
      emu_loop.flushAudioRing();
      final audioRate = Platform.isIOS
          ? (reported > 0 ? reported : 32768.0).clamp(8000.0, 192000.0)
          : (coreRate > 0 ? coreRate : 32768.0);
      logAudio(
        'emulator_screen init audio: av_info.sampleRate=$coreRate '
        'reported=$reported -> startNativeAudio($audioRate) ring=${emu_loop.audioAvailable()}',
      );
      await _audioOutputService.initialize(sampleRate: audioRate);

      _emulatorService.startGameLoop();

      // iOS: AVAudioEngine pulls PCM on a real-time thread (no Dart drain).
      if (!_audioOutputService.usesNativeAudio) {
        _audioDrainTimer?.cancel();
        _audioDrainTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
          final samples = emu_loop.drainAudio(maxSamples: 8192);
          if (samples != null && samples.isNotEmpty) {
            _audioOutputService.addSamples(samples);
          }
        });
      }

      _lastRumbleSequence = emu_loop.rumbleSequence();
      _rumblePollTimer?.cancel();
      _rumblePollTimer = Timer.periodic(const Duration(milliseconds: 16), (_) {
        final sequence = emu_loop.rumbleSequence();
        if (sequence == _lastRumbleSequence) {
          return;
        }
        _lastRumbleSequence = sequence;

        final strong = emu_loop.rumbleStrong();
        final weak = emu_loop.rumbleWeak();
        final strength = strong >= weak ? strong : weak;
        HapticService.instance.gameRumble(strength, strong: strong >= weak);
      });

      setState(() {
        _isRunning = true;
        _isPaused = false;
        _isLoading = false;
      });

      // Update FPS periodically
      _fpsTimer?.cancel();
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          _fps.value = _emulatorService.currentFps;
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

  void _syncFrameDimensionsFromCore() {
    final w = _emulatorService.baseWidth;
    final h = _emulatorService.baseHeight;
    if (w <= 0 || h <= 0) {
      return;
    }
    _frameBufferManager.ensureSize(w, h);
    if (_frameWidth != w || _frameHeight != h) {
      setState(() {
        _frameWidth = w;
        _frameHeight = h;
      });
    }
  }

  void _onInputUpdate(Map<int, bool> state) {
    _inputState
      ..clear()
      ..addAll(state);
    // Update the C-side atomic input bitmask directly (avoids Dart map lookup
    // during retro_run on the native thread).
    for (final entry in state.entries) {
      emu_loop.setInputBit(entry.key, entry.value);
    }
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
    await _endSession();
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
    AppSystemUi.apply();
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
        backgroundColor: AppColors.background,
        body: _isFullscreen ? _buildFullscreenBody() : _buildPortraitBody(),
      ),
    );
  }

  GamepadLayout get _gamepadLayout {
    final id = _settings.gamepadLayoutId;
    if (id.isNotEmpty) {
      return GamepadLayouts.byId(id);
    }
    return GamepadLayouts.forSystem(_coreConfig.system);
  }

  GamepadSkin get _gamepadSkin => GamepadSkins.byId(_settings.gamepadSkinId);

  Widget _buildGamepad({bool overlay = false, bool landscape = false}) {
    return VirtualGamepad(
      overlay: overlay,
      skin: _gamepadSkin,
      layout: _gamepadLayout,
      onInputUpdate: _onInputUpdate,
    );
  }

  Widget _buildPortraitBody() {
    final topInset = MediaQuery.paddingOf(context).top;

    return LayoutBuilder(
      builder: (context, constraints) {
        final controlHeight = (constraints.maxHeight * 0.40).clamp(220.0, 340.0);

        return Column(
          children: [
            _buildTopBar(context, topInset: topInset),
            Expanded(
              child: _isLoading
                  ? _buildLoadingScreen()
                  : _errorMessage != null
                  ? _buildErrorScreen()
                  : _buildPortraitGameArea(),
            ),
            if (_isRunning)
              SizedBox(
                height: controlHeight,
                child: _buildGamepad(),
              ),
          ],
        );
      },
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
              child: _buildGamepad(overlay: true, landscape: true),
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

  Widget _buildTopBar(BuildContext context, {required double topInset}) {
    return Padding(
      padding: EdgeInsets.only(top: topInset),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        color: Colors.transparent,
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
      child: ValueListenableBuilder<double>(
        valueListenable: _fps,
        builder: (context, fps, _) {
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              '${fps.toStringAsFixed(0)} FPS${_speed > 1 ? ' · ${_speed}x' : ''}',
              style: TextStyle(
                fontSize: 10,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
                color: Colors.white.withValues(alpha: 0.82),
                height: 1.2,
              ),
            ),
          );
        },
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

  Widget _buildPortraitGameArea() {
    return LayoutBuilder(
      builder: (context, constraints) {
        const horizontalPad = 4.0;
        final maxWidth = constraints.maxWidth - horizontalPad * 2;
        final maxHeight = constraints.maxHeight;

        if (_isDisplayStretched) {
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: horizontalPad),
            child: _buildGameFrame(
              child: _buildGameViewportStack(
                onFullscreen: _enterFullscreen,
              ),
            ),
          );
        }

        final aspectRatio = _targetAspectRatio;
        final availableRatio = maxWidth / maxHeight;
        final displayWidth = availableRatio > aspectRatio
            ? maxHeight * aspectRatio
            : maxWidth;
        final displayHeight = availableRatio > aspectRatio
            ? maxHeight
            : maxWidth / aspectRatio;

        return Center(
          child: SizedBox(
            width: displayWidth,
            height: displayHeight,
            child: _buildGameFrame(
              child: _buildGameViewportStack(
                onFullscreen: _enterFullscreen,
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildGameViewportStack({VoidCallback? onFullscreen}) {
    return Stack(
      fit: StackFit.expand,
      children: [
        const ColoredBox(color: Colors.black),
        _buildDisplay(),
        Positioned(top: 6, right: 6, child: _buildFpsBadge()),
        if (onFullscreen != null)
          Positioned(
            right: 8,
            bottom: 8,
            child: _buildTransparentIconButton(
              icon: Icons.fullscreen,
              tooltip: '全屏',
              onPressed: onFullscreen,
            ),
          ),
      ],
    );
  }

  Widget _buildGameFrame({required Widget child}) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: AppColors.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.outlineVariant, width: 1.5),
        boxShadow: [
          BoxShadow(
            color: AppColors.primary.withValues(alpha: 0.16),
            blurRadius: 14,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10.5),
        child: child,
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
    if (_useNativeTexture && _gameTexture.isReady) {
      return NativeGameDisplay(
        texture: _gameTexture,
        width: _frameWidth,
        height: _frameHeight,
        displayAspectRatio: _targetAspectRatio,
        stretch: _isDisplayStretched,
        brightness: _displayBrightness,
      );
    }
    return GBADisplay(
      frameBuffer: _frameBufferManager,
      width: _frameWidth,
      height: _frameHeight,
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
        return _frameWidth / _frameHeight;
    }
  }
}
