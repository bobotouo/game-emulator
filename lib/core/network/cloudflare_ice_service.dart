import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'room_info.dart';

class CloudflareIceCredentials {
  const CloudflareIceCredentials({required this.iceServers});

  final List<Map<String, dynamic>> iceServers;
}

class InternetSignalRoom {
  const InternetSignalRoom({
    required this.offerSdp,
    required this.roomInfo,
    required this.expiresAtMs,
  });

  final String offerSdp;
  final RoomInfo roomInfo;
  final int expiresAtMs;
}

abstract final class CloudflareIceService {
  static const signalBaseUrl = 'https://game.bobotou118.dpdns.org';
  static const requestTimeout = Duration(seconds: 20);

  static Future<CloudflareIceCredentials> generate({
    int ttlSeconds = 86400,
  }) async {
    final decoded = await _requestJson(
      'POST',
      '/ice',
      body: {'ttl': ttlSeconds},
    );
    final rawServers = decoded['iceServers'] as List? ?? const [];
    final servers = rawServers
        .whereType<Map>()
        .map((server) => Map<String, dynamic>.from(server))
        .where((server) => server['urls'] != null)
        .toList();
    if (servers.isEmpty) {
      throw const FormatException('Worker ICE response has no servers');
    }
    return CloudflareIceCredentials(iceServers: servers);
  }

  static Future<String> createRoom({
    required String offerSdp,
    required RoomInfo roomInfo,
    int ttlSeconds = 3600,
  }) async {
    final decoded = await _requestJson(
      'POST',
      '/rooms',
      body: {
        'offer': offerSdp,
        'ttlSeconds': ttlSeconds,
        'room': roomInfo.toJson(),
      },
    );
    final roomId = decoded['roomId'] as String? ?? '';
    if (roomId.isEmpty) {
      throw const FormatException('Worker create room response missing roomId');
    }
    return roomId;
  }

  static Future<void> updateRoom({
    required String roomId,
    required String offerSdp,
    required RoomInfo roomInfo,
    int ttlSeconds = 3600,
  }) async {
    await _requestJson(
      'POST',
      '/rooms/$roomId',
      body: {
        'offer': offerSdp,
        'offerSdp': offerSdp,
        'ttlSeconds': ttlSeconds,
        'room': roomInfo.toJson(),
        'roomInfo': roomInfo.toJson(),
      },
    );
  }

  static Future<InternetSignalRoom> getRoom(String roomId) async {
    final decoded = await _requestJson('GET', '/rooms/$roomId');
    final offer =
        decoded['offer'] as String? ?? decoded['offerSdp'] as String? ?? '';
    final roomPayload =
        decoded['room'] as Map? ?? decoded['roomInfo'] as Map? ?? const {};
    if (offer.isEmpty || roomPayload.isEmpty) {
      throw const FormatException('Worker room response is incomplete');
    }
    return InternetSignalRoom(
      offerSdp: offer,
      roomInfo: RoomInfo.fromJson(
        Map<String, dynamic>.from(roomPayload),
        hostIp: Uri.parse(signalBaseUrl).host,
      ),
      expiresAtMs:
          (decoded['expiresAt'] as num?)?.toInt() ??
          (decoded['expiresAtMs'] as num?)?.toInt() ??
          0,
    );
  }

  static Future<void> submitAnswer({
    required String roomId,
    required String answerSdp,
  }) async {
    await _requestJson(
      'POST',
      '/rooms/$roomId/answer',
      body: {'answer': answerSdp, 'answerSdp': answerSdp},
    );
  }

  static Future<String?> getAnswer(String roomId) async {
    final uri = Uri.parse('$signalBaseUrl/rooms/$roomId/answer');
    final client = HttpClient();
    client.connectionTimeout = requestTimeout;
    try {
      debugPrint('[InternetDirect/Worker] GET ${uri.path}');
      final request = await client.getUrl(uri).timeout(requestTimeout);
      final response = await request.close().timeout(requestTimeout);
      if (response.statusCode == HttpStatus.noContent) {
        return null;
      }
      final body = await utf8.decodeStream(response);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Worker answer request failed: ${response.statusCode} $body',
        );
      }
      final decoded = jsonDecode(body) as Map<String, dynamic>;
      final answer =
          decoded['answer'] as String? ?? decoded['answerSdp'] as String? ?? '';
      return answer.isEmpty ? null : answer;
    } finally {
      client.close(force: true);
    }
  }

  static Future<void> closeRoom(String roomId) async {
    await _requestJson('POST', '/rooms/$roomId/close');
  }

  static Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
  }) async {
    final uri = Uri.parse('$signalBaseUrl$path');
    final client = HttpClient();
    client.connectionTimeout = requestTimeout;
    try {
      debugPrint('[InternetDirect/Worker] $method ${uri.path}');
      final request = await switch (method) {
        'GET' => client.getUrl(uri).timeout(requestTimeout),
        'POST' => client.postUrl(uri).timeout(requestTimeout),
        _ => throw ArgumentError.value(method, 'method'),
      };
      if (body != null) {
        final bytes = utf8.encode(jsonEncode(body));
        request.headers.contentType = ContentType.json;
        request.headers.contentLength = bytes.length;
        request.add(bytes);
      }
      final response = await request.close().timeout(requestTimeout);
      final text = await utf8.decodeStream(response).timeout(requestTimeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        throw HttpException(
          'Worker request failed: $method $path ${response.statusCode} $text',
        );
      }
      if (text.isEmpty) {
        return {};
      }
      return jsonDecode(text) as Map<String, dynamic>;
    } finally {
      client.close(force: true);
    }
  }
}
