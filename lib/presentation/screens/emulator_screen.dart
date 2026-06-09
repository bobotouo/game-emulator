import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'package:crypto/crypto.dart';
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
import '../../core/network/netplay_room_state.dart';
import '../../core/network/netplay_service.dart';
import '../../core/network/room_info.dart';
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
  static const _gbaAutoRoomPrefix = 'GBAWIFI';

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
  bool _endingSession = false;
  String? _errorMessage;
  final ValueNotifier<double> _fps = ValueNotifier(0);
  final ValueNotifier<int> _remoteLatency = ValueNotifier(0);
  String _gameName = '';
  String _displayAspectRatio = AppSettingsService.aspectOriginal;
  double _displayBrightness = 1;
  int _speed = 1;

  // FPS overlay refresh timer
  Timer? _fpsTimer;
  // Audio drain: reads C ring buffer → SoLoud
  Timer? _audioDrainTimer;
  Timer? _rumblePollTimer;
  Timer? _gbaNetpacketPumpTimer;
  Timer? _gbaAutoHostTimer;
  int _lastRumbleSequence = 0;
  int _lastFrameCount = 0;
  DateTime _lastFpsUpdate = DateTime.now();

  // Input state
  final Map<int, bool> _inputState = {};

  NetplayLockstepRunner? _lockstepRunner;
  NetplayRollbackRunner? _rollbackRunner;
  StreamSubscription<LockstepStartConfig>? _lockstepStartSub;
  StreamSubscription<void>? _gameplayPeerLeftSub;
  StreamSubscription<RoomInfo>? _hostPromotedSub;
  StreamSubscription<int>? _gameSpeedSub;
  StreamSubscription<GbaNetpacketEvent>? _gbaNetpacketSub;
  StreamSubscription<RoomInfo>? _gbaAutoRoomFoundSub;
  StreamSubscription<NetplayRoomState>? _gbaAutoRoomStateSub;

  NetplayService? _gbaAutoNetplayService;
  NetplayService? _gbaAutoDiscoveryService;
  NetplayEmulatorSession? _gbaAutoNetplaySession;
  String? _gbaAutoRomMd5;
  String? _gbaAutoMatchKey;
  String _gbaGpspSerialMode = 'auto';
  int? _gbaNetpacketLocalClientId;
  final Set<int> _gbaNetpacketConnectedClients = {};
  bool _gbaAutoStarted = false;
  bool _gbaAutoConnecting = false;
  bool _gbaNetpacketStarted = false;

  bool get _usesLockstepNetplay =>
      widget.useLockstepNetplay &&
      _isNetplay &&
      (widget.netplaySession?.localPlayerSlot ?? 0) > 0;

  bool get _usesRollbackNetplay => false;

  bool get _usesGbaWirelessNetplay =>
      _coreConfig.system == EmulatorSystem.gba &&
      _effectiveNetplayService != null &&
      _effectiveNetplaySession != null;

  bool get _isNetplayHost => widget.isNetplayHost;

  bool get _isNetplay => widget.netplaySession != null;

  NetplayService? get _effectiveNetplayService =>
      widget.netplayService ?? _gbaAutoNetplayService;

  NetplayEmulatorSession? get _effectiveNetplaySession =>
      widget.netplaySession ?? _gbaAutoNetplaySession;

  bool get _effectiveIsNetplayHost =>
      _effectiveNetplayService?.isHost ?? _isNetplayHost;

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

  String _detectGpspSerialMode() {
    final text = '${widget.romPath} $_gameName'.toLowerCase();
    final compact = text.replaceAll(RegExp(r'[^a-z0-9\u4e00-\u9fff]+'), '');

    final looksLikePokemonGen3 =
        text.contains('pokemon') ||
        text.contains('pokémon') ||
        text.contains('pocket monster') ||
        text.contains('pocket monsters') ||
        text.contains('宝可梦') ||
        text.contains('口袋妖怪') ||
        text.contains('口袋怪兽') ||
        compact.contains('firered') ||
        compact.contains('leafgreen') ||
        text.contains('fire red') ||
        text.contains('leaf green') ||
        text.contains('ruby') ||
        text.contains('sapphire') ||
        text.contains('emerald') ||
        text.contains('红宝石') ||
        text.contains('蓝宝石') ||
        text.contains('绿宝石') ||
        text.contains('火红') ||
        text.contains('叶绿');
    if (looksLikePokemonGen3) {
      return 'mul_poke';
    }

    if (text.contains('advance wars 2') ||
        text.contains('black hole rising') ||
        text.contains('高级战争2')) {
      return 'mul_aw2';
    }
    if (text.contains('advance wars') || text.contains('高级战争')) {
      return 'mul_aw1';
    }

    return 'auto';
  }

  String _gbaAutoSessionKey(String romMd5) {
    return switch (_gbaGpspSerialMode) {
      'mul_poke' => 'gba-link:mul_poke:pokemon-gen3',
      'mul_aw1' => 'gba-link:mul_aw1:advance-wars-1',
      'mul_aw2' => 'gba-link:mul_aw2:advance-wars-2',
      _ => 'gba-wireless:$romMd5',
    };
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
      _hostPromotedSub = widget.netplayService!.onHostPromoted.listen((_) {
        unawaited(_handlePromotedToHostDuringNetplay());
      });
    }
  }

  Future<void> _handleGameplayPeerLeft() async {
    if (!mounted || _endingSession) {
      return;
    }
    _endingSession = true;
    if (widget.isNetplayHost) {
      final state = await _emulatorService.saveState(persistToDisk: false);
      if (state != null && state.isNotEmpty) {
        widget.netplayService?.stashResumeSaveState(state);
      }
    }
    await _endSession();
    widget.netplayService?.markDeferGameExitToRoomScreen();
    if (mounted) {
      Navigator.of(context).pop(false);
    }
  }

  Future<void> _handlePromotedToHostDuringNetplay() async {
    if (!mounted || widget.isNetplayHost || _endingSession) {
      return;
    }
    _endingSession = true;
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
    _gbaNetpacketPumpTimer?.cancel();
    _gbaNetpacketPumpTimer = null;
    _gbaAutoHostTimer?.cancel();
    _gbaAutoHostTimer = null;
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
    _hostPromotedSub?.cancel();
    _hostPromotedSub = null;
    _gameSpeedSub?.cancel();
    _gameSpeedSub = null;
    _gbaNetpacketSub?.cancel();
    _gbaNetpacketSub = null;
    if (_gbaNetpacketStarted) {
      emu_loop.stopGbaNetpacketSession();
      _gbaNetpacketStarted = false;
      _gbaNetpacketLocalClientId = null;
      _gbaNetpacketConnectedClients.clear();
    }
    unawaited(_disposeGbaAutoNetplay());
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
    _hostPromotedSub?.cancel();
    _gameSpeedSub?.cancel();
    _gbaNetpacketSub?.cancel();
    _gbaAutoRoomFoundSub?.cancel();
    _gbaAutoRoomStateSub?.cancel();
    _cancelSessionTimers();
    if (_gbaNetpacketStarted) {
      emu_loop.stopGbaNetpacketSession();
      _gbaNetpacketStarted = false;
      _gbaNetpacketLocalClientId = null;
      _gbaNetpacketConnectedClients.clear();
    }
    _fps.dispose();
    _remoteLatency.dispose();
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
    unawaited(_disposeGbaAutoNetplay());
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

      if (_coreConfig.system == EmulatorSystem.gba) {
        _gbaGpspSerialMode = _detectGpspSerialMode();
        emu_loop.setGpspSerialMode(_gbaGpspSerialMode);
      }

      _inputState.clear();
      emu_loop.clearInputs();

      // Load ROM (core init + load in one locked session).
      final loaded = await _emulatorService.loadAndStart(
        widget.romPath,
        corePath: corePath,
        gameId: widget.gameId,
        coreConfig: _coreConfig,
        startLoop: false,
        restoreSaveState: !_isNetplay,
        runWarmupFrames: !_usesLockstepNetplay,
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

      _inputState.clear();
      emu_loop.clearInputs();

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
      await _audioOutputService.initialize(
        sampleRate: audioRate,
        volume: _coreAudioVolume,
      );

      if (_usesLockstepNetplay) {
        emu_loop.setPresentToTexture(true);
        _emulatorService.core?.switchToNativeCallbacks();
        await _startLockstepNetplay(fps: _emulatorService.core?.fps ?? 60.0);
      } else {
        if (_usesGbaWirelessNetplay) {
          _startGbaWirelessNetplay();
        }
        _emulatorService.startGameLoop();

        // iOS: AVAudioEngine pulls PCM on a real-time thread (no Dart drain).
        if (!_audioOutputService.usesNativeAudio) {
          _audioDrainTimer?.cancel();
          _audioDrainTimer = Timer.periodic(const Duration(milliseconds: 16), (
            _,
          ) {
            final samples = emu_loop.drainAudio(maxSamples: 16384);
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
      if (!_isNetplay && _coreConfig.system == EmulatorSystem.gba) {
        unawaited(_startGbaAutoWirelessNetplay(romFile));
      }
      if (_isNetplay) {
        _applySpeed(_speed);
      }

      // Update FPS periodically
      _fpsTimer?.cancel();
      _lastFrameCount = emu_loop.nativeFrameCount();
      _lastFpsUpdate = DateTime.now();
      _fpsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
        if (mounted) {
          if (_isNetplay) {
            _remoteLatency.value = widget.netplayService?.localLatencyMs ?? 0;
          }
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

    final initialSlots = session.activeSlots;

    if (_usesRollbackNetplay && core.serializeStateSize > 0) {
      _rollbackRunner = NetplayRollbackRunner(
        localSlot: session.localPlayerSlot,
        requiredSlots: initialSlots,
        retroRunPtr: core.retroRunPtr,
        serializePtr: core.bindings.retroSerializePtr,
        restorePtr: core.bindings.retroUnserializePtr,
        stateSize: core.serializeStateSize,
        maxRollbackFrames: netplay.recommendedRollbackFrames(),
        inputDelayFrames: netplay.recommendedRollbackInputDelayFrames(),
        sharedMenuFrames: (fps * 30).round(),
        onSendInput: (frame, slot, buttons) {
          netplay.sendFrameInput(frame: frame, slot: slot, buttons: buttons);
        },
        onFrameAdvanced: _onLockstepFrame,
      );
      netplay.configureRollbackRunner(_rollbackRunner!);
      _rollbackRunner!.setSpeed(_speed);
    } else {
      final menuGuardFrames = switch (_coreConfig.system) {
        EmulatorSystem.nes || EmulatorSystem.arcade => (fps * 30).round(),
        _ => 0,
      };
      final shareMenuControls = _coreConfig.system == EmulatorSystem.nes;
      final edgeFilteredMenuMask = _coreConfig.system == EmulatorSystem.arcade
          ? kNetplayMenuCoinMask | kNetplayMenuStartMask
          : kNetplayMenuStartMask;
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
        inputDelayFrames: netplay.recommendedLockstepInputDelayFrames(),
        sharedMenuFrames: menuGuardFrames,
        shareMenuControls: shareMenuControls,
        edgeFilteredMenuMask: edgeFilteredMenuMask,
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

    final synced = await _syncInitialNetplayState();
    if (!synced) {
      return;
    }
    netplay.signalLockstepReady(fps: fps, requiredSlots: initialSlots);
    if (!widget.isNetplayHost) {
      // Wait for LOCKSTEP_START from host (may arrive after signalLockstepReady).
      for (var attempt = 0; attempt < 20; attempt++) {
        final config = netplay.lastLockstepStartConfig;
        if (config != null) {
          _lockstepRunner?.setRequiredSlots(config.requiredSlots.toSet());
          _rollbackRunner?.setRequiredSlots(config.requiredSlots.toSet());
          _lockstepRunner?.start(
            fps: config.fps,
            startFrame: config.startFrame,
          );
          _rollbackRunner?.start(
            fps: config.fps,
            startFrame: config.startFrame,
          );
          netplay.sendLockstepStartAck();
          return;
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      debugPrint('[Netplay] guest never received LOCKSTEP_START');
    }
  }

  Future<void> _startGbaAutoWirelessNetplay(File romFile) async {
    if (_gbaAutoStarted ||
        _sessionEnded ||
        _isNetplay ||
        !_settings.networkEnabled) {
      return;
    }
    _gbaAutoStarted = true;

    try {
      final digest = await md5.bind(romFile.openRead()).first;
      if (!mounted || _sessionEnded) {
        return;
      }
      _gbaAutoRomMd5 = digest.toString();
      _gbaAutoMatchKey = _gbaAutoSessionKey(_gbaAutoRomMd5!);

      final discovery = NetplayService();
      _gbaAutoDiscoveryService = discovery;
      _gbaAutoRoomFoundSub = discovery.onRoomFound.listen((room) {
        unawaited(_handleGbaAutoRoomFound(room));
      });
      discovery.startDiscovery();

      final jitterMs = 900 + Random().nextInt(900);
      _gbaAutoHostTimer?.cancel();
      _gbaAutoHostTimer = Timer(Duration(milliseconds: jitterMs), () {
        unawaited(_ensureGbaAutoHost());
      });
    } catch (_) {
      _gbaAutoStarted = false;
    }
  }

  bool _isMatchingGbaAutoRoom(RoomInfo room) {
    final matchKey = _gbaAutoMatchKey;
    if (matchKey == null || room.closed || room.gameMd5 != matchKey) {
      return false;
    }
    if (!room.roomId.startsWith(_gbaAutoRoomPrefix)) {
      return false;
    }
    return netplayExtensionFromPath(room.gameCode) == '.gba';
  }

  bool _isOwnGbaAutoRoom(RoomInfo room) {
    final hosted = _gbaAutoNetplayService?.hostedRoom;
    return hosted != null &&
        hosted.roomId == room.roomId &&
        hosted.hostIp == room.hostIp &&
        hosted.port == room.port;
  }

  bool _shouldPreferRemoteGbaRoom(RoomInfo remote) {
    final hosted = _gbaAutoNetplayService?.hostedRoom;
    if (hosted == null) {
      return true;
    }
    if ((hosted.currentPlayers) > 1) {
      return false;
    }
    final localKey = '${hosted.roomId}|${hosted.hostIp}';
    final remoteKey = '${remote.roomId}|${remote.hostIp}';
    return remoteKey.compareTo(localKey) < 0;
  }

  void _watchGbaAutoRoomState(NetplayService service) {
    _gbaAutoRoomStateSub?.cancel();
    _gbaAutoRoomStateSub = service.onRoomStateChanged.listen((_) {
      if (!mounted || service.activeRoom == null) {
        return;
      }
      setState(() {
        _gbaAutoNetplaySession = NetplayEmulatorSession.fromNetplay(
          netplay: service,
          isHost: service.isHost,
        );
      });
      _syncGbaNetpacketConnections();
    });
  }

  void _syncGbaNetpacketConnections() {
    final session = _effectiveNetplaySession;
    final localClientId = _gbaNetpacketLocalClientId;
    if (!_gbaNetpacketStarted || session == null || localClientId == null) {
      return;
    }

    final wanted = <int>{};
    for (var clientId = 0; clientId < session.maxPlayers; clientId++) {
      if (clientId != localClientId) {
        wanted.add(clientId);
      }
    }

    for (final clientId in wanted) {
      if (_gbaNetpacketConnectedClients.add(clientId)) {
        emu_loop.connectGbaNetpacketClient(clientId);
      }
    }

    final stale = _gbaNetpacketConnectedClients.difference(wanted);
    for (final clientId in stale) {
      emu_loop.disconnectGbaNetpacketClient(clientId);
      _gbaNetpacketConnectedClients.remove(clientId);
    }
  }

  Future<void> _handleGbaAutoRoomFound(RoomInfo room) async {
    if (!_isMatchingGbaAutoRoom(room) ||
        _isOwnGbaAutoRoom(room) ||
        _gbaAutoConnecting ||
        _sessionEnded) {
      return;
    }

    final activeService = _gbaAutoNetplayService;
    if (activeService?.isHost == true && !_shouldPreferRemoteGbaRoom(room)) {
      return;
    }
    if (activeService != null && !activeService.isHost) {
      return;
    }

    _gbaAutoConnecting = true;
    _gbaAutoHostTimer?.cancel();
    _gbaAutoHostTimer = null;

    if (activeService?.isHost == true) {
      activeService?.closeRoom();
      await activeService?.dispose();
      if (_gbaAutoNetplayService == activeService) {
        _gbaAutoNetplayService = null;
        _gbaAutoNetplaySession = null;
      }
      if (_gbaNetpacketStarted) {
        emu_loop.stopGbaNetpacketSession();
        _gbaNetpacketStarted = false;
        _gbaNetpacketLocalClientId = null;
        _gbaNetpacketConnectedClients.clear();
      }
    }

    final service = NetplayService();
    _gbaAutoNetplayService = service;
    _watchGbaAutoRoomState(service);

    try {
      final joined = await service.joinRoom(room, playerName: 'Player 2');
      if (!joined) {
        await service.dispose();
        if (_gbaAutoNetplayService == service) {
          _gbaAutoNetplayService = null;
        }
        _gbaAutoConnecting = false;
        unawaited(_ensureGbaAutoHost());
        return;
      }

      if (service.localPlayerSlot <= 0) {
        await service.onPlayerSlotAssigned
            .firstWhere((slot) => slot > 0)
            .timeout(const Duration(seconds: 5));
      }
      if (!mounted || _sessionEnded || service.localPlayerSlot <= 0) {
        return;
      }
      setState(() {
        _gbaAutoNetplaySession = NetplayEmulatorSession.fromNetplay(
          netplay: service,
          isHost: false,
        );
      });
      _startGbaWirelessNetplay();
    } catch (_) {
      await service.dispose();
      if (_gbaAutoNetplayService == service) {
        _gbaAutoNetplayService = null;
        _gbaAutoNetplaySession = null;
      }
      unawaited(_ensureGbaAutoHost());
    } finally {
      _gbaAutoConnecting = false;
    }
  }

  Future<void> _ensureGbaAutoHost() async {
    if (!mounted ||
        _sessionEnded ||
        _gbaAutoConnecting ||
        _gbaAutoNetplayService != null ||
        _gbaAutoMatchKey == null) {
      return;
    }

    final service = NetplayService();
    _gbaAutoNetplayService = service;
    _watchGbaAutoRoomState(service);

    try {
      final hostIp = await service.getLocalIp() ?? '0.0.0.0';
      final roomId =
          '$_gbaAutoRoomPrefix-${DateTime.now().microsecondsSinceEpoch.toRadixString(36).toUpperCase()}';
      final roomTemplate = RoomInfo(
        roomId: roomId,
        roomName: _gameName,
        hostIp: hostIp,
        port: service.port,
        gameCode: widget.romPath.split(Platform.pathSeparator).last,
        gameTitle: _gameName,
        gameMd5: _gbaAutoMatchKey!,
        currentPlayers: 1,
        maxPlayers: 2,
      );
      final hosted = await service.createRoom(
        roomTemplate: roomTemplate,
        playerName: 'Player 1',
      );
      if (!hosted || !mounted || _sessionEnded) {
        await service.dispose();
        if (_gbaAutoNetplayService == service) {
          _gbaAutoNetplayService = null;
        }
        return;
      }
      setState(() {
        _gbaAutoNetplaySession = NetplayEmulatorSession.fromNetplay(
          netplay: service,
          isHost: true,
        );
      });
      _startGbaWirelessNetplay();
    } catch (_) {
      await service.dispose();
      if (_gbaAutoNetplayService == service) {
        _gbaAutoNetplayService = null;
        _gbaAutoNetplaySession = null;
      }
    }
  }

  Future<void> _disposeGbaAutoNetplay() async {
    _gbaAutoHostTimer?.cancel();
    _gbaAutoHostTimer = null;
    await _gbaAutoRoomFoundSub?.cancel();
    _gbaAutoRoomFoundSub = null;
    await _gbaAutoRoomStateSub?.cancel();
    _gbaAutoRoomStateSub = null;

    final discovery = _gbaAutoDiscoveryService;
    _gbaAutoDiscoveryService = null;
    if (discovery != null) {
      await discovery.dispose();
    }

    final service = _gbaAutoNetplayService;
    _gbaAutoNetplayService = null;
    _gbaAutoNetplaySession = null;
    if (service != null) {
      await service.dispose();
    }
  }

  void _startGbaWirelessNetplay() {
    final netplay = _effectiveNetplayService;
    final session = _effectiveNetplaySession;
    if (netplay == null || session == null) {
      return;
    }
    if (_gbaNetpacketStarted) {
      return;
    }
    if (!emu_loop.isGbaNetpacketAvailable()) {
      if (_isNetplay) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('当前 GBA 核心未提供 wireless 联机接口'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final localClientId = _effectiveIsNetplayHost
        ? 0
        : (session.localPlayerSlot - 1).clamp(1, 0xFFFF).toInt();
    emu_loop.startGbaNetpacketSession(localClientId);
    _gbaNetpacketStarted = true;
    _gbaNetpacketLocalClientId = localClientId;
    _gbaNetpacketConnectedClients.clear();
    _syncGbaNetpacketConnections();

    _gbaNetpacketSub?.cancel();
    _gbaNetpacketSub = netplay.onGbaNetpacket.listen((packet) {
      final target = packet.targetClientId;
      final shouldReceive =
          target == emu_loop.gbaNetpacketBroadcast || target == localClientId;
      if (!shouldReceive) {
        return;
      }
      emu_loop.pushGbaNetpacket(
        packet.bytes,
        sourceClientId: packet.sourceClientId,
      );
    });

    _gbaNetpacketPumpTimer?.cancel();
    _gbaNetpacketPumpTimer = Timer.periodic(const Duration(milliseconds: 4), (
      _,
    ) {
      for (var i = 0; i < 64; i++) {
        final packet = emu_loop.readGbaNetpacket();
        if (packet == null) {
          return;
        }
        netplay.sendGbaNetpacket(
          sourceClientId: localClientId,
          targetClientId: packet.targetClientId,
          flags: packet.flags,
          bytes: packet.bytes,
        );
      }
    });
  }

  Future<bool> _syncInitialNetplayState() async {
    final netplay = widget.netplayService;
    if (netplay == null || !_usesLockstepNetplay) {
      return true;
    }

    if (widget.isNetplayHost) {
      final state = await _emulatorService.saveState(persistToDisk: false);
      if (state != null && state.isNotEmpty) {
        await netplay.sendSaveStateToPlayablePeers(state);
        if (netplay.isInternetDirectMode) {
          await Future<void>.delayed(const Duration(milliseconds: 120));
        }
      }
      return true;
    }

    var state = netplay.takeResumeSaveState();
    if (state == null || state.isEmpty) {
      try {
        final timeout = netplay.isInternetDirectMode
            ? const Duration(seconds: 15)
            : const Duration(seconds: 3);
        debugPrint(
          '[Netplay] guest waiting initial save state timeout=$timeout',
        );
        state = await netplay.onSaveStateReceived.first.timeout(timeout);
      } on Object {
        state = null;
      }
    }
    if ((state == null || state.isEmpty) && netplay.isInternetDirectMode) {
      debugPrint('[Netplay] guest initial save state missing');
      if (mounted) {
        setState(() {
          _errorMessage = '互联网联机同步状态超时，请返回房间后重试';
          _isLoading = false;
        });
      }
      return false;
    }
    if (state != null && state.isNotEmpty) {
      debugPrint(
        '[Netplay] guest loading initial save state bytes=${state.length}',
      );
      await _emulatorService.loadState(state);
    }
    return true;
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
    if (_usesLockstepNetplay) {
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
    if (_endingSession) {
      return;
    }
    _endingSession = true;
    if (_isNetplay && widget.netplayService != null) {
      final netplay = widget.netplayService!;
      if (_isNetplayHost && netplay.hasActiveTeammates) {
        final state = await _emulatorService.saveState(persistToDisk: false);
        if (state != null && state.isNotEmpty) {
          netplay.stashResumeSaveState(state);
        }
        netplay.exitGameToTeamLobby();
      } else if (!_isNetplayHost) {
        netplay.exitGameAndLeave();
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
      final next = _speed >= 3 ? 1 : _speed + 1;
      widget.netplayService!.setGameSpeed(next);
      return;
    }
    setState(() {
      _speed = _speed >= 3 ? 1 : _speed + 1;
    });
    _applySpeed(_speed);
  }

  void _applySpeed(int speed) {
    final clamped = speed.clamp(1, 3);
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
          final parts = <String>['${fps.toStringAsFixed(0)} FPS'];
          if (_speed > 1) parts.add('${_speed}x');
          final latency = _remoteLatency.value;
          if (_isNetplay && latency > 0) parts.add('${latency}ms');
          return Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.38),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              parts.join(' · '),
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

  double get _coreAudioVolume =>
      _coreConfig.system == EmulatorSystem.arcade ? 2.0 : 1.5;

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
