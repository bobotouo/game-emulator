import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
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
import '../../core/network/netplay_emulator_session.dart';
import '../../core/network/netplay_input_sync.dart';
import '../../core/network/netplay_lockstep.dart';
import '../../core/network/netplay_rollback.dart';
import '../../core/network/netplay_service.dart';
import '../widgets/netplay_player_bar.dart';

class EmulatorScreen extends StatefulWidget {
  final String romPath;
  final String? gameId;

  /// Library extension (e.g. `.nes`) when [romPath] has no usable suffix.
  final String? romExtension;
  final NetplayEmulatorSession? netplaySession;
  final NetplayService? netplayService;
  final bool isNetplayHost;

  /// FC/NES / arcade host-authoritative lockstep netplay.
  final bool useLockstepNetplay;
  final Uint8List? resumeSaveState;

  const EmulatorScreen({
    super.key,
    required this.romPath,
    this.gameId,
    this.romExtension,
    this.netplaySession,
    this.netplayService,
    this.isNetplayHost = false,
    this.useLockstepNetplay = false,
    this.resumeSaveState,
  });

  @override
  State<EmulatorScreen> createState() => _EmulatorScreenState();
}

class _EmulatorScreenState extends State<EmulatorScreen> {
  // Emulator service
  final EmulatorService _emulatorService = EmulatorService();
  final AudioOutputService _audioOutputService = AudioOutputService.instance;
  final AppSettingsService _settings = AppSettingsService.instance;

  // Frame buffer manager (allocated after first frame to keep push animation smooth).
  FrameBufferManager? _frameBufferManager;
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
  int _lastFrameCount = 0;
  DateTime _lastFpsUpdate = DateTime.now();

  // Input state
  final Map<int, bool> _inputState = {};

  NetplayLockstepRunner? _lockstepRunner;
  NetplayRollbackRunner? _rollbackRunner;
  StreamSubscription<LockstepStartConfig>? _lockstepStartSub;
  StreamSubscription<void>? _gameplayPeerLeftSub;
  StreamSubscription<int>? _gameSpeedSub;

  bool get _usesLockstepNetplay =>
      widget.useLockstepNetplay &&
      _isNetplay &&
      (widget.netplaySession?.localPlayerSlot ?? 0) > 0;

  bool get _usesRollbackNetplay =>
      _usesLockstepNetplay && _coreConfig.system == EmulatorSystem.nes;

  bool get _isNetplayHost => widget.isNetplayHost;

  bool get _isNetplay => widget.netplaySession != null;

  bool get _canAdjustSpeed =>
      !_isNetplay || (widget.netplayService?.isHost ?? _isNetplayHost);

  bool _sessionEnded = false;

  EmulatorCoreConfig? _tryResolveCoreConfig() {
    try {
      return EmulatorCoreResolver.resolve(
        widget.romPath,
        fallbackExtension: widget.romExtension,
      );
    } catch (_) {
      return null;
    }
  }

  String _loadFailureMessage() {
    if (_coreConfig.system == EmulatorSystem.arcade) {
      return '无法加载街机游戏。请确认：\n'
          '· 这是 FBNeo 兼容的完整 ROM set（.zip/.7z）\n'
          '· ROM 版本与机种名称匹配\n'
          '· 所需 BIOS 已放在 system 目录（如 neogeo.zip）';
    }
    return '加载游戏失败';
  }

