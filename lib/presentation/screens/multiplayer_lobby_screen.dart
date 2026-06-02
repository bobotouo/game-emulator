import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/network/lan_service.dart';
import '../../core/settings/app_settings_service.dart';
import '../../features/game_library/game_library_service.dart';
import '../theme/app_theme.dart';
import '../widgets/immersive_scroll_page.dart';
import 'room_screen.dart';

class MultiplayerLobbyScreen extends StatefulWidget {
  const MultiplayerLobbyScreen({super.key, this.isActive = false});

  /// Whether the bottom-nav 「联机」 tab is currently visible.
  final bool isActive;

  @override
  State<MultiplayerLobbyScreen> createState() => _MultiplayerLobbyScreenState();
}

class _MultiplayerLobbyScreenState extends State<MultiplayerLobbyScreen> {
  static const _scanInterval = Duration(seconds: 5);
  static const _roomStaleTimeout = Duration(seconds: 6);

  final NetplayService _netplay = NetplayService();
  final GameLibraryService _gameLibrary = GameLibraryService();
  final List<RoomInfo> _rooms = [];
  final Map<String, bool> _localRomCache = {};
  final Map<String, DateTime> _roomLastSeen = {};
  final TextEditingController _searchController = TextEditingController();

  LanNetworkSnapshot? _network;
  bool _discoveryActive = false;
  String _searchQuery = '';
  Timer? _lobbyRefreshTimer;
  bool _joiningRoom = false;

  StreamSubscription<RoomInfo>? _roomSubscription;

