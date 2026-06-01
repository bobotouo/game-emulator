import 'dart:convert';

/// LAN room metadata shared between host and clients.
class RoomInfo {
  const RoomInfo({
    required this.roomId,
    required this.roomName,
    required this.hostIp,
    required this.port,
    required this.gameCode,
    required this.gameTitle,
    required this.gameMd5,
    this.currentPlayers = 1,
    this.maxPlayers = 2,
    this.inGame = false,
    this.awaitingReplacement = false,
    this.closed = false,
    this.pingMs,
  });

  final String roomId;
  final String roomName;
  final String hostIp;
  final int port;
  final String gameCode;
  final String gameTitle;
  final String gameMd5;
  final int currentPlayers;
  final int maxPlayers;
  final bool inGame;
  final bool awaitingReplacement;
  final bool closed;
  final int? pingMs;

  String get code => roomId;

  String get name => roomName;

  int get playerCount => currentPlayers;

  bool get isFull =>
      currentPlayers >= maxPlayers && (!inGame || !awaitingReplacement);

  bool get canJoinAsPlayer =>
      currentPlayers < maxPlayers && (!inGame || awaitingReplacement);

  String get phaseLabel {
    if (awaitingReplacement) {
      return '等待续玩';
    }
    return inGame ? '游戏进行中' : '等待玩家';
  }

  String get occupancyLabel => '$currentPlayers/$maxPlayers';

  RoomInfo copyWith({
    String? roomId,
    String? roomName,
    String? hostIp,
    int? port,
    String? gameCode,
    String? gameTitle,
    String? gameMd5,
    int? currentPlayers,
    int? maxPlayers,
    bool? inGame,
    bool? awaitingReplacement,
    bool? closed,
    int? pingMs,
  }) {
    return RoomInfo(
      roomId: roomId ?? this.roomId,
      roomName: roomName ?? this.roomName,
      hostIp: hostIp ?? this.hostIp,
      port: port ?? this.port,
      gameCode: gameCode ?? this.gameCode,
      gameTitle: gameTitle ?? this.gameTitle,
      gameMd5: gameMd5 ?? this.gameMd5,
      currentPlayers: currentPlayers ?? this.currentPlayers,
      maxPlayers: maxPlayers ?? this.maxPlayers,
      inGame: inGame ?? this.inGame,
      awaitingReplacement: awaitingReplacement ?? this.awaitingReplacement,
      closed: closed ?? this.closed,
      pingMs: pingMs ?? this.pingMs,
    );
  }

  Map<String, String> toTxtRecord() => {
        'roomId': roomId,
        'roomName': roomName,
        'gameCode': gameCode,
        'gameTitle': gameTitle,
        'gameMd5': gameMd5,
        'players': '$currentPlayers/$maxPlayers',
        'inGame': inGame ? '1' : '0',
        'awaitingReplacement': awaitingReplacement ? '1' : '0',
      };

  factory RoomInfo.fromTxtRecord({
    required String hostIp,
    required int port,
    required Map<String, String> txt,
    int? pingMs,
  }) {
    final playersRaw = txt['players'] ?? '1/2';
    final parts = playersRaw.split('/');
    final maxPlayers = int.tryParse(parts.length > 1 ? parts[1] : '2') ?? 2;
    return RoomInfo(
      roomId: txt['roomId'] ?? txt['id'] ?? '',
      roomName: txt['roomName'] ?? txt['name'] ?? '联机房间',
      hostIp: hostIp,
      port: port,
      gameCode: txt['gameCode'] ?? '',
      gameTitle: txt['gameTitle'] ?? '未知游戏',
      gameMd5: txt['gameMd5'] ?? '',
      currentPlayers: int.tryParse(parts.first) ?? 1,
      maxPlayers: maxPlayers.clamp(2, 4),
      inGame: txt['inGame'] == '1' || txt['inGame'] == 'true',
      awaitingReplacement:
          txt['awaitingReplacement'] == '1' ||
          txt['awaitingReplacement'] == 'true',
      pingMs: pingMs,
    );
  }

  factory RoomInfo.fromJson(Map<String, dynamic> json, {required String hostIp}) {
    return RoomInfo(
      roomId: json['roomId'] as String? ?? '',
      roomName: json['roomName'] as String? ?? '联机房间',
      hostIp: json['hostIp'] as String? ?? hostIp,
      port: json['port'] as int? ?? 7845,
      gameCode: json['gameCode'] as String? ?? '',
      gameTitle: json['gameTitle'] as String? ?? '未知游戏',
      gameMd5: json['gameMd5'] as String? ?? '',
      currentPlayers: json['currentPlayers'] as int? ?? 1,
      maxPlayers: (json['maxPlayers'] as int? ?? 2).clamp(2, 4),
      inGame: json['inGame'] as bool? ?? false,
      awaitingReplacement: json['awaitingReplacement'] as bool? ?? false,
      closed: json['closed'] as bool? ?? false,
      pingMs: json['pingMs'] as int?,
    );
  }

  Map<String, dynamic> toJson() => {
        'roomId': roomId,
        'roomName': roomName,
        'hostIp': hostIp,
        'port': port,
        'gameCode': gameCode,
        'gameTitle': gameTitle,
        'gameMd5': gameMd5,
        'currentPlayers': currentPlayers,
        'maxPlayers': maxPlayers,
        'inGame': inGame,
        'awaitingReplacement': awaitingReplacement,
        if (closed) 'closed': true,
      };

  String toUdpPayload() => jsonEncode(toJson());

  factory RoomInfo.fromUdpPayload(String hostIp, String payload) {
    return RoomInfo.fromJson(
      jsonDecode(payload) as Map<String, dynamic>,
      hostIp: hostIp,
    );
  }
}
