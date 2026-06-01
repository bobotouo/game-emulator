import 'player_info.dart';

/// Authoritative room roster synced to every connected client.
class NetplayRoomState {
  const NetplayRoomState({
    required this.players,
    required this.maxPlayers,
    this.inGame = false,
    this.awaitingReplacement = false,
  });

  final List<PlayerInfo> players;
  final int maxPlayers;
  final bool inGame;
  final bool awaitingReplacement;

  int get playableCount =>
      players.where((p) => p.slot > 0).length;

  PlayerInfo? occupantOfSlot(int slot) {
    for (final p in players) {
      if (p.slot == slot) {
        return p;
      }
    }
    return null;
  }

  factory NetplayRoomState.fromPayload(Map<String, dynamic> payload) {
    final rawPlayers = payload['players'];
    final players = <PlayerInfo>[];
    if (rawPlayers is List) {
      for (final entry in rawPlayers) {
        if (entry is Map) {
          players.add(PlayerInfo.fromJson(Map<String, dynamic>.from(entry)));
        }
      }
    }
    return NetplayRoomState(
      players: players,
      maxPlayers: ((payload['maxPlayers'] as num?)?.toInt() ?? 2).clamp(2, 4),
      inGame: payload['inGame'] as bool? ?? false,
      awaitingReplacement: payload['awaitingReplacement'] as bool? ?? false,
    );
  }

  Map<String, dynamic> toPayload() => {
        'players': players.map((p) => p.toJson()).toList(),
        'maxPlayers': maxPlayers,
        'inGame': inGame,
        'awaitingReplacement': awaitingReplacement,
      };
}