  @override
  void initState() {
    super.initState();

    // Extract game name from ROM path
    _gameName = widget.romPath.split('/').last;
    final dotIndex = _gameName.lastIndexOf('.');
    if (dotIndex > 0) {
      _gameName = _gameName.substring(0, dotIndex);
    }

    final config = _tryResolveCoreConfig();
    if (config == null) {
      _coreConfig = EmulatorCoreResolver.resolve('fallback.nes');
      _errorMessage = '不支持的 ROM 格式: ${widget.romExtension ?? widget.romPath}';
      _isLoading = false;
      return;
    }
    _coreConfig = config;
    _frameWidth = _coreConfig.defaultWidth;
    _frameHeight = _coreConfig.defaultHeight;
    _syncSettings();
    _settings.addListener(_syncSettings);
    AppSystemUi.apply();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_initializeEmulator());
    });

    if (_isNetplay && widget.netplayService != null) {
      _speed = widget.netplayService!.gameSpeed;
      _gameSpeedSub = widget.netplayService!.onGameSpeedChanged.listen(
        _applySpeed,
      );
      _gameplayPeerLeftSub = widget.netplayService!.onGameplayPeerLeft.listen((
        _,
      ) {
        unawaited(_handleGameplayPeerLeft());
      });
    }
  }

  Future<void> _handleGameplayPeerLeft() async {
    if (!mounted || !widget.isNetplayHost) {
      return;
    }
    final state = await _emulatorService.saveState(persistToDisk: false);
    if (state != null && state.isNotEmpty) {
      widget.netplayService?.stashResumeSaveState(state);
    }
    await _endSession();
    widget.netplayService?.markDeferGameExitToRoomScreen();
    if (mounted) {
      Navigator.of(context).pop(false);
    }
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
    _lockstepRunner?.stop();
    _rollbackRunner?.stop();
    _lockstepStartSub?.cancel();
    _lockstepStartSub = null;
    _gameplayPeerLeftSub?.cancel();
    _gameplayPeerLeftSub = null;
    _gameSpeedSub?.cancel();
    _gameSpeedSub = null;
    _emulatorService.pause();

    if (autoSave && !_isNetplay) {
      await _emulatorService.autoSave();
    }

    _emulatorService.stop();
    emu_loop.flushAudioRing();
    await _audioOutputService.stop();
    await _gameTexture.dispose();
  }

  @override
  void dispose() {
    _gameplayPeerLeftSub?.cancel();
    _gameSpeedSub?.cancel();
    _cancelSessionTimers();
    _fps.dispose();
    _settings.removeListener(_syncSettings);
    if (!_sessionEnded) {
      _emulatorService.pause();
      _emulatorService.stop();
      emu_loop.flushAudioRing();
      unawaited(_audioOutputService.stop());
    }
    _emulatorService.core?.unbindDisplayBuffer();
    _frameBufferManager?.disposeBuffer();
    unawaited(_restorePortraitMode());
    if (!_sessionEnded) {
      unawaited(_gameTexture.dispose());
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

      _frameBufferManager ??= FrameBufferManager(
        width: _frameWidth,
        height: _frameHeight,
        nativeAllocation: _useNativeTexture,
      );

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
        fallbackExtension: widget.romExtension,
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

      // Load ROM (core init + load in one locked session).
      final loaded = await _emulatorService.loadAndStart(
        widget.romPath,
        corePath: corePath,
        gameId: widget.gameId,
        coreConfig: _coreConfig,
        startLoop: false,
        restoreSaveState: !_isNetplay,
      );
      if (!loaded) {
        setState(() {
          _errorMessage = _loadFailureMessage();
          _isLoading = false;
        });
        return;
      }

      final resumeSave = widget.resumeSaveState;
      if (resumeSave != null && resumeSave.isNotEmpty) {
        await _emulatorService.loadState(resumeSave);
      }

      if (_isNetplay && (widget.netplaySession?.maxPlayers ?? 0) >= 2) {
        _emulatorService.core?.configureMultiplayerJoypads();
      }

      _syncFrameDimensionsFromCore();
      final lastFrame = emu_loop.captureLastFrame();
      if (lastFrame != null) {
        _frameWidth = lastFrame.width;
        _frameHeight = lastFrame.height;
        _frameBufferManager?.ensureSize(_frameWidth, _frameHeight);
      }
      _emulatorService.core?.bindDisplayBuffer(_frameBufferManager!.pixels);

      if (_useNativeTexture) {
        await _gameTexture.create(_frameWidth, _frameHeight);
      }

      final coreRate = _emulatorService.core?.sampleRate ?? 0.0;
      final reported = Platform.isIOS
          ? emu_loop.getReportedSampleRate()
          : coreRate;
      emu_loop.flushAudioRing();
      final audioRate = Platform.isIOS
          ? (reported > 0 ? reported : 32768.0).clamp(8000.0, 192000.0)
          : (coreRate > 0 ? coreRate : 32768.0);
      logAudio(
        'emulator_screen init audio: av_info.sampleRate=$coreRate '
        'reported=$reported -> startNativeAudio($audioRate) ring=${emu_loop.audioAvailable()}',
      );
      await _audioOutputService.initialize(sampleRate: audioRate);

      if (_usesLockstepNetplay) {
        emu_loop.setPresentToTexture(true);
        _emulatorService.core?.switchToNativeCallbacks();
        _presentLockstepWarmupFrame();
        await _startLockstepNetplay(fps: _emulatorService.core?.fps ?? 60.0);
      } else {
        _emulatorService.startGameLoop();

        // iOS: AVAudioEngine pulls PCM on a real-time thread (no Dart drain).
        if (!_audioOutputService.usesNativeAudio) {
          _audioDrainTimer?.cancel();
          _audioDrainTimer = Timer.periodic(const Duration(milliseconds: 16), (
            _,
          ) {
            final samples = emu_loop.drainAudio(maxSamples: 8192);
            if (samples != null && samples.isNotEmpty) {
              _audioOutputService.addSamples(samples);
            }
          });
        }
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
      if (_isNetplay) {
        _applySpeed(_speed);
      }

      // Update FPS periodically
      _fpsTimer?.cancel();
      _lastFrameCount = emu_loop.nativeFrameCount();
      _lastFpsUpdate = DateTime.now();
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          if (_usesLockstepNetplay) {
            final now = DateTime.now();
            final elapsed = now.difference(_lastFpsUpdate).inMilliseconds;
            if (elapsed > 0) {
              final fc = emu_loop.nativeFrameCount();
              _fps.value = (fc - _lastFrameCount) * 1000.0 / elapsed;
              _lastFrameCount = fc;
              _lastFpsUpdate = now;
            }
          } else {
            _fps.value = _emulatorService.currentFps;
          }
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

  /// [loadAndStart] warmup runs before [GameTexture] exists; push one frame after texture is ready.
  void _presentLockstepWarmupFrame() {
    final runPtr = _emulatorService.core?.retroRunPtr;
    if (runPtr == null) {
      return;
    }
    emu_loop.advanceEmulatorFrame(runPtr);
    if (_useNativeTexture) {
      return;
    }
    final capture = emu_loop.captureLastFrame();
    if (capture != null) {
      _frameBufferManager?.updateFrom(capture.rgba);
    }
  }

  Future<void> _startLockstepNetplay({required double fps}) async {
    final netplay = widget.netplayService;
    final session = widget.netplaySession;
    final core = _emulatorService.core;
    if (netplay == null || session == null || core == null) {
      setState(() {
        _errorMessage = '联机锁步初始化失败';
        _isLoading = false;
      });
      return;
    }

    final initialSlots = <int>{1};
    for (var slot = 2; slot <= session.maxPlayers; slot++) {
      initialSlots.add(slot);
    }

    if (_usesRollbackNetplay && core.serializeStateSize > 0) {
      _rollbackRunner = NetplayRollbackRunner(
        localSlot: session.localPlayerSlot,
        requiredSlots: initialSlots,
        retroRunPtr: core.retroRunPtr,
        serializePtr: core.bindings.retroSerializePtr,
        restorePtr: core.bindings.retroUnserializePtr,
        stateSize: core.serializeStateSize,
        onSendInput: (frame, slot, buttons) {
          netplay.sendFrameInput(frame: frame, slot: slot, buttons: buttons);
        },
        onFrameAdvanced: _onLockstepFrame,
      );
      netplay.configureRollbackRunner(_rollbackRunner!);
      _rollbackRunner!.setSpeed(_speed);
    } else {
      _lockstepRunner = NetplayLockstepRunner(
        localSlot: session.localPlayerSlot,
        isHost: widget.isNetplayHost,
        requiredSlots: initialSlots,
        retroRunPtr: core.retroRunPtr,
        onSendInput: (frame, slot, buttons) {
          netplay.sendFrameInput(frame: frame, slot: slot, buttons: buttons);
        },
        onFrameComplete: widget.isNetplayHost
            ? (frame, inputs) {
                netplay.publishFrameBundle(frame: frame, inputs: inputs);
              }
            : null,
        onFrameAdvanced: _onLockstepFrame,
      );
      netplay.configureLockstepRunner(_lockstepRunner!);
      _lockstepRunner!.setSpeed(_speed);
    }

    if (session.maxPlayers >= 2) {
      core.configureMultiplayerJoypads();
    }

    _lockstepStartSub = netplay.onLockstepStart.listen((config) {
      _lockstepRunner?.setRequiredSlots(config.requiredSlots.toSet());
      _rollbackRunner?.setRequiredSlots(config.requiredSlots.toSet());
      if (session.maxPlayers >= 2) {
        core.configureMultiplayerJoypads();
      }
    });

    await _syncInitialNetplayState();
    netplay.signalLockstepReady(fps: fps, requiredSlots: initialSlots);
  }

  Future<void> _syncInitialNetplayState() async {
    final netplay = widget.netplayService;
    if (netplay == null || !_usesLockstepNetplay) {
      return;
    }

    if (widget.isNetplayHost) {
      final state = await _emulatorService.saveState(persistToDisk: false);
      if (state != null && state.isNotEmpty) {
        await netplay.sendSaveStateToPlayablePeers(state);
      }
      return;
    }

    var state = netplay.takeResumeSaveState();
    if (state == null || state.isEmpty) {
      try {
        state = await netplay.onSaveStateReceived.first.timeout(
          const Duration(seconds: 3),
        );
      } on Object {
        state = null;
      }
    }
    if (state != null && state.isNotEmpty) {
      await _emulatorService.loadState(state);
    }
  }

  void _onLockstepFrame() {
    if (!_audioOutputService.usesNativeAudio) {
      final samples = emu_loop.drainAudio(maxSamples: 8192);
      if (samples != null && samples.isNotEmpty) {
        _audioOutputService.addSamples(samples);
      }
    }
  }

  void _syncFrameDimensionsFromCore() {
    final w = _emulatorService.baseWidth;
    final h = _emulatorService.baseHeight;
    if (w <= 0 || h <= 0) {
      return;
    }
    _frameBufferManager?.ensureSize(w, h);
    if (_frameWidth != w || _frameHeight != h) {
      setState(() {
        _frameWidth = w;
        _frameHeight = h;
      });
    }
  }

  void _onInputUpdate(Map<int, bool> state) {
    if (_usesRollbackNetplay && _rollbackRunner != null) {
      _rollbackRunner!.updateLocalButtons(inputStateToMask(state));
      return;
    }
    if (_usesLockstepNetplay && _lockstepRunner != null) {
      _lockstepRunner!.updateLocalButtons(inputStateToMask(state));
      return;
    }
    _inputState
      ..clear()
      ..addAll(state);
    final port = _isNetplayHost ? 0 : 0;
    for (final entry in state.entries) {
      emu_loop.setInputBitForPort(port, entry.key, entry.value);
    }
  }

  void _togglePause() {
    if (_usesLockstepNetplay) {
      return;
    }
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
    if (_isNetplay && widget.netplayService != null) {
      final netplay = widget.netplayService!;
      if (_isNetplayHost && netplay.clients.isNotEmpty) {
        final state = await _emulatorService.saveState(persistToDisk: false);
        if (state != null && state.isNotEmpty) {
          netplay.stashResumeSaveState(state);
        }
        netplay.markExitingForReplacement();
      } else if (!_isNetplayHost) {
        netplay.exitGameAndLeaveRoom();
      } else {
        netplay.endGame();
      }
      netplay.markDeferGameExitToRoomScreen();
    }
    await _endSession();
    if (mounted) {
      Navigator.of(context).pop(_isNetplay ? false : null);
    }
  }

  void _cycleSpeed() {
    if (_isNetplay) {
      if (!_canAdjustSpeed || widget.netplayService == null) {
        return;
      }
      final next = _speed >= 5 ? 1 : _speed + 1;
      widget.netplayService!.setGameSpeed(next);
      return;
    }
    setState(() {
      _speed = _speed >= 5 ? 1 : _speed + 1;
    });
    _applySpeed(_speed);
  }

  void _applySpeed(int speed) {
    final clamped = speed.clamp(1, 5);
    if (_speed != clamped) {
      setState(() => _speed = clamped);
    }
    _lockstepRunner?.setSpeed(clamped);
    _rollbackRunner?.setSpeed(clamped);
    _emulatorService.speed = clamped;
    _audioOutputService.setSpeed(clamped.toDouble());
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
        final controlHeight = (constraints.maxHeight * 0.40).clamp(
          220.0,
          340.0,
        );

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
              SizedBox(height: controlHeight, child: _buildGamepad()),
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
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_isRunning && widget.netplaySession != null)
                  Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: NetplayPlayerBar(
                      session: widget.netplaySession!,
                      style: NetplayPlayerBarStyle.fullscreen,
                    ),
                  ),
                _buildTransparentIconButton(
                  icon: Icons.fullscreen_exit,
                  tooltip: '退出全屏',
                  onPressed: _exitFullscreen,
                ),
              ],
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
            if (_canAdjustSpeed)
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
            if (_canAdjustSpeed)
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
              child: _buildGameViewportStack(onFullscreen: _enterFullscreen),
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
              child: _buildGameViewportStack(onFullscreen: _enterFullscreen),
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
        _buildDisplay(),
        if (widget.netplaySession != null)
          Positioned(
            top: 6,
            left: 6,
            child: NetplayPlayerBar(session: widget.netplaySession!),
          ),
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
      child: ClipRRect(borderRadius: BorderRadius.circular(10.5), child: child),
    );
  }

  Widget _buildFullscreenGameScreen() {
    if (_isDisplayStretched) {
      return Stack(
        fit: StackFit.expand,
        children: [
          _buildDisplay(),
          Positioned(
            top: MediaQuery.paddingOf(context).top + 6,
            right: 6,
            child: _buildFpsBadge(),
          ),
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
                Positioned(top: 6, right: 6, child: _buildFpsBadge()),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDisplay() {
    final buffer = _frameBufferManager;
    if (buffer == null) {
      return const ColoredBox(color: Colors.black);
    }
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
      frameBuffer: buffer,
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
        if (_frameHeight > 0) {
          return _frameWidth / _frameHeight;
        }
        return _coreConfig.nativeAspectRatio;
      case AppSettingsService.aspectOriginal:
      default:
        return _emulatorService.coreAspectRatio > 0
            ? _emulatorService.coreAspectRatio
            : _coreConfig.nativeAspectRatio;
    }
  }
}
