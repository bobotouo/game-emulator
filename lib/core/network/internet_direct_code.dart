import 'dart:convert';
import 'dart:io';

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

  static const scheme = 'gbaemu://netplay';

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

  String encode() {
    final payload = <String, Object?>{
      'v': 3,
      'transport': 'webrtc-worker',
      'signalUrl': signalUrl,
      'signalRoomId': signalRoomId,
      'roomId': roomId,
      'roomName': roomName,
      'gameCode': gameCode,
      'gameTitle': gameTitle,
      'gameMd5': gameMd5,
      'maxPlayers': maxPlayers,
    };
    final jsonBytes = utf8.encode(jsonEncode(payload));
    final compressed = GZipCodec().encode(jsonBytes);
    final body = base64UrlEncode(compressed);
    return '$scheme#$body';
  }

  static InternetDirectCode? tryDecode(String raw) {
    final text = raw.trim();
    if (!text.startsWith('$scheme#')) {
      return null;
    }
    final body = text.substring('$scheme#'.length);
    try {
      final normalized = base64Url.normalize(body);
      final raw = base64Url.decode(normalized);
      final jsonBytes = (() {
        try {
          return GZipCodec().decode(raw);
        } catch (_) {
          return raw;
        }
      })();
      final decoded = jsonDecode(utf8.decode(jsonBytes)) as Map;
      final version = (decoded['v'] as num?)?.toInt() ?? 1;
      final transport = decoded['transport'] as String? ?? '';
      if (version < 3 || transport != 'webrtc-worker') {
        return null;
      }

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
    } catch (_) {
      return null;
    }
  }

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
