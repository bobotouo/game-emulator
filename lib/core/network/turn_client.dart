import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'stun_client.dart';

class TurnServerPreset {
  const TurnServerPreset({
    required this.label,
    required this.host,
    this.port = 3478,
    this.altPort = 53,
    this.username,
    this.credential,
    this.custom = false,
  });

  final String label;
  final String host;
  final int port;
  final int? altPort;
  final String? username;
  final String? credential;
  final bool custom;

  bool get hasCredentials =>
      username != null &&
      username!.isNotEmpty &&
      credential != null &&
      credential!.isNotEmpty;

  String get endpoint => '$host:$port';

  List<int> get probePorts => [
    port,
    if (altPort != null && altPort != port) altPort!,
  ];

  TurnServerPreset copyWith({
    String? label,
    String? host,
    int? port,
    int? altPort,
    String? username,
    String? credential,
  }) {
    return TurnServerPreset(
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      altPort: altPort ?? this.altPort,
      username: username ?? this.username,
      credential: credential ?? this.credential,
      custom: custom,
    );
  }

  static TurnServerPreset? tryParseCustom(String raw) {
    final text = raw.trim();
    if (text.isEmpty) {
      return null;
    }
    var userPart = '';
    var hostPart = text;
    final at = text.lastIndexOf('@');
    if (at > 0) {
      userPart = text.substring(0, at);
      hostPart = text.substring(at + 1);
    }
    final colon = hostPart.lastIndexOf(':');
    final host = colon > 0 ? hostPart.substring(0, colon).trim() : hostPart;
    final port = colon > 0 ? int.tryParse(hostPart.substring(colon + 1)) : 3478;
    if (host.isEmpty || port == null || port <= 0 || port > 65535) {
      return null;
    }
    String? username;
    String? credential;
    if (userPart.isNotEmpty) {
      final sep = userPart.indexOf(':');
      if (sep <= 0) {
        return null;
      }
      username = userPart.substring(0, sep);
      credential = userPart.substring(sep + 1);
      if (username.isEmpty || credential.isEmpty) {
        return null;
      }
    }
    return TurnServerPreset(
      label: '自定义',
      host: host,
      port: port,
      altPort: null,
      username: username,
      credential: credential,
      custom: true,
    );
  }
}

class TurnRelayEndpoint {
  const TurnRelayEndpoint({
    required this.host,
    required this.port,
    required this.elapsed,
  });

  final String host;
  final int port;
  final Duration elapsed;

  String get endpoint => '$host:$port';
}

abstract final class TurnClient {
  static const presets = [
    TurnServerPreset(
      label: 'Cloudflare',
      host: 'turn.cloudflare.com',
      port: 3478,
      altPort: 53,
    ),
    TurnServerPreset(label: '自定义', host: '', custom: true),
  ];

  static const _allocateRequest = 0x0003;
  static const _allocateSuccess = 0x0103;
  static const _allocateError = 0x0113;
  static const _magicCookie = 0x2112A442;
  static const _requestedTransport = 0x0019;
  static const _xorRelayedAddress = 0x0016;
  static const _username = 0x0006;
  static const _messageIntegrity = 0x0008;
  static const _realm = 0x0014;
  static const _nonce = 0x0015;
  static const _errorCode = 0x0009;
  static const _udpTransport = 0x11;

  static Future<StunMappedAddress> queryBinding(
    TurnServerPreset server, {
    Duration timeout = const Duration(seconds: 4),
  }) {
    return StunClient.query(
      StunServerPreset(label: server.label, host: server.host, port: server.port),
      timeout: timeout,
    );
  }

  static Future<StunMappedAddress> queryBindingWithSocket(
    RawDatagramSocket socket,
    TurnServerPreset server, {
    Stream<RawSocketEvent>? events,
    Duration timeout = const Duration(seconds: 4),
  }) {
    return StunClient.queryWithSocket(
      socket,
      StunServerPreset(label: server.label, host: server.host, port: server.port),
      events: events,
      timeout: timeout,
    );
  }

