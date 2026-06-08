import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../core/network/internet_direct_code.dart';
import '../../core/network/lan_service.dart';
import '../../core/network/netplay_protocol.dart';
import '../../core/settings/app_settings_service.dart';
import '../../features/game_library/game_library_service.dart';
import '../theme/app_theme.dart';
import '../widgets/add_game_loading.dart';
import '../widgets/game_card.dart';
import 'netplay_emulator_screen.dart';

enum NetplayRoomMode { lan, internet }

/// Unified room page: host configures name + game, waits for players, starts game.
/// Guests see the same layout without game selection.
class RoomScreen extends StatefulWidget {
  const RoomScreen({
    super.key,
    required this.netplayService,
    this.gameLibrary,
    this.isHost = true,
    this.roomInfo,
    this.hasLocalRom = true,
  });

  final NetplayService netplayService;
  final GameLibraryService? gameLibrary;
  final bool isHost;
  final RoomInfo? roomInfo;
  final bool hasLocalRom;

  @override
  State<RoomScreen> createState() => _RoomScreenState();
}

class _RoomScreenState extends State<RoomScreen> {
  late final GameLibraryService _gameLibrary =
      widget.gameLibrary ?? GameLibraryService();
  final _roomNameController = TextEditingController();
  PageController? _pageController;
  final _players = <PlayerInfo>[];

  List<GameRom> _games = [];
  int _selectedGameIndex = 0;
  int _selectedMaxPlayers = 2;
  bool _loading = true;
  bool _creating = false;
  bool _roomLive = false;
  bool _leaving = false;
  bool _promotedToHost = false;

  bool get _isRoomHost => widget.isHost || _promotedToHost;

  bool _isReady = false;
  bool _hasLocalRom = true;
  bool _awaitingRomDecision = false;
  NetplayRoomMode _roomMode = NetplayRoomMode.lan;
  InternetDirectCode? _internetDirectCode;
  double _romProgress = 0;
  String? _romStatusText;

  GameRom? _localGame;

  StreamSubscription<PlayerInfo>? _playerJoinedSub;
  StreamSubscription<PlayerInfo>? _playerUpdatedSub;
  StreamSubscription<String>? _playerLeftSub;
  StreamSubscription<NetplayMessage>? _messageSub;
  StreamSubscription<String>? _romRequestSub;
  StreamSubscription<RomTransferProgress>? _romProgressSub;
  StreamSubscription<NetplayStartGameEvent>? _startGameSub;
  StreamSubscription<bool>? _connectionSub;
  StreamSubscription<List<GameRom>>? _gamesSub;
  StreamSubscription<NetplayRoomState>? _roomStateSub;
  StreamSubscription<RoomInfo>? _hostPromotedSub;

  RoomInfo? get _room =>
      widget.netplayService.hostedRoom ??
      widget.netplayService.joinedRoom ??
      widget.roomInfo;

  List<GameRom> _roomCompatibleGames(List<GameRom> games) {
    return games
        .where((game) => isHostAuthoritativeNetplayExtension(game.extension))
        .toList();
  }

  void _setRoomGames(List<GameRom> games) {
    _games = _roomCompatibleGames(games);
    if (_selectedGameIndex >= _games.length) {
      _selectedGameIndex = _games.isEmpty ? 0 : _games.length - 1;
    }
  }

  GameRom? get _selectedGame {
    if (!_isRoomHost) {
      return _localGame;
    }
    if (_games.isEmpty) {
      return null;
    }
    final index = _selectedGameIndex.clamp(0, _games.length - 1);
    return _games[index];
  }

  int get _maxSeats {
    if (_room != null) {
      return _room!.maxPlayers.clamp(2, 4);
    }
    return _selectedMaxPlayers.clamp(2, 4);
  }

  bool get _hasTeammate => _playablePlayers.any((player) => !player.isHost);

  bool get _teammateReady =>
      _playablePlayers.any((player) => !player.isHost && player.isReady);

  bool get _canStartGame => _hasTeammate && _teammateReady;

  List<PlayerInfo> get _effectivePlayers =>
      widget.netplayService.roomState?.players ?? _players;

  List<PlayerInfo> get _playablePlayers {
    final sorted = List<PlayerInfo>.from(_effectivePlayers)
      ..sort((a, b) => a.slot.compareTo(b.slot));
    return sorted;
  }

  PlayerInfo? _playerAtSlot(int slot) {
    for (final player in _effectivePlayers) {
      if (player.slot == slot) {
        return _localizePlayer(player);
      }
    }
    return null;
  }

