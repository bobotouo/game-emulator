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

class InternetJoinTicket {
  const InternetJoinTicket({
    required this.joinId,
    required this.roomInfo,
    required this.expiresAtMs,
  });

  final String joinId;
  final RoomInfo roomInfo;
  final int expiresAtMs;
}

class InternetJoinRequest {
  const InternetJoinRequest({
    required this.joinId,
    required this.playerName,
    required this.hasOffer,
    required this.hasAnswer,
    required this.createdAtMs,
    required this.expiresAtMs,
  });

  final String joinId;
  final String playerName;
  final bool hasOffer;
  final bool hasAnswer;
  final int createdAtMs;
  final int expiresAtMs;
}

abstract final class CloudflareIceService {
  static const signalBaseUrl = 'https://game.bobotou118.dpdns.org';
  static const requestTimeout = Duration(seconds: 12);
  static const pollRequestTimeout = Duration(seconds: 6);
  static const signalPollInterval = Duration(milliseconds: 250);
  static const hostJoinPollInterval = Duration(milliseconds: 300);

  static CloudflareIceCredentials? _cachedIce;
  static DateTime? _cachedIceExpiresAt;
  static Future<CloudflareIceCredentials>? _icePrefetchInFlight;

  /// Warm ICE/TURN credentials (e.g. when opening the lobby).
  static Future<void> prefetchIce({int ttlSeconds = 86400}) async {
    try {
      await generate(ttlSeconds: ttlSeconds);
    } catch (e) {
      debugPrint('[InternetDirect/Worker] ICE prefetch failed: $e');
    }
  }

  static Future<CloudflareIceCredentials> generate({
    int ttlSeconds = 86400,
    bool forceRefresh = false,
  }) async {
    final now = DateTime.now();
    final cached = _cachedIce;
    final expiresAt = _cachedIceExpiresAt;
    if (!forceRefresh &&
        cached != null &&
        expiresAt != null &&
        now.isBefore(expiresAt)) {
      return cached;
    }

    if (!forceRefresh && _icePrefetchInFlight != null) {
      return _icePrefetchInFlight!;
    }

    final fetch = _fetchIceFromWorker(ttlSeconds: ttlSeconds);
    _icePrefetchInFlight = fetch;
    try {
      final credentials = await fetch;
      _cachedIce = credentials;
      // Refresh a few minutes before worker TTL to avoid mid-join expiry.
      _cachedIceExpiresAt = now.add(
        Duration(seconds: ttlSeconds.clamp(300, 86400) - 300),
      );
      return credentials;
    } finally {
      if (identical(_icePrefetchInFlight, fetch)) {
        _icePrefetchInFlight = null;
      }
    }
  }