  static Future<TurnRelayEndpoint?> allocateRelay(
    RawDatagramSocket socket,
    TurnServerPreset server, {
    Stream<RawSocketEvent>? events,
    Duration timeout = const Duration(seconds: 6),
  }) async {
    if (!server.hasCredentials) {
      return null;
    }
    final addresses = await InternetAddress.lookup(
      server.host,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) {
      return null;
    }
    final stopwatch = Stopwatch()..start();
    for (final probePort in server.probePorts) {
      final relay = await _allocateOnPort(
        socket: socket,
        serverAddress: addresses.first,
        serverPort: probePort,
        username: server.username!,
        credential: server.credential!,
        events: events,
        timeout: timeout,
      );
      if (relay != null) {
        stopwatch.stop();
        return TurnRelayEndpoint(
          host: relay.$1,
          port: relay.$2,
          elapsed: stopwatch.elapsed,
        );
      }
    }
    return null;
  }

  static Future<(String, int)?> _allocateOnPort({
    required RawDatagramSocket socket,
    required InternetAddress serverAddress,
    required int serverPort,
    required String username,
    required String credential,
    required Stream<RawSocketEvent>? events,
    required Duration timeout,
  }) async {
    final transactionId = _transactionId();
    final first = _allocateRequestBytes(transactionId);
    socket.send(first, serverAddress, serverPort);

    final firstResponse = await _waitTurnResponse(
      socket: socket,
      transactionId: transactionId,
      events: events,
      timeout: timeout,
    );
    if (firstResponse == null) {
      return null;
    }

    final code = firstResponse.errorCode;
    if (code == null) {
      return _parseRelayedAddress(firstResponse.bytes);
    }
    if (code != 401 && code != 438) {
      return null;
    }
    final realm = firstResponse.realm;
    final nonce = firstResponse.nonce;
    if (realm == null || nonce == null) {
      return null;
    }

    final authenticated = _allocateRequestBytes(
      transactionId,
      username: username,
      realm: realm,
      nonce: nonce,
      credential: credential,
    );
    socket.send(authenticated, serverAddress, serverPort);

    final secondResponse = await _waitTurnResponse(
      socket: socket,
      transactionId: transactionId,
      events: events,
      timeout: timeout,
    );
    if (secondResponse == null) {
      return null;
    }
    if (secondResponse.errorCode != null) {
      return null;
    }
    return _parseRelayedAddress(secondResponse.bytes);
  }

