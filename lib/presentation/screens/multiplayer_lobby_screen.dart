import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../core/network/lan_service.dart';
import '../../core/settings/app_settings_service.dart';
import 'battle_room_screen.dart';

class MultiplayerLobbyScreen extends StatefulWidget {
  const MultiplayerLobbyScreen({super.key});

  @override
  State<MultiplayerLobbyScreen> createState() => _MultiplayerLobbyScreenState();
}

class _MultiplayerLobbyScreenState extends State<MultiplayerLobbyScreen> {
  final LANService _lanService = LANService();
  final List<RoomInfo> _rooms = [];
  String? _localIp;
  bool _isSearching = false;
  late StreamSubscription<RoomInfo> _roomSubscription;

  @override
  void initState() {
    super.initState();
    _initNetwork();
  }

  @override
  void dispose() {
    _roomSubscription.cancel();
    _lanService.dispose();
    super.dispose();
  }

  Future<void> _initNetwork() async {
    _localIp = await _lanService.getLocalIp();
    setState(() {});

    // Listen for discovered rooms
    _roomSubscription = _lanService.onRoomFound.listen((room) {
      if (!_rooms.any((r) => r.code == room.code)) {
        setState(() {
          _rooms.add(room);
        });
      }
    });
  }

  void _startSearching() {
    if (!AppSettingsService.instance.networkEnabled) {
      _showNetworkDisabledMessage();
      return;
    }

    setState(() {
      _isSearching = true;
      _rooms.clear();
    });
    _lanService.startDiscovery();
  }

  void _stopSearching() {
    setState(() {
      _isSearching = false;
    });
    _lanService.stopDiscovery();
  }

  Future<void> _createRoom() async {
    if (!AppSettingsService.instance.networkEnabled) {
      _showNetworkDisabledMessage();
      return;
    }

    final success = await _lanService.createRoom();
    if (success && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) =>
              BattleRoomScreen(lanService: _lanService, isHost: true),
        ),
      );
    }
  }

  Future<void> _joinRoom(RoomInfo room) async {
    if (!AppSettingsService.instance.networkEnabled) {
      _showNetworkDisabledMessage();
      return;
    }

    final success = await _lanService.joinRoom(room.hostIp);
    if (success && mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => BattleRoomScreen(
            lanService: _lanService,
            isHost: false,
            roomInfo: room,
          ),
        ),
      );
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('联机大厅'),
        actions: [
          IconButton(
            icon: Icon(_isSearching ? Icons.stop : Icons.refresh),
            onPressed: _isSearching ? _stopSearching : _startSearching,
          ),
        ],
      ),
      body: Column(
        children: [
          // Online Status
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surfaceContainerLow,
            child: Row(
              children: [
                Container(
                  width: 12,
                  height: 12,
                  decoration: BoxDecoration(
                    color: _localIp != null
                        ? AppColors.secondary
                        : AppColors.error,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  _localIp != null ? '在线' : '离线',
                  style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: _localIp != null
                        ? AppColors.secondary
                        : AppColors.error,
                  ),
                ),
                const Spacer(),
                Text(
                  '本机 IP: ${_localIp ?? "获取中..."}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: AppColors.onSurfaceVariant,
                    fontFamily: 'JetBrains Mono',
                  ),
                ),
              ],
            ),
          ),

          // Search/Filter
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              decoration: InputDecoration(
                hintText: '搜索房间...',
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

          // Searching indicator
          if (_isSearching)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    '正在搜索房间...',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: AppColors.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),

          // Room List
          Expanded(
            child: _rooms.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(
                          Icons.wifi_find,
                          size: 64,
                          color: AppColors.onSurfaceVariant.withValues(
                            alpha: 0.3,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          _isSearching ? '正在搜索房间...' : '暂未发现房间',
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(color: AppColors.onSurfaceVariant),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          '点击右上角刷新按钮开始搜索',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppColors.onSurfaceVariant.withValues(
                                  alpha: 0.7,
                                ),
                              ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _rooms.length,
                    itemBuilder: (context, index) {
                      return _buildRoomCard(context, _rooms[index]);
                    },
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createRoom,
        backgroundColor: AppColors.secondary,
        foregroundColor: AppColors.onSecondary,
        icon: const Icon(Icons.add),
        label: const Text('创建房间'),
      ),
    );
  }

  Widget _buildRoomCard(BuildContext context, RoomInfo room) {
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: InkWell(
        onTap: () => _joinRoom(room),
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: AppColors.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                      gradient: LinearGradient(
                        colors: [
                          AppColors.primary.withValues(alpha: 0.3),
                          AppColors.surfaceContainerHighest,
                        ],
                      ),
                    ),
                    child: const Icon(Icons.gamepad, color: AppColors.primary),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          room.name,
                          style: Theme.of(context).textTheme.bodyLarge
                              ?.copyWith(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '房间码: ${room.code}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppColors.onSurfaceVariant,
                                fontFamily: 'JetBrains Mono',
                              ),
                        ),
                      ],
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: AppColors.secondary.withValues(alpha: 0.2),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: AppColors.secondary.withValues(alpha: 0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 8,
                          height: 8,
                          decoration: const BoxDecoration(
                            color: AppColors.secondary,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 4),
                        Text(
                          '${room.playerCount}/${room.maxPlayers}',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppColors.secondary,
                                fontWeight: FontWeight.w600,
                              ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  _buildInfoChip(Icons.wifi, room.hostIp),
                  const Spacer(),
                  TextButton(
                    onPressed: () => _joinRoom(room),
                    child: const Text('加入'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData icon, String label) {
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
          Icon(icon, size: 12, color: AppColors.onSurfaceVariant),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              color: AppColors.onSurfaceVariant,
              fontFamily: 'JetBrains Mono',
            ),
          ),
        ],
      ),
    );
  }
}
