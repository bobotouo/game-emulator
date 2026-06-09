import 'room_info.dart';

class InternetDirectCode {
  const InternetDirectCode({
    required this.signalUrl,
    required this.signalRoomId,
    required this.roomId,
    required this.roomName,
    required this.gameCode,
    required this.gameTitle,
    required this.gameMd5,
    required this.maxPlayers,
  });

  final String signalUrl;
  final String signalRoomId;
  final String roomId;
  final String roomName;
  final String gameCode;
  final String gameTitle;
  final String gameMd5;
  final int maxPlayers;

  RoomInfo toRoomInfo() {
    return RoomInfo(
      roomId: roomId,
      roomName: roomName,
      hostIp: Uri.tryParse(signalUrl)?.host ?? 'internet',
      port: 443,
      gameCode: gameCode,
      gameTitle: gameTitle,
      gameMd5: gameMd5,
      currentPlayers: 1,
      maxPlayers: maxPlayers.clamp(2, 4),
      internetDirect: true,
      signalRoomId: signalRoomId,
    );
  }

  Map<String, dynamic> toJson() => {
    'signalUrl': signalUrl,
    'signalRoomId': signalRoomId,
    'roomId': roomId,
    'roomName': roomName,
    'gameCode': gameCode,
    'gameTitle': gameTitle,
    'gameMd5': gameMd5,
    'maxPlayers': maxPlayers,
  };

  static InternetDirectCode? fromJson(Map<String, dynamic> decoded) {
    final signalUrl = decoded['signalUrl'] as String? ?? '';
    final signalRoomId = decoded['signalRoomId'] as String? ?? '';
    final roomId = decoded['roomId'] as String? ?? signalRoomId;
    final maxPlayers = ((decoded['maxPlayers'] as num?)?.toInt() ?? 2).clamp(
      2,
      4,
    );
    final signalUri = Uri.tryParse(signalUrl);
    if (signalUrl.isEmpty ||
        signalUri == null ||
        !signalUri.hasScheme ||
        signalUri.host.isEmpty ||
        signalRoomId.isEmpty ||
        roomId.isEmpty) {
      return null;
    }
    return InternetDirectCode(
      signalUrl: signalUrl,
      signalRoomId: signalRoomId,
      roomId: roomId,
      roomName: decoded['roomName'] as String? ?? '互联网直连房间',
      gameCode: decoded['gameCode'] as String? ?? '',
      gameTitle: decoded['gameTitle'] as String? ?? '未知游戏',
      gameMd5: decoded['gameMd5'] as String? ?? '',
      maxPlayers: maxPlayers,
    );
  }
}
