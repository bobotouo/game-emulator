import 'dart:async';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../core/network/lan_service.dart';

class BattleRoomScreen extends StatefulWidget {
  final LANService lanService;
  final bool isHost;
  final RoomInfo? roomInfo;

  const BattleRoomScreen({
    super.key,
    required this.lanService,
    required this.isHost,
    this.roomInfo,
  });

  @override
  State<BattleRoomScreen> createState() => _BattleRoomScreenState();
}

class _BattleRoomScreenState extends State<BattleRoomScreen> {
  final List<PlayerInfo> _players = [];
  bool _isReady = false;
  late StreamSubscription<PlayerInfo> _playerJoinedSub;
  late StreamSubscription<String> _playerLeftSub;

  @override
  void initState() {
    super.initState();
    _initRoom();

    // Listen for player events
    _playerJoinedSub = widget.lanService.onPlayerJoined.listen((player) {
      setState(() {
        _players.add(player);
      });
    });

    _playerLeftSub = widget.lanService.onPlayerLeft.listen((playerId) {
      setState(() {
        _players.removeWhere((p) => p.id == playerId);
      });
    });
  }

  @override
  void dispose() {
    _playerJoinedSub.cancel();
    _playerLeftSub.cancel();
    super.dispose();
  }

  void _initRoom() {
    if (widget.isHost) {
      // Add host as first player
      _players.add(PlayerInfo(
        id: 'host',
        name: 'Player 1 (房主)',
        isHost: true,
        isReady: true,
      ));
    } else {
      // Add self as player
      _players.add(PlayerInfo(
        id: widget.lanService.hostIp ?? 'self',
        name: 'Player 2',
        isHost: false,
        isReady: false,
      ));
    }
  }

  void _toggleReady() {
    setState(() {
      _isReady = !_isReady;
    });
    // TODO: Broadcast ready state to other players
  }

  void _startGame() {
    if (!widget.isHost) return;
    // TODO: Start game and navigate to emulator screen
  }

  void _leaveRoom() {
    if (widget.isHost) {
      widget.lanService.closeRoom();
    } else {
      widget.lanService.leaveRoom();
    }
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final roomCode = widget.lanService.roomCode ?? widget.roomInfo?.code ?? '------';

    return Scaffold(
      appBar: AppBar(
        title: const Text('对战房间'),
        actions: [
          IconButton(
            icon: const Icon(Icons.exit_to_app),
            onPressed: _leaveRoom,
          ),
        ],
      ),
      body: Column(
        children: [
          // Room Info
          Container(
            padding: const EdgeInsets.all(16),
            color: AppColors.surfaceContainerLow,
            child: Column(
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
                      child:
                          const Icon(Icons.gamepad, color: AppColors.primary),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            widget.roomInfo?.name ?? 'GBA 联机房间',
                            style: Theme.of(context)
                                .textTheme
                                .bodyLarge
                                ?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                          ),
                          const SizedBox(height: 4),
                          Row(
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
                                '房间已就绪',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(
                                      color: AppColors.secondary,
                                    ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                    // Room Code
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      decoration: BoxDecoration(
                        color: AppColors.surfaceContainerHighest,
                        borderRadius: BorderRadius.circular(8),
                        border:
                            Border.all(color: AppColors.outlineVariant),
                      ),
                      child: Column(
                        children: [
                          Text(
                            '房间码',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.onSurfaceVariant,
                              fontFamily: 'JetBrains Mono',
                            ),
                          ),
                          Text(
                            roomCode,
                            style: TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              color: AppColors.primary,
                              fontFamily: 'JetBrains Mono',
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Player List
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ..._players.map((player) => _buildPlayerCard(
                      context,
                      player: player,
                    )),
                // Empty slots
                ...List.generate(
                  4 - _players.length,
                  (index) => _buildEmptySlot(context, slotNumber: _players.length + index + 1),
                ),
              ],
            ),
          ),

          // Game Preview
          Container(
            height: 120,
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.black,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppColors.outlineVariant),
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(11),
              child: AspectRatio(
                aspectRatio: 240 / 160,
                child: Container(
                  color: Colors.black,
                  child: const Center(
                    child: Text(
                      '游戏预览',
                      style: TextStyle(
                        color: Colors.white54,
                        fontFamily: 'Space Mono',
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),

          // Action Buttons
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Row(
              children: [
                if (!widget.isHost)
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: _toggleReady,
                      icon: Icon(
                        _isReady
                            ? Icons.check_circle
                            : Icons.check_circle_outline,
                      ),
                      label: Text(_isReady ? '已准备' : '准备'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: _isReady
                            ? AppColors.secondary
                            : AppColors.onSurfaceVariant,
                        side: BorderSide(
                          color: _isReady
                              ? AppColors.secondary
                              : AppColors.outlineVariant,
                        ),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                if (!widget.isHost) const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    onPressed: widget.isHost ? _startGame : null,
                    icon: const Icon(Icons.play_arrow),
                    label: Text(widget.isHost ? '开始游戏' : '等待房主开始'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: widget.isHost
                          ? AppColors.primary
                          : AppColors.surfaceContainerHighest,
                      foregroundColor: widget.isHost
                          ? AppColors.onPrimary
                          : AppColors.onSurfaceVariant,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPlayerCard(
    BuildContext context, {
    required PlayerInfo player,
  }) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: LinearGradient(
                  colors: [
                    AppColors.primary.withValues(alpha: 0.3),
                    AppColors.surfaceContainerHighest,
                  ],
                ),
                border: Border.all(
                  color: player.isHost
                      ? AppColors.secondary
                      : AppColors.outlineVariant,
                  width: player.isHost ? 2 : 1,
                ),
              ),
              child: Center(
                child: Text(
                  player.name[0].toUpperCase(),
                  style: TextStyle(
                    fontFamily: 'Space Mono',
                    fontWeight: FontWeight.w700,
                    color: player.isHost
                        ? AppColors.secondary
                        : AppColors.primary,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            // Name & Status
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Text(
                        player.name,
                        style:
                            Theme.of(context).textTheme.bodyMedium?.copyWith(
                                  fontWeight: FontWeight.w600,
                                ),
                      ),
                      if (player.isHost) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color:
                                AppColors.secondary.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            '房主',
                            style: TextStyle(
                              fontSize: 10,
                              color: AppColors.secondary,
                              fontFamily: 'JetBrains Mono',
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '延迟: ${player.latency}ms',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                          color: AppColors.onSurfaceVariant,
                          fontFamily: 'JetBrains Mono',
                        ),
                  ),
                ],
              ),
            ),
            // Ready Status
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: player.isReady
                    ? AppColors.secondary.withValues(alpha: 0.2)
                    : AppColors.surfaceContainerHighest,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: player.isReady
                      ? AppColors.secondary
                      : AppColors.outlineVariant,
                ),
              ),
              child: Text(
                player.isReady ? '已准备' : '未准备',
                style: TextStyle(
                  fontSize: 12,
                  color: player.isReady
                      ? AppColors.secondary
                      : AppColors.onSurfaceVariant,
                  fontFamily: 'JetBrains Mono',
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptySlot(BuildContext context, {required int slotNumber}) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      color: AppColors.surfaceContainerLow,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: AppColors.surfaceContainerHighest,
                border: Border.all(color: AppColors.outlineVariant),
              ),
              child: Icon(
                Icons.person_add,
                color:
                    AppColors.onSurfaceVariant.withValues(alpha: 0.5),
                size: 20,
              ),
            ),
            const SizedBox(width: 12),
            Text(
              '等待玩家加入...',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                    color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
                  ),
            ),
          ],
        ),
      ),
    );
  }
}