  static Future<_TurnResponse?> _waitTurnResponse({
    required RawDatagramSocket socket,
    required Uint8List transactionId,
    required Stream<RawSocketEvent>? events,
    required Duration timeout,
  }) async {
    final completer = Completer<_TurnResponse?>();
    late StreamSubscription<RawSocketEvent> sub;
    sub = (events ?? socket).listen((event) {
      if (event != RawSocketEvent.read || completer.isCompleted) {
        return;
      }
      final datagram = socket.receive();
      if (datagram == null) {
        return;
      }
      final parsed = _parseTurnPacket(datagram.data, transactionId);
      if (parsed != null) {
        completer.complete(parsed);
      }
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return null;
    } finally {
      await sub.cancel();
    }
  }

  static Uint8List _transactionId() {
    final random = Random.secure();
    return Uint8List.fromList(
      List<int>.generate(12, (_) => random.nextInt(256)),
    );
  }

  static Uint8List _allocateRequestBytes(
    Uint8List transactionId, {
    String? username,
    String? realm,
    String? nonce,
    String? credential,
  }) {
    final attrs = <Uint8List>[];
    attrs.add(_attribute(_requestedTransport, Uint8List.fromList([0, 0, 0, _udpTransport])));
    if (username != null && realm != null && nonce != null && credential != null) {
      attrs.add(_attribute(_username, Uint8List.fromList(utf8.encode(username))));
      attrs.add(_attribute(_realm, Uint8List.fromList(utf8.encode(realm))));
      attrs.add(_attribute(_nonce, Uint8List.fromList(utf8.encode(nonce))));
    }

    var length = 0;
    for (final attr in attrs) {
      length += attr.length;
    }
    if (credential != null && realm != null && username != null && nonce != null) {
      length += 24;
    }

    final bytes = Uint8List(20 + length);
    final header = ByteData.sublistView(bytes);
    header.setUint16(0, _allocateRequest);
    header.setUint16(2, length);
    header.setUint32(4, _magicCookie);
    bytes.setRange(8, 20, transactionId);

    var offset = 20;
    for (final attr in attrs) {
      bytes.setRange(offset, offset + attr.length, attr);
      offset += attr.length;
    }

    if (credential != null && realm != null && username != null && nonce != null) {
      final integrityOffset = offset;
      final integrity = _attribute(_messageIntegrity, Uint8List(20));
      bytes.setRange(offset, offset + integrity.length, integrity);
      final key = md5.convert(utf8.encode('$username:$realm:$credential')).bytes;
      final hmac = Hmac(sha1, key);
      final mac = hmac.convert(bytes.sublist(0, integrityOffset));
      bytes.setRange(integrityOffset + 4, integrityOffset + 24, mac.bytes);
      header.setUint16(2, integrityOffset + integrity.length - 20);
    }

    return bytes;
  }

  static Uint8List _attribute(int type, Uint8List value) {
    final paddedLength = (value.length + 3) & ~3;
    final bytes = Uint8List(4 + paddedLength);
    final data = ByteData.sublistView(bytes);
    data.setUint16(0, type);
    data.setUint16(2, value.length);
    bytes.setRange(4, 4 + value.length, value);
    return bytes;
  }

  static _TurnResponse? _parseTurnPacket(
    Uint8List bytes,
    Uint8List transactionId,
  ) {
    if (bytes.length < 20) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    final type = data.getUint16(0);
    if (type != _allocateSuccess && type != _allocateError) {
      return null;
    }
    if (data.getUint32(4) != _magicCookie) {
      return null;
    }
    for (var i = 0; i < transactionId.length; i++) {
      if (bytes[8 + i] != transactionId[i]) {
        return null;
      }
    }

    int? errorCode;
    String? realm;
    String? nonce;
    final messageLength = data.getUint16(2);
    var offset = 20;
    final end = min(bytes.length, 20 + messageLength);
    while (offset + 4 <= end) {
      final attrType = data.getUint16(offset);
      final length = data.getUint16(offset + 2);
      final valueOffset = offset + 4;
      if (valueOffset + length > end) {
        break;
      }
      if (attrType == _errorCode && length >= 4) {
        final klass = bytes[valueOffset];
        final number = bytes[valueOffset + 1];
        errorCode = klass * 100 + number;
      } else if (attrType == _realm) {
        realm = utf8.decode(bytes.sublist(valueOffset, valueOffset + length));
      } else if (attrType == _nonce) {
        nonce = utf8.decode(bytes.sublist(valueOffset, valueOffset + length));
      }
      offset = valueOffset + ((length + 3) & ~3);
    }
    return _TurnResponse(bytes: bytes, errorCode: errorCode, realm: realm, nonce: nonce);
  }

  static (String, int)? _parseRelayedAddress(Uint8List bytes) {
    final data = ByteData.sublistView(bytes);
    final messageLength = data.getUint16(2);
    var offset = 20;
    final end = min(bytes.length, 20 + messageLength);
    while (offset + 4 <= end) {
      final type = data.getUint16(offset);
      final length = data.getUint16(offset + 2);
      final valueOffset = offset + 4;
      if (valueOffset + length > end) {
        return null;
      }
      if (type == _xorRelayedAddress) {
        return _parseXorAddress(bytes, valueOffset, length);
      }
      offset = valueOffset + ((length + 3) & ~3);
    }
    return null;
  }

  static (String, int)? _parseXorAddress(
    Uint8List bytes,
    int offset,
    int length,
  ) {
    if (length < 8 || offset + length > bytes.length) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    if (bytes[offset + 1] != 0x01) {
      return null;
    }
    var port = data.getUint16(offset + 2);
    var address = data.getUint32(offset + 4);
    port ^= (_magicCookie >> 16);
    address ^= _magicCookie;
    final host = [
      (address >> 24) & 0xFF,
      (address >> 16) & 0xFF,
      (address >> 8) & 0xFF,
      address & 0xFF,
    ].join('.');
    return (host, port);
  }
}

class _TurnResponse {
  const _TurnResponse({
    required this.bytes,
    this.errorCode,
    this.realm,
    this.nonce,
  });

  final Uint8List bytes;
  final int? errorCode;
  final String? realm;
  final String? nonce;
}