  bool get _canUseLanLobby =>
      AppSettingsService.instance.networkEnabled &&
      (_network?.canUseLanLobby ?? false);

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(
        () => _searchQuery = _searchController.text.trim().toLowerCase(),
      );
    });
    unawaited(_initNetwork());
  }

  @override
  void didUpdateWidget(MultiplayerLobbyScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.isActive && !oldWidget.isActive) {
      _onTabVisible();
    } else if (!widget.isActive && oldWidget.isActive) {
      _onTabHidden();
    }
  }

  @override
  void dispose() {
    _lobbyRefreshTimer?.cancel();
    _roomSubscription?.cancel();
    _searchController.dispose();
    _netplay.stopDiscovery();
    super.dispose();
  }

  Future<void> _initNetwork() async {
    if (_gameLibrary.games.isEmpty) {
      await _gameLibrary.init(refreshThumbnails: false);
    } else {
      unawaited(_gameLibrary.init(refreshThumbnails: false));
    }

    _roomSubscription = _netplay.onRoomFound.listen((room) {
      unawaited(_onRoomDiscovered(room));
    });

    if (mounted && widget.isActive) {
      _onTabVisible();
    }
  }

  void _onTabVisible() {
    _lobbyRefreshTimer?.cancel();
    _lobbyRefreshTimer = Timer.periodic(_scanInterval, (_) {
      unawaited(_refreshLobbyNetwork());
      _pruneStaleRooms();
      unawaited(_probeUnreachableRooms());
    });
    unawaited(_refreshLobbyNetwork());
  }

  String _roomKey(RoomInfo room) =>
      '${room.roomId}|${room.hostIp}|${room.port}';

  void _removeRoomsById(String roomId) {
    _rooms.removeWhere((r) => r.roomId == roomId);
    _localRomCache.remove(roomId);
    _roomLastSeen.removeWhere((key, _) => key.startsWith('$roomId|'));
  }

  void _pruneStaleRooms() {
    if (_rooms.isEmpty) {
      return;
    }
    final now = DateTime.now();
    final staleKeys = _roomLastSeen.entries
        .where((entry) => now.difference(entry.value) > _roomStaleTimeout)
        .map((entry) => entry.key)
        .toList();
    if (staleKeys.isEmpty) {
      return;
    }
    setState(() {
      _rooms.removeWhere((room) => staleKeys.contains(_roomKey(room)));
      for (final key in staleKeys) {
        _roomLastSeen.remove(key);
      }
    });
  }

  Future<void> _probeUnreachableRooms() async {
    if (_rooms.isEmpty || !mounted) {
      return;
    }
    final activeRoom = _netplay.activeRoom;
    final deadRoomIds = <String>{};
    for (final room in _rooms) {
      if (activeRoom != null &&
          room.hostIp == activeRoom.hostIp &&
          room.port == activeRoom.port) {
        continue;
      }
      try {
        final socket = await Socket.connect(
          room.hostIp,
          room.port,
          timeout: const Duration(seconds: 2),
        );
        await socket.close();
      } catch (_) {
        deadRoomIds.add(room.roomId);
      }
    }
    if (deadRoomIds.isEmpty || !mounted) {
      return;
    }
    setState(() {
      for (final roomId in deadRoomIds) {
        _removeRoomsById(roomId);
      }
    });
  }

  void _onTabHidden() {
    _lobbyRefreshTimer?.cancel();
    _lobbyRefreshTimer = null;
    _pauseDiscovery();
  }

  Future<void> _refreshLobbyNetwork() async {
    final snapshot = await LanNetworkChecker.evaluate();
    if (!mounted) {
      return;
    }

    final wasLan = _network?.canUseLanLobby ?? false;
    setState(() => _network = snapshot);

    if (!AppSettingsService.instance.networkEnabled) {
      _pauseDiscovery();
      return;
    }

    if (snapshot.canUseLanLobby) {
      if (!_discoveryActive || !_netplay.isDiscoverySocketReady) {
        _ensureDiscoveryRunning(clearRooms: !wasLan && _rooms.isEmpty);
      } else {
        _netplay.pulseDiscovery();
      }
    } else {
      _pauseDiscovery();
    }
  }

  Future<void> _onRoomDiscovered(RoomInfo room) async {
    if (room.roomId.isEmpty || !mounted) {
      return;
    }

    final key = _roomKey(room);

    if (room.closed) {
      setState(() => _removeRoomsById(room.roomId));
      return;
    }

    setState(() {
      _rooms.removeWhere(
        (r) => r.roomId == room.roomId && _roomKey(r) != key,
      );
      _roomLastSeen[key] = DateTime.now();
      final index = _rooms.indexWhere((r) => _roomKey(r) == key);
      if (index >= 0) {
        _rooms[index] = room.copyWith(
          pingMs: room.pingMs ?? _rooms[index].pingMs,
        );
      } else {
        _rooms.add(room);
      }
    });

    final hasRom = await _gameLibrary.hasLocalRom(room.gameMd5);
    if (!mounted) {
      return;
    }
    _localRomCache[room.roomId] = hasRom;
  }

  List<RoomInfo> get _filteredRooms {
    if (_searchQuery.isEmpty) {
      return _rooms;
    }
    return _rooms.where((room) {
      return room.roomName.toLowerCase().contains(_searchQuery) ||
          room.gameTitle.toLowerCase().contains(_searchQuery);
    }).toList();
  }

  void _ensureDiscoveryRunning({bool clearRooms = false}) {
    if (!_canUseLanLobby) {
      return;
    }

    if (clearRooms) {
      setState(() {
        _rooms.clear();
        _localRomCache.clear();
        _roomLastSeen.clear();
      });
    }

    _discoveryActive = true;
    _netplay.stopDiscovery();
    _netplay.startDiscovery();
  }

  void _pauseDiscovery() {
    if (!_discoveryActive) {
      return;
    }
    _discoveryActive = false;
    _netplay.stopDiscovery();
  }

  void _manualRefresh() {
    if (!AppSettingsService.instance.networkEnabled) {
      _showNetworkDisabledMessage();
      return;
    }

    if (!(_network?.canUseLanLobby ?? false)) {
      _showWideAreaMessage();
      return;
    }

    setState(() {
      _rooms.clear();
      _localRomCache.clear();
      _roomLastSeen.clear();
    });
    if (!_discoveryActive || !_netplay.isDiscoverySocketReady) {
      _ensureDiscoveryRunning();
    } else {
      _netplay.pulseDiscovery();
    }
  }

  Future<void> _openCreateRoom() async {
    if (!AppSettingsService.instance.networkEnabled) {
      _showNetworkDisabledMessage();
      return;
    }
    if (!(_network?.canUseLanLobby ?? false)) {
      _showWideAreaMessage();
      return;
    }

    if (_gameLibrary.games.isEmpty) {
      await _gameLibrary.init(refreshThumbnails: false);
    } else {
      unawaited(_gameLibrary.init(refreshThumbnails: false));
    }

    if (!mounted) {
      return;
    }

    _pauseDiscovery();

    await Navigator.push<bool>(
      context,
      MaterialPageRoute(
        builder: (context) =>
            RoomScreen(netplayService: _netplay, gameLibrary: _gameLibrary),
      ),
    );

    if (mounted && widget.isActive) {
      unawaited(_refreshLobbyAfterRoom());
    }
  }

  Future<void> _joinRoom(RoomInfo room) async {
    if (_joiningRoom) {
      return;
    }
    _joiningRoom = true;

    try {
      if (!AppSettingsService.instance.networkEnabled) {
        _showNetworkDisabledMessage();
        return;
      }
      if (!(_network?.canUseLanLobby ?? false)) {
        _showWideAreaMessage();
        return;
      }

      if (room.isFull) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('房间已满')));
        return;
      }

      final hasRom =
          _localRomCache[room.roomId] ??
          await _gameLibrary.hasLocalRom(room.gameMd5);

      if (!mounted) {
        return;
      }

      final success = await _netplay.joinRoom(
        room,
        playerName: 'Player 2',
      );

      if (!success) {
        if (!mounted) {
          return;
        }
        setState(() => _removeRoomsById(room.roomId));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('加入房间失败')));
        return;
      }

      _pauseDiscovery();

      if (!mounted) {
        return;
      }

      await Navigator.push<bool>(
        context,
        MaterialPageRoute(
          builder: (context) => RoomScreen(
            netplayService: _netplay,
            gameLibrary: _gameLibrary,
            isHost: false,
            roomInfo: room,
            hasLocalRom: hasRom,
          ),
        ),
      );

      if (mounted && widget.isActive) {
        unawaited(_refreshLobbyAfterRoom());
      }
    } finally {
      _joiningRoom = false;
    }
  }

  /// 从房间返回后清空列表并重新扫描，避免仍显示已离开/已解散的房间。
  Future<void> _refreshLobbyAfterRoom() async {
    if (!mounted) {
      return;
    }

    setState(() {
      _rooms.clear();
      _localRomCache.clear();
      _roomLastSeen.clear();
    });

    await _refreshLobbyNetwork();
    if (!mounted || !widget.isActive) {
      return;
    }

    if (_canUseLanLobby) {
      _ensureDiscoveryRunning();
      _netplay.pulseDiscovery();
    }
  }

  void _showNetworkDisabledMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('联机设置已关闭，请先在设置中开启'),
        duration: Duration(seconds: 2),
      ),
    );
  }

  void _showWideAreaMessage() {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(_network?.userMessage ?? '局域网联机仅支持同一 WiFi 下的设备，不支持外网。'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset =
        kBottomNavigationBarHeight + MediaQuery.paddingOf(context).bottom + 88;
    final rooms = _filteredRooms;
    final onLan = _network?.canUseLanLobby ?? false;
    final networkMessage = _network?.userMessage;

    return ImmersiveScrollPage(
      title: '联机大厅',
      actions: [
        IconButton(
          icon: const Icon(Icons.refresh),
          tooltip: '重新搜索',
          onPressed: _manualRefresh,
        ),
      ],
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _canUseLanLobby ? _openCreateRoom : _showWideAreaMessage,
        backgroundColor: AppColors.secondary,
        foregroundColor: AppColors.onSecondary,
        icon: const Icon(Icons.add),
        label: const Text('创建房间'),
      ),
      slivers: [
        SliverToBoxAdapter(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            color: AppColors.surfaceContainerLow,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: onLan ? AppColors.secondary : AppColors.error,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      onLan ? '局域网 · 在线' : '非局域网',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                        color: onLan ? AppColors.secondary : AppColors.error,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '本机 IP: ${_network?.localIp ?? "获取中..."}',
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        color: AppColors.onSurfaceVariant,
                        fontFamily: 'JetBrains Mono',
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
            ),
          ),
        ),
        if (networkMessage != null && networkMessage.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
              child: Material(
                color: AppColors.error.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Icon(
                        Icons.wifi_off,
                        color: AppColors.error,
                        size: 20,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          networkMessage,
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(color: AppColors.error, height: 1.4),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              decoration: InputDecoration(
                hintText: '搜索房间或游戏...',
                hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                prefixIcon: const Icon(
                  Icons.search,
                  color: AppColors.onSurfaceVariant,
                ),
                filled: true,
                fillColor: AppColors.surfaceContainerLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.outlineVariant),
                ),
              ),
            ),
          ),
        ),
        if (rooms.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  Icons.wifi_find,
                  size: 64,
                  color: AppColors.onSurfaceVariant.withValues(alpha: 0.3),
                ),
                const SizedBox(height: 16),
                Text(
                  onLan ? '暂未发现房间' : '请连接 WiFi 后再试',
                  style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                    color: AppColors.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          )
        else
          SliverPadding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, bottomInset),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (context, index) => _buildRoomCard(context, rooms[index]),
                childCount: rooms.length,
              ),
            ),
          ),
      ],
    );
  }

  void _onRoomTap(RoomInfo room) {
    if (!AppSettingsService.instance.networkEnabled) {
      _showNetworkDisabledMessage();
      return;
    }
    if (!(_network?.canUseLanLobby ?? false)) {
      _showWideAreaMessage();
      return;
    }

    if (room.isFull) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('房间已满')));
      return;
    }

    unawaited(_joinRoom(room));
  }

  Widget _buildRoomCard(BuildContext context, RoomInfo room) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _onRoomTap(room),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildRoomGameCover(room),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                room.roomName,
                                style: Theme.of(context).textTheme.bodyLarge
                                    ?.copyWith(fontWeight: FontWeight.w600),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                room.gameTitle,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(color: AppColors.onSurfaceVariant),
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _buildInfoChip(Icons.people, room.occupancyLabel),
                        if (room.pingMs != null) ...[
                          const SizedBox(width: 8),
                          _buildInfoChip(
                            Icons.network_ping,
                            '${room.pingMs}ms',
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              _buildRoomStatusBadge(room),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildRoomStatusBadge(RoomInfo room) {
    late Color background;
    late Color foreground;
    late Color borderColor;

    if (room.awaitingReplacement) {
      background = const Color(0xFF3A2A12);
      foreground = const Color(0xFFFFB74D);
      borderColor = const Color(0xFFFF9800).withValues(alpha: 0.55);
    } else if (room.inGame) {
      background = const Color(0xFF0F2E24);
      foreground = const Color(0xFF5DFFC8);
      borderColor = AppColors.secondary.withValues(alpha: 0.5);
    } else {
      background = const Color(0xFF1A2433);
      foreground = const Color(0xFF90B8FF);
      borderColor = const Color(0xFF5B8DEF).withValues(alpha: 0.45);
    }

    return Container(
      constraints: const BoxConstraints(minWidth: 58),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: borderColor, width: 1),
      ),
      child: Text(
        room.phaseLabel,
        textAlign: TextAlign.center,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: foreground,
          height: 1.25,
          letterSpacing: 0.2,
        ),
      ),
    );
  }

  Widget _buildRoomGameCover(RoomInfo room) {
    const size = 56.0;
    const radius = 8.0;
    final game = room.gameMd5.isNotEmpty
        ? _gameLibrary.findGameByMd5(room.gameMd5)
        : null;
    final thumbnailPath = game?.thumbnailPath;

    if (thumbnailPath != null && File(thumbnailPath).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(radius),
        child: Image.file(
          File(thumbnailPath),
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorBuilder: (context, error, stackTrace) =>
              _buildRoomCoverPlaceholder(size, radius, game?.extension),
        ),
      );
    }

    return _buildRoomCoverPlaceholder(size, radius, game?.extension);
  }

  Widget _buildRoomCoverPlaceholder(
    double size,
    double radius,
    String? extension,
  ) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(radius),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.primary.withValues(alpha: 0.3),
            AppColors.surfaceContainerHighest,
          ],
        ),
      ),
      child: Icon(
        _coverIconForExtension(extension),
        size: 28,
        color: AppColors.primary.withValues(alpha: 0.6),
      ),
    );
  }

  IconData _coverIconForExtension(String? extension) {
    switch (extension?.toLowerCase()) {
      case '.gba':
        return Icons.gamepad;
      case '.gbc':
      case '.gb':
        return Icons.gamepad_outlined;
      case '.nes':
      case '.fc':
      case '.fds':
        return Icons.videogame_asset;
      case '.zip':
      case '.7z':
        return Icons.sports_esports;
      default:
        return Icons.sports_esports_outlined;
    }
  }

  Widget _buildInfoChip(
    IconData icon,
    String label, {
    Color? labelColor,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: AppColors.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 12, color: labelColor ?? AppColors.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: labelColor ?? AppColors.onSurfaceVariant,
              fontFamily: 'JetBrains Mono',
            ),
          ),
        ],
      ),
    );
  }
}