  PlayerInfo _localizePlayer(PlayerInfo player) {
    if (_isRoomHost && player.isHost) {
      return player.copyWith(name: '我');
    }
    if (!_isRoomHost && player.id == widget.netplayService.localPlayerId) {
      return player.copyWith(name: '我');
    }
    return player;
  }

  @override
  void initState() {
    super.initState();
    _hasLocalRom = widget.hasLocalRom;
    _roomLive = !widget.isHost;
    unawaited(_bootstrap());
  }

  Future<void> _bootstrap() async {
    _gamesSub = _gameLibrary.gamesStream.listen((games) {
      if (!mounted) {
        return;
      }
      setState(() => _setRoomGames(games));
    });

    if (_gameLibrary.games.isEmpty) {
      await _gameLibrary.init(refreshThumbnails: false);
    } else {
      unawaited(_gameLibrary.init(refreshThumbnails: false));
    }
    _setRoomGames(_gameLibrary.games);

    if (widget.isHost) {
      final defaultName = await NetplayService.defaultRoomName();
      _roomNameController.text = defaultName;
      _initHostPlayers();
    } else {
      final room = _room;
      if (room != null) {
        _localGame = _gameLibrary.findGameByMd5(room.gameMd5);
        _hasLocalRom = await _gameLibrary.hasLocalRom(room.gameMd5);
      }
      _internetDirectCode = widget.netplayService.internetDirectInviteCode;
      _initGuestPlayers();
      _attachNetplayListeners();
      widget.netplayService.enterLobby();

      if (!_hasLocalRom) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          unawaited(_promptRomTransfer());
        });
      } else {
        widget.netplayService.sendReady(true);
        _isReady = true;
      }
    }

    if (mounted) {
      setState(() => _loading = false);
    }
  }

  @override
  void dispose() {
    _roomNameController.dispose();
    _pageController?.dispose();
    _playerJoinedSub?.cancel();
    _playerUpdatedSub?.cancel();
    _playerLeftSub?.cancel();
    _messageSub?.cancel();
    _romRequestSub?.cancel();
    _romProgressSub?.cancel();
    _startGameSub?.cancel();
    _connectionSub?.cancel();
    _gamesSub?.cancel();
    _roomStateSub?.cancel();
    _hostPromotedSub?.cancel();
    super.dispose();
  }

  void _initHostPlayers() {
    _players
      ..clear()
      ..add(
        const PlayerInfo(
          id: 'host',
          name: '房主',
          isHost: true,
          isReady: true,
          slot: 1,
        ),
      );
  }

  void _initGuestPlayers() {
    _players
      ..clear()
      ..add(const PlayerInfo(id: 'self', name: '我', isHost: false));
  }

  void _attachNetplayListeners() {
    _playerJoinedSub?.cancel();
    _playerUpdatedSub?.cancel();
    _playerLeftSub?.cancel();
    _messageSub?.cancel();
    _romRequestSub?.cancel();
    _romProgressSub?.cancel();
    _startGameSub?.cancel();
    _connectionSub?.cancel();
    _roomStateSub?.cancel();
    _hostPromotedSub?.cancel();

    _playerJoinedSub = widget.netplayService.onPlayerJoined.listen(
      _onPlayerJoined,
    );
    _playerUpdatedSub = widget.netplayService.onPlayerUpdated.listen(
      _onPlayerUpdated,
    );
    _playerLeftSub = widget.netplayService.onPlayerLeft.listen(_onPlayerLeft);
    _roomStateSub = widget.netplayService.onRoomStateChanged.listen(
      _onRoomState,
    );
    _messageSub = widget.netplayService.onMessage.listen(_onMessage);
    _romRequestSub = widget.netplayService.onRomRequested.listen((peerId) {
      if (_isRoomHost) {
        unawaited(_sendRomToPeer(peerId: peerId));
      }
    });
    _romProgressSub = widget.netplayService.onRomProgress.listen(
      _onRomProgress,
    );
    _startGameSub = widget.netplayService.onStartGame.listen(_launchEmulator);
    final cachedStart = widget.netplayService.lastStartGameEvent;
    if (cachedStart != null &&
        widget.netplayService.status == NetplayStatus.gaming) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          _launchEmulator(cachedStart);
        }
      });
    }
    _connectionSub = widget.netplayService.onConnectionStateChanged.listen((
      connected,
    ) {
      if (!connected &&
          mounted &&
          !_leaving &&
          !widget.netplayService.isHostPromotionPending) {
        _leaveRoom(showDisconnectedSnack: true, notifyHost: false);
      }
    });
    _hostPromotedSub = widget.netplayService.onHostPromoted.listen(
      _onHostPromoted,
    );

    _syncPlayersFromService();
  }

  void _syncPlayersFromService() {
    final state = widget.netplayService.roomState;
    if (state != null && mounted) {
      setState(() {
        _players
          ..clear()
          ..addAll(state.players);
      });
    }
  }

  void _onHostPromoted(RoomInfo room) {
    if (!mounted) {
      return;
    }
    setState(() {
      _promotedToHost = true;
      _roomLive = true;
      _isReady = false;
      _internetDirectCode = widget.netplayService.internetDirectInviteCode;
      _roomNameController.text = room.roomName;
      _selectedMaxPlayers = room.maxPlayers;
      final idx = _games.indexWhere((g) => g.md5 == room.gameMd5);
      if (idx >= 0) {
        _selectedGameIndex = idx;
        _localGame = _games[idx];
        if (_pageController?.hasClients ?? false) {
          _pageController!.animateToPage(
            idx,
            duration: const Duration(milliseconds: 250),
            curve: Curves.easeOutCubic,
          );
        }
      }
    });
    _showSnack('你已成为房主，等待玩家加入');
    _syncPlayersFromService();
  }

  Future<void> _openRoom() async {
    if (!AppSettingsService.instance.networkEnabled) {
      _showSnack('联机设置已关闭，请先在设置中开启');
      return;
    }

    final game = _selectedGame;
    if (game == null) {
      _showSnack('请先选择一款游戏');
      return;
    }

    final romPath = await _gameLibrary.resolvePlayableRomPath(
      game.path,
      md5: game.md5,
    );
    if (romPath == null) {
      _showSnack('无法读取所选 ROM 文件');
      return;
    }

    setState(() => _creating = true);

    final hostIp = await widget.netplayService.getLocalIp() ?? '0.0.0.0';
    final roomId = DateTime.now().millisecondsSinceEpoch
        .toRadixString(36)
        .toUpperCase();
    final roomTemplate = RoomInfo(
      roomId: roomId,
      roomName: _roomNameController.text.trim().isEmpty
          ? await NetplayService.defaultRoomName()
          : _roomNameController.text.trim(),
      hostIp: hostIp,
      port: widget.netplayService.port,
      gameCode: game.path.split('/').last,
      gameTitle: game.name,
      gameMd5: game.md5 ?? '',
      currentPlayers: 1,
      maxPlayers: _selectedMaxPlayers.clamp(2, 4),
    );

    InternetDirectCode? directCode;
    final success = _roomMode == NetplayRoomMode.internet
        ? (directCode = await widget.netplayService.createInternetDirectRoom(
                roomTemplate: roomTemplate,
                playerName: 'Player 1',
              )) !=
              null
        : await widget.netplayService.createRoom(
            roomTemplate: roomTemplate,
            playerName: 'Player 1',
          );

    if (!mounted) {
      return;
    }

    setState(() {
      _creating = false;
      if (success) {
        _roomLive = true;
        _localGame = game;
        _internetDirectCode = directCode;
      }
    });

    if (!success) {
      _showSnack('创建房间失败，请检查网络与端口设置');
      return;
    }

    _attachNetplayListeners();
    widget.netplayService.enterLobby();
  }

  void _onRoomState(NetplayRoomState state) {
    if (!mounted) {
      return;
    }
    setState(() {
      _players
        ..clear()
        ..addAll(state.players);
    });
  }

  void _onPlayerJoined(PlayerInfo player) {
    final state = widget.netplayService.roomState;
    if (state != null) {
      setState(() {
        _players
          ..clear()
          ..addAll(state.players);
      });
      return;
    }
    setState(() {
      if (!_players.any((p) => p.id == player.id)) {
        _players.add(player);
      }
    });
  }

  void _onPlayerUpdated(PlayerInfo player) {
    final state = widget.netplayService.roomState;
    if (state != null) {
      setState(() {
        _players
          ..clear()
          ..addAll(state.players);
      });
      return;
    }
    setState(() {
      final index = _players.indexWhere((p) => p.id == player.id);
      if (index >= 0) {
        final current = _players[index];
        _players[index] = current.copyWith(
          isReady: player.isReady || current.isReady,
          latency: player.latency > 0 ? player.latency : current.latency,
        );
      }
    });
  }

  void _onPlayerLeft(String playerId) {
    if (widget.netplayService.roomState != null) {
      return;
    }
    setState(() {
      _players.removeWhere((p) => p.id == playerId);
    });
  }

  void _onMessage(NetplayMessage message) {
    switch (message.type) {
      case NetplayMessageType.readyStatus:
        final ready = message.payload['status'] == 'ready';
        setState(() {
          final peerIndex = _players.indexWhere((p) => !p.isHost);
          if (peerIndex >= 0) {
            _players[peerIndex] = _players[peerIndex].copyWith(isReady: ready);
          }
        });
      case NetplayMessageType.leave:
        if (!_isRoomHost && mounted) {
          _leaveRoom(showDisconnectedSnack: true, notifyHost: false);
        }
    }
  }

  void _onRomProgress(RomTransferProgress progress) {
    if (!progress.isSending &&
        progress.bytes != null &&
        progress.fileName != null) {
      setState(_clearRomTransferUi);
      unawaited(_saveReceivedRom(progress));
      return;
    }

    if (progress.isSending && progress.progress >= 1.0) {
      setState(_clearRomTransferUi);
      return;
    }

    setState(() {
      _romProgress = progress.progress.clamp(0.0, 1.0);
      _romStatusText = progress.isSending
          ? '正在发送 ROM... ${(progress.progress * 100).round()}%'
          : '正在接收 ROM... ${(progress.progress * 100).round()}%';
    });
  }

  void _clearRomTransferUi() {
    _romProgress = 0;
    _romStatusText = null;
  }

  bool get _showRomTransferUi {
    if (widget.netplayService.status == NetplayStatus.transferringRom) {
      return true;
    }
    if (_romProgress > 0 && _romProgress < 1.0) {
      return true;
    }
    final text = _romStatusText;
    return text != null && (text.contains('正在') || text.contains('等待'));
  }

  double _gameCarouselHeight(BuildContext context) {
    return 108.0;
  }

  static const _gameBannerSideInset = 16.0;
  static const _gameBannerItemGap = 2.0;

  void _ensurePageController(BuildContext context) {
    final screenWidth = MediaQuery.sizeOf(context).width;
    final pageWidth = screenWidth - _gameBannerSideInset * 2;
    final fraction = ((pageWidth + _gameBannerItemGap) / screenWidth).clamp(
      0.88,
      0.96,
    );

    _pageController ??= PageController(
      viewportFraction: fraction,
      initialPage: _selectedGameIndex,
    );
  }

  Widget _buildGamePreview(GameRom game, {VoidCallback? onTap}) {
    return SizedBox(
      height: _gameCarouselHeight(context),
      width: double.infinity,
      child: GameCard(
        game: game,
        compact: true,
        horizontal: true,
        onTap: onTap,
      ),
    );
  }

  Future<void> _saveReceivedRom(RomTransferProgress progress) async {
    try {
      final result = await _gameLibrary.importNetplayRom(
        bytes: progress.bytes!,
        fileName: progress.fileName!,
      );
      if (!mounted || result == null) {
        return;
      }
      setState(() {
        _localGame = result.game;
        _hasLocalRom = true;
        _isReady = true;
      });
      widget.netplayService.sendReady(true);
    } catch (e) {
      if (!mounted) {
        return;
      }
      final message = 'ROM 接收失败: $e';
      _showSnack(message);
    }
  }

  Future<void> _promptRomTransfer() async {
    if (_awaitingRomDecision || !mounted) {
      return;
    }
    _awaitingRomDecision = true;

    final accept = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('缺少游戏 ROM'),
        content: Text(
          '本地没有「${_room?.gameTitle ?? '该游戏'}」或版本不一致。\n是否从房主接收 ROM？',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('接收'),
          ),
        ],
      ),
    );

    _awaitingRomDecision = false;

    if (accept == true) {
      widget.netplayService.requestRom();
      setState(() => _romStatusText = '等待房主发送 ROM...');
    }
  }

  Future<void> _sendRomToPeer({String? peerId}) async {
    final game = _localGame ?? _selectedGame;
    final room = _room;
    if (game == null || room == null) {
      return;
    }

    final romPath = await _gameLibrary.resolvePlayableRomPath(
      game.path,
      md5: game.md5,
    );
    if (romPath == null) {
      return;
    }

    final targetPeerId = peerId ?? widget.netplayService.firstPlayablePeerId;
    if (targetPeerId == null) {
      return;
    }

    await widget.netplayService.sendRomFile(
      peerId: targetPeerId,
      filePath: romPath,
      fileName: NetplayWire.safeFileName(
        romPath.split(Platform.pathSeparator).last,
      ),
    );
  }

  void _toggleReady() {
    setState(() => _isReady = !_isReady);
    widget.netplayService.sendReady(_isReady);
  }

  void _startGame() {
    if (!_isRoomHost) {
      return;
    }
    if (!_canStartGame) {
      return;
    }
    final game = _localGame ?? _selectedGame;
    final room = _room;
    if (game == null || room == null) {
      return;
    }
    widget.netplayService.startGame(gameMd5: room.gameMd5, gameId: game.id);
  }

  Future<void> _launchEmulator(NetplayStartGameEvent event) async {
    if (!_isRoomHost) {
      final ready = await _ensureGuestPlayerSlot();
      if (!ready || !mounted) {
        return;
      }
    }

    final game =
        _gameLibrary.findGameByMd5(event.gameMd5) ??
        _gameLibrary.getGame(event.gameId) ??
        _localGame;
    if (game == null) {
      return;
    }

    final romPath = await _gameLibrary.resolvePlayableRomPath(
      game.path,
      md5: game.md5,
    );
    if (romPath == null || !mounted) {
      return;
    }

    final romExtension = netplayExtensionFromPath(romPath);

    if (!mounted) {
      return;
    }

    final resumeSave = event.resume ? await _waitForResumeSaveState() : null;

    if (!mounted) {
      return;
    }

    final exitToLobby = await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) => NetplayEmulatorScreen(
          romPath: romPath,
          romExtension: romExtension,
          gameId: game.id,
          netplayService: widget.netplayService,
          isHost: _isRoomHost,
          resumeSaveState: resumeSave,
        ),
      ),
    );

    if (!mounted) {
      return;
    }

    if (exitToLobby == true) {
      Navigator.pop(context, true);
      return;
    }

    if (widget.netplayService.consumeExitingForReplacement()) {
      if (_isRoomHost) {
        widget.netplayService.exitGameAndHandoffHost();
        if (mounted) {
          Navigator.pop(context, true);
        }
        return;
      }
    }

    if (!widget.netplayService.isConnected) {
      if (mounted) {
        Navigator.pop(context, true);
      }
      return;
    }

    setState(() {
      _roomLive = true;
      _isReady = false;
      _promotedToHost = _promotedToHost || widget.netplayService.isHost;
    });
    _syncPlayersFromService();
  }

  Future<bool> _ensureGuestPlayerSlot() async {
    if (widget.netplayService.localPlayerSlot > 0) {
      return true;
    }
    try {
      await widget.netplayService.onPlayerSlotAssigned
          .firstWhere((slot) => slot > 0)
          .timeout(const Duration(seconds: 5));
      return widget.netplayService.localPlayerSlot > 0;
    } catch (_) {
      if (mounted) {
        _showSnack('未能分配玩家位，请退出房间后重新加入');
      }
      return false;
    }
  }

  Future<Uint8List?> _waitForResumeSaveState() async {
    final cached = widget.netplayService.takeResumeSaveState();
    if (cached != null) {
      return cached;
    }
    try {
      return await widget.netplayService.onSaveStateReceived.first.timeout(
        const Duration(seconds: 8),
      );
    } catch (_) {
      return null;
    }
  }

  void _leaveRoom({
    bool showDisconnectedSnack = false,
    bool notifyHost = true,
  }) {
    if (_leaving) {
      return;
    }
    _leaving = true;

    _connectionSub?.cancel();
    _connectionSub = null;
    _playerJoinedSub?.cancel();
    _playerUpdatedSub?.cancel();
    _playerLeftSub?.cancel();
    _messageSub?.cancel();
    _romRequestSub?.cancel();
    _romProgressSub?.cancel();
    _startGameSub?.cancel();
    _roomStateSub?.cancel();
    _hostPromotedSub?.cancel();

    try {
      if (_isRoomHost) {
        widget.netplayService.closeRoom();
      } else if (notifyHost) {
        widget.netplayService.leaveRoom();
      } else {
        widget.netplayService.detachFromRoom();
      }
    } catch (_) {
      // 连接可能已关闭，仍应退出房间页。
    }
    if (mounted) {
      if (showDisconnectedSnack) {
        _showSnack('房主已解散房间');
      }
      Navigator.pop(context, true);
    }
  }

  Future<void> _importRomForRoom() async {
    try {
      final result = await runWithAddGameLoading(
        context,
        (updateMessage) => _gameLibrary.addGame(onProgress: updateMessage),
        initialMessage: '正在添加…',
      );
      if (!mounted || result == null) {
        return;
      }
      setState(() {
        _setRoomGames(_gameLibrary.games);
        _selectedGameIndex = _games.indexWhere((g) => g.id == result.game.id);
        if (_selectedGameIndex < 0) {
          _selectedGameIndex = _games.isEmpty ? 0 : _games.length - 1;
        }
      });
      _showSnack(
        !isHostAuthoritativeNetplayExtension(result.game.extension)
            ? '已添加 ${result.game.name}，GBA 会在游戏内使用独立 Link 入口'
            : result.isDuplicate
            ? '该游戏已在库中: ${result.game.name}'
            : '已添加: ${result.game.name}',
      );
    } catch (e) {
      if (mounted) {
        _showSnack('添加失败: $e');
      }
    }
  }

  void _showSnack(String message) {
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final room = _room;
    final canStart = _isRoomHost && _roomLive && _canStartGame;

    return PopScope(
      canPop: !_roomLive,
      onPopInvokedWithResult: (didPop, _) {
        if (didPop) {
          return;
        }
        if (_roomLive) {
          _leaveRoom();
        }
      },
      child: Scaffold(
        backgroundColor: AppColors.background,
        appBar: AppBar(
          title: Text(_isRoomHost && !_roomLive ? '创建房间' : '组队房间'),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Column(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      padding: const EdgeInsets.only(bottom: 16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          _buildRoomHeader(context, room),
                          if (_room?.awaitingReplacement ?? false) ...[
                            const SizedBox(height: 12),
                            _buildAwaitingReplacementBanner(context),
                          ],
                          if (_isRoomHost && !_roomLive) ...[
                            const SizedBox(height: 12),
                            _buildRoomModeSelector(context),
                            const SizedBox(height: 12),
                            _buildMaxPlayersSelector(context),
                          ],
                          if (_internetDirectCode != null && _roomLive) ...[
                            const SizedBox(height: 12),
                            _buildInternetDirectCard(context),
                          ],
                          const SizedBox(height: 12),
                          _buildGameCarousel(context),
                          const SizedBox(height: 16),
                          _buildPlayersSection(context),
                          if (_showRomTransferUi) _buildRomStatus(context),
                        ],
                      ),
                    ),
                  ),
                  _buildBottomBar(context, canStart),
                ],
              ),
      ),
    );
  }

  Widget _buildRoomModeSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '连接方式',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          SegmentedButton<NetplayRoomMode>(
            segments: const [
              ButtonSegment(
                value: NetplayRoomMode.lan,
                icon: Icon(Icons.wifi),
                label: Text('局域网'),
              ),
              ButtonSegment(
                value: NetplayRoomMode.internet,
                icon: Icon(Icons.qr_code_2),
                label: Text('互联网'),
              ),
            ],
            selected: {_roomMode},
            onSelectionChanged: (value) {
              setState(() => _roomMode = value.first);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildInternetDirectCard(BuildContext context) {
    final code = _internetDirectCode;
    if (code == null) {
      return const SizedBox.shrink();
    }
    final raw = code.encode();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.public, color: AppColors.secondary, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '互联网二维码',
                  style: Theme.of(
                    context,
                  ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: '复制连接码',
                visualDensity: VisualDensity.compact,
                iconSize: 18,
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: raw));
                  _showSnack('已复制连接码');
                },
                icon: const Icon(Icons.copy),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              QrImageView(
                backgroundColor: Colors.white,
                data: raw,

                version: QrVersions.auto,
                size: 120,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _buildInternetInfoLine(
                      context,
                      label: '游戏',
                      value: code.gameTitle,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildInternetInfoLine(
    BuildContext context, {
    required String label,
    required String value,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelSmall?.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 2),
        Text(
          value,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: AppColors.onSurface,
            fontFamily: 'JetBrains Mono',
            height: 1.25,
          ),
        ),
      ],
    );
  }

  Widget _buildMaxPlayersSelector(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '联机人数',
            style: Theme.of(
              context,
            ).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            alignment: WrapAlignment.start,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: [2, 3, 4].map((count) {
              final selected = _selectedMaxPlayers == count;
              return ChoiceChip(
                label: Text('$count 人'),
                selected: selected,
                showCheckmark: false,
                visualDensity: VisualDensity.compact,
                onSelected: (_) {
                  setState(() => _selectedMaxPlayers = count);
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildAwaitingReplacementBanner(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.orange.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          const Icon(Icons.sync, color: Colors.orange, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              _isRoomHost ? '队友已离开，进度已保存。等待新玩家加入后将自动同步并继续。' : '房主等待新玩家加入以继续游戏…',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRoomHeader(BuildContext context, RoomInfo? room) {
    if (_isRoomHost && !_roomLive) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: TextField(
          controller: _roomNameController,
          decoration: const InputDecoration(
            labelText: '房间名称',
            hintText: '例如：Bobo的房间',
            border: OutlineInputBorder(),
          ),
        ),
      );
    }

    if (room == null) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: _buildMetaColumn(
              context,
              label: '房间码',
              value: room.roomId,
              mono: true,
            ),
          ),
          Expanded(
            child: _buildMetaColumn(
              context,
              label: '状态',
              value: room.phaseLabel,
              valueColor: room.inGame || room.awaitingReplacement
                  ? AppColors.secondary
                  : AppColors.onSurfaceVariant,
            ),
          ),
          Expanded(
            child: _buildMetaColumn(
              context,
              label: '人数',
              value: room.occupancyLabel,
              mono: true,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMetaColumn(
    BuildContext context, {
    required String label,
    required String value,
    bool mono = false,
    Color? valueColor,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: Theme.of(
            context,
          ).textTheme.labelMedium?.copyWith(color: AppColors.onSurfaceVariant),
        ),
        const SizedBox(height: 4),
        Text(
          value,
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            fontWeight: FontWeight.w600,
            color: valueColor ?? AppColors.onSurface,
            fontFamily: mono ? 'JetBrains Mono' : null,
            letterSpacing: mono ? 0.5 : null,
          ),
        ),
      ],
    );
  }

  Widget _buildGameCarousel(BuildContext context) {
    if (!_isRoomHost && _localGame == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '游戏',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Text(
              _room?.gameTitle ?? '未知游戏',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ],
        ),
      );
    }

    if (_isRoomHost && _games.isEmpty) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          children: [
            Text(
              '暂无可用于房间联机的游戏',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '房间模式支持 FC/NES、街机 ROM（.zip/.7z 整包）；GBA 暂使用 gpSP Wi-Fi/RFU 局域网通道',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 16),
            FilledButton.icon(
              onPressed: _importRomForRoom,
              icon: const Icon(Icons.add),
              label: const Text('添加游戏'),
            ),
          ],
        ),
      );
    }

    final games = _isRoomHost ? _games : [_localGame!];
    final locked = _roomLive || !_isRoomHost;
    final displayIndex = _isRoomHost
        ? _selectedGameIndex.clamp(0, games.length - 1)
        : 0;

    if (locked) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '游戏',
              style: Theme.of(context).textTheme.titleSmall?.copyWith(
                fontWeight: FontWeight.w600,
                color: AppColors.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            _buildGamePreview(games[displayIndex]),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Text(
            '选择游戏',
            style: Theme.of(
              context,
            ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        SizedBox(
          height: _gameCarouselHeight(context) + 8,
          child: Builder(
            builder: (context) {
              _ensurePageController(context);
              final controller = _pageController!;

              return PageView.builder(
                controller: controller,
                padEnds: false,
                physics: const BouncingScrollPhysics(),
                itemCount: games.length,
                onPageChanged: (index) {
                  setState(() => _selectedGameIndex = index);
                },
                itemBuilder: (context, index) {
                  final game = games[index];
                  final selected = index == _selectedGameIndex;

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: _gameBannerSideInset,
                    ),
                    child: Align(
                      alignment: Alignment.center,
                      child: AnimatedScale(
                        scale: selected ? 1 : 0.96,
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeOutCubic,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(14),
                            border: selected
                                ? Border.all(color: AppColors.primary, width: 2)
                                : null,
                            boxShadow: selected
                                ? [
                                    BoxShadow(
                                      color: AppColors.primary.withValues(
                                        alpha: 0.2,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 3),
                                    ),
                                  ]
                                : null,
                          ),
                          child: _buildGamePreview(
                            game,
                            onTap: () {
                              if (_selectedGameIndex == index) {
                                return;
                              }
                              controller.animateToPage(
                                index,
                                duration: const Duration(milliseconds: 280),
                                curve: Curves.easeOutCubic,
                              );
                            },
                          ),
                        ),
                      ),
                    ),
                  );
                },
              );
            },
          ),
        ),
        if (games.length > 1) ...[
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: List.generate(games.length, (index) {
              final active = index == _selectedGameIndex;
              return AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                margin: const EdgeInsets.symmetric(horizontal: 4),
                width: active ? 18 : 7,
                height: 7,
                decoration: BoxDecoration(
                  color: active ? AppColors.primary : AppColors.outlineVariant,
                  borderRadius: BorderRadius.circular(4),
                ),
              );
            }),
          ),
        ],
      ],
    );
  }

  Widget _buildPlayersSection(BuildContext context) {
    final seatCount = _maxSeats;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '玩家',
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w600,
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            alignment: WrapAlignment.start,
            spacing: 16,
            runSpacing: 12,
            children: [
              for (var slot = 1; slot <= seatCount; slot++)
                _buildPlayerSlot(
                  context,
                  player: _playerAtSlot(slot),
                  slotLabel: slot,
                ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerSlot(
    BuildContext context, {
    PlayerInfo? player,
    int? slotLabel,
  }) {
    final isEmpty = player == null;
    final isHost = player?.isHost ?? false;
    final isReady = player?.isReady ?? false;
    final slot = slotLabel ?? player?.slot;

    Color ringColor;
    String statusText;
    if (isEmpty) {
      ringColor = AppColors.outlineVariant;
      statusText = slot != null ? 'P$slot · 空位' : '空位';
    } else if (isReady) {
      ringColor = AppColors.secondary;
      statusText = isHost ? '房主' : '已准备';
    } else {
      ringColor = AppColors.onSurfaceVariant.withValues(alpha: 0.4);
      statusText = isHost ? '房主' : '未准备';
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          padding: const EdgeInsets.all(2),
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: ringColor, width: 2),
          ),
          child: CircleAvatar(
            radius: 22,
            backgroundColor: isEmpty
                ? AppColors.surfaceContainerLow
                : (isHost
                      ? AppColors.secondary.withValues(alpha: 0.15)
                      : AppColors.primary.withValues(alpha: 0.15)),
            child: isEmpty
                ? Icon(
                    Icons.person_add_alt_1,
                    color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
                    size: 18,
                  )
                : Text(
                    player.name.isNotEmpty ? player.name[0].toUpperCase() : '?',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                      color: isHost ? AppColors.secondary : AppColors.primary,
                    ),
                  ),
          ),
        ),
        const SizedBox(height: 4),
        SizedBox(
          width: 56,
          child: Text(
            isEmpty ? statusText : player.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: isEmpty ? AppColors.onSurfaceVariant : AppColors.onSurface,
            ),
          ),
        ),
        if (!isEmpty)
          Text(
            statusText,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: isReady ? AppColors.secondary : AppColors.onSurfaceVariant,
              fontSize: 10,
            ),
          ),
        if (!isEmpty && player.latency > 0)
          Text(
            '${player.latency}ms',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
              color: player.latency < 80
                  ? Colors.greenAccent
                  : player.latency < 150
                  ? Colors.orangeAccent
                  : Colors.redAccent,
              fontSize: 9,
              fontFamily: 'monospace',
            ),
          ),
      ],
    );
  }

  Widget _buildRomStatus(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
      child: Column(
        children: [
          if (_romProgress > 0)
            LinearProgressIndicator(value: _romProgress.clamp(0, 1)),
          if (_romStatusText != null) ...[
            const SizedBox(height: 8),
            Text(
              _romStatusText!,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBottomBar(BuildContext context, bool canStart) {
    if (!_isRoomHost && _roomLive) {
      return SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed:
                  _hasLocalRom &&
                      widget.netplayService.status !=
                          NetplayStatus.transferringRom
                  ? _toggleReady
                  : null,
              icon: Icon(
                _isReady ? Icons.check_circle : Icons.check_circle_outline,
              ),
              label: Text(_isReady ? '已准备，等待房主开始' : '准备'),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
        child: SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            onPressed: _primaryActionEnabled(canStart)
                ? _onPrimaryAction
                : null,
            icon: _creating
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : Icon(_primaryActionIcon(canStart)),
            label: Text(_primaryActionLabel(canStart)),
          ),
        ),
      ),
    );
  }

  bool _primaryActionEnabled(bool canStart) {
    if (_creating) {
      return false;
    }
    if (_isRoomHost && !_roomLive) {
      return _games.isNotEmpty;
    }
    if (_isRoomHost) {
      return canStart;
    }
    return false;
  }

  IconData _primaryActionIcon(bool canStart) {
    if (_isRoomHost && !_roomLive) {
      return Icons.meeting_room;
    }
    return Icons.play_arrow;
  }

  String _primaryActionLabel(bool canStart) {
    if (_creating) {
      return '开放中...';
    }
    if (_isRoomHost && !_roomLive) {
      return '开放房间';
    }
    if (_isRoomHost) {
      if (!_hasTeammate) {
        return '等待玩家加入';
      }
      return canStart ? '开始游戏' : '等待队友准备';
    }
    return '';
  }

  void _onPrimaryAction() {
    if (_isRoomHost && !_roomLive) {
      unawaited(_openRoom());
    } else if (_isRoomHost) {
      _startGame();
    }
  }
}