  static Future<CloudflareIceCredentials> _fetchIceFromWorker({
    required int ttlSeconds,
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

  static void clearIceCache() {
    _cachedIce = null;
    _cachedIceExpiresAt = null;
    _icePrefetchInFlight = null;
  }

  static Future<String> createRoom({
    required String offerSdp,
    required RoomInfo roomInfo,
    String? password,
    int ttlSeconds = 3600,
  }) async {
    final decoded = await _requestJson(
      'POST',
      '/rooms',
      body: {
        'offer': offerSdp,
        'ttlSeconds': ttlSeconds,
        'room': roomInfo.toJson(),
        if (password != null && password.isNotEmpty) 'password': password,
      },
    );
    final roomId = decoded['roomId'] as String? ?? '';
    if (roomId.isEmpty) {
      throw const FormatException('Worker create room response missing roomId');
    }
    return roomId;
  }

  static Future<List<RoomInfo>> listRooms() async {
    final decoded = await _requestJson('GET', '/rooms');
    final rawRooms = decoded['rooms'] as List? ?? const [];
    final signalHost = Uri.parse(signalBaseUrl).host;
    return rawRooms
        .whereType<Map>()
        .map((raw) {
          final roomId = raw['roomId'] as String? ?? '';
          final signalRoomId = raw['signalRoomId'] as String? ?? roomId;
          final roomPayload =
              raw['room'] as Map? ?? raw['roomInfo'] as Map? ?? const {};
          final passwordRequired = raw['passwordRequired'] == true;
          final room = RoomInfo.fromJson(
            Map<String, dynamic>.from(roomPayload),
            hostIp: signalHost,
          );
          return room.copyWith(
            hostIp: signalHost,
            port: 443,
            internetDirect: true,
            passwordRequired: passwordRequired,
            signalRoomId: signalRoomId,
          );
        })
        .where((room) {
          return room.roomId.isNotEmpty &&
              room.signalRoomId != null &&
              room.signalRoomId!.isNotEmpty;
        })
        .toList();
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
    return _parseSignalRoom(decoded);
  }

  static Future<InternetSignalRoom> joinRoom({
    required String roomId,
    String? password,
  }) async {
    final decoded = await _requestJson(
      'POST',
      '/rooms/$roomId/join',
      body: {if (password != null && password.isNotEmpty) 'password': password},
    );
    return _parseSignalRoom(decoded);
  }

  static Future<InternetJoinTicket> createJoinRequest({
    required String roomId,
    String? password,
    String? playerName,
  }) async {
    final decoded = await _requestJson(
      'POST',
      '/rooms/$roomId/join',
      body: {
        'request': true,
        if (password != null && password.isNotEmpty) 'password': password,
        if (playerName != null && playerName.isNotEmpty)
          'playerName': playerName,
      },
    );
    final joinId = decoded['joinId'] as String? ?? '';
    final roomPayload =
        decoded['room'] as Map? ?? decoded['roomInfo'] as Map? ?? const {};
    if (joinId.isEmpty || roomPayload.isEmpty) {
      throw const FormatException('Worker join request response is incomplete');
    }
    return InternetJoinTicket(
      joinId: joinId,
      roomInfo: RoomInfo.fromJson(
        Map<String, dynamic>.from(roomPayload),
        hostIp: Uri.parse(signalBaseUrl).host,
      ).copyWith(internetDirect: true, signalRoomId: roomId),
      expiresAtMs: (decoded['expiresAtMs'] as num?)?.toInt() ?? 0,
    );
  }

  static Future<List<InternetJoinRequest>> listJoinRequests({
    required String roomId,
  }) async {
    final decoded = await _requestJson('GET', '/rooms/$roomId/joins');
    final rawJoins = decoded['joins'] as List? ?? const [];
    return rawJoins
        .whereType<Map>()
        .map((raw) {
          return InternetJoinRequest(
            joinId: raw['joinId'] as String? ?? '',
            playerName: raw['playerName'] as String? ?? 'Player 2',
            hasOffer: raw['hasOffer'] == true,
            hasAnswer: raw['hasAnswer'] == true,
            createdAtMs: (raw['createdAtMs'] as num?)?.toInt() ?? 0,
            expiresAtMs: (raw['expiresAtMs'] as num?)?.toInt() ?? 0,
          );
        })
        .where((join) => join.joinId.isNotEmpty)
        .toList();
  }

  static Future<void> submitJoinOffer({
    required String roomId,
    required String joinId,
    required String offerSdp,
  }) async {
    await _requestJson(
      'POST',
      '/rooms/$roomId/joins/$joinId/offer',
      body: {'offer': offerSdp, 'offerSdp': offerSdp},
    );
  }

  static Future<InternetSignalRoom?> getJoinOffer({
    required String roomId,
    required String joinId,
  }) async {
    final decoded = await _requestJsonOrNull(
      'GET',
      '/rooms/$roomId/joins/$joinId/offer',
    );
    if (decoded == null) {
      return null;
    }
    final signalRoom = _parseSignalRoom(decoded);
    return InternetSignalRoom(
      offerSdp: signalRoom.offerSdp,
      roomInfo: signalRoom.roomInfo.copyWith(signalRoomId: roomId),
      expiresAtMs: signalRoom.expiresAtMs,
    );
  }

  static Future<void> submitJoinAnswer({
    required String roomId,
    required String joinId,
    required String answerSdp,
  }) async {
    await _requestJson(
      'POST',
      '/rooms/$roomId/joins/$joinId/answer',
      body: {'answer': answerSdp, 'answerSdp': answerSdp},
    );
  }

  static Future<String?> getJoinAnswer({
    required String roomId,
    required String joinId,
  }) async {
    final decoded = await _requestJsonOrNull(
      'GET',
      '/rooms/$roomId/joins/$joinId/answer',
    );
    if (decoded == null) {
      return null;
    }
    final answer =
        decoded['answer'] as String? ?? decoded['answerSdp'] as String? ?? '';
    return answer.isEmpty ? null : answer;
  }

  static Future<void> completeJoin({
    required String roomId,
    required String joinId,
  }) async {
    try {
      await _requestJson('POST', '/rooms/$roomId/joins/$joinId/complete');
    } on HttpException catch (e) {
      // Join ticket may already be completed by the other side.
      if (!e.message.contains('404')) {
        rethrow;
      }
    }
  }

  static Future<void> heartbeatRoom({
    required String roomId,
    required RoomInfo roomInfo,
    int ttlSeconds = 3600,
  }) async {
    await _requestJson(
      'POST',
      '/rooms/$roomId/heartbeat',
      body: {'ttlSeconds': ttlSeconds, 'room': roomInfo.toJson()},
    );
  }

  static InternetSignalRoom _parseSignalRoom(Map<String, dynamic> decoded) {
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
      ).copyWith(internetDirect: true),
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
    final decoded = await _requestJsonOrNull(
      'GET',
      '/rooms/$roomId/answer',
      timeout: pollRequestTimeout,
    );
    if (decoded == null) {
      return null;
    }
    final answer =
        decoded['answer'] as String? ?? decoded['answerSdp'] as String? ?? '';
    return answer.isEmpty ? null : answer;
  }

  static Future<void> closeRoom(String roomId) async {
    await _requestJson('POST', '/rooms/$roomId/close');
  }

  static HttpClient? _httpClient;

  static HttpClient get _client {
    return _httpClient ??= HttpClient()
      ..connectionTimeout = requestTimeout
      ..idleTimeout = const Duration(seconds: 60);
  }

  static Future<Map<String, dynamic>> _requestJson(
    String method,
    String path, {
    Map<String, dynamic>? body,
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? requestTimeout;
    final uri = Uri.parse('$signalBaseUrl$path');
    final client = _client;
    debugPrint('[InternetDirect/Worker] $method ${uri.path}');
    final request = await switch (method) {
      'GET' => client.getUrl(uri).timeout(effectiveTimeout),
      'POST' => client.postUrl(uri).timeout(effectiveTimeout),
      _ => throw ArgumentError.value(method, 'method'),
    };
    if (body != null) {
      final bytes = utf8.encode(jsonEncode(body));
      request.headers.contentType = ContentType.json;
      request.headers.contentLength = bytes.length;
      request.add(bytes);
    }
    final response = await request.close().timeout(effectiveTimeout);
    final text = await utf8
        .decodeStream(response)
        .timeout(effectiveTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Worker request failed: $method $path ${response.statusCode} $text',
      );
    }
    if (text.isEmpty) {
      return {};
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }

  static Future<Map<String, dynamic>?> _requestJsonOrNull(
    String method,
    String path, {
    Duration? timeout,
  }) async {
    final effectiveTimeout = timeout ?? pollRequestTimeout;
    final uri = Uri.parse('$signalBaseUrl$path');
    final client = _client;
    debugPrint('[InternetDirect/Worker] $method ${uri.path}');
    final request = await switch (method) {
      'GET' => client.getUrl(uri).timeout(effectiveTimeout),
      _ => throw ArgumentError.value(method, 'method'),
    };
    final response = await request.close().timeout(effectiveTimeout);
    if (response.statusCode == HttpStatus.noContent) {
      return null;
    }
    final text = await utf8
        .decodeStream(response)
        .timeout(effectiveTimeout);
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw HttpException(
        'Worker request failed: $method $path ${response.statusCode} $text',
      );
    }
    if (text.isEmpty) {
      return null;
    }
    return jsonDecode(text) as Map<String, dynamic>;
  }
}
