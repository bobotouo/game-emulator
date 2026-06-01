import 'netplay_service.dart';
import 'player_info.dart';

/// Netplay context shown on the multiplayer emulator screen.
class NetplayEmulatorSession {
  const NetplayEmulatorSession({
    required this.maxPlayers,
    required this.localPlayerSlot,
    required this.slotPlayers,
  });

  final int maxPlayers;
  final int localPlayerSlot;

  /// Index `0` = P1 … `maxPlayers-1` = Pn; `null` = empty slot.
  final List<PlayerInfo?> slotPlayers;

  factory NetplayEmulatorSession.fromNetplay({
    required NetplayService netplay,
    required bool isHost,
  }) {
    final state = netplay.roomState;
    final room = netplay.hostedRoom ?? netplay.activeRoom ?? netplay.joinedRoom;
    final maxPlayers = (state?.maxPlayers ?? room?.maxPlayers ?? 2).clamp(2, 4);

    final localSlot = isHost ? 1 : netplay.localPlayerSlot;

    final slots = List<PlayerInfo?>.filled(maxPlayers, null);
    final roster = state?.players ?? const <PlayerInfo>[];
    for (final player in roster) {
      if (player.slot >= 1 && player.slot <= maxPlayers) {
        slots[player.slot - 1] = player;
      }
    }

    if (isHost && slots[0] == null) {
      PlayerInfo? hostPlayer;
      for (final player in roster) {
        if (player.isHost) {
          hostPlayer = player;
          break;
        }
      }
      slots[0] = hostPlayer ??
          const PlayerInfo(
            id: 'host',
            name: '房主',
            isHost: true,
            isReady: true,
            slot: 1,
          );
    }

    return NetplayEmulatorSession(
      maxPlayers: maxPlayers,
      localPlayerSlot: localSlot,
      slotPlayers: slots,
    );
  }

  NetplayEmulatorSession copyWith({
    int? maxPlayers,
    int? localPlayerSlot,
    List<PlayerInfo?>? slotPlayers,
  }) {
    return NetplayEmulatorSession(
      maxPlayers: maxPlayers ?? this.maxPlayers,
      localPlayerSlot: localPlayerSlot ?? this.localPlayerSlot,
      slotPlayers: slotPlayers ?? this.slotPlayers,
    );
  }
}
