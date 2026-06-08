import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

class StunServerPreset {
  const StunServerPreset({
    required this.label,
    required this.host,
    this.port = 3478,
    this.custom = false,
  });

  final String label;
  final String host;
  final int port;
  final bool custom;

  String get endpoint => '$host:$port';

  StunServerPreset copyWith({String? label, String? host, int? port}) {
    return StunServerPreset(
      label: label ?? this.label,
      host: host ?? this.host,
      port: port ?? this.port,
      custom: custom,
    );
  }
}

class StunMappedAddress {
  const StunMappedAddress({
    required this.host,
    required this.port,
    required this.elapsed,
  });

  final String host;
  final int port;
  final Duration elapsed;

  String get endpoint => '$host:$port';
}

abstract final class StunClient {
  static const presets = [
    StunServerPreset(label: 'MiWiFi', host: 'stun.miwifi.com'),
    StunServerPreset(label: 'Bilibili', host: 'stun.chat.bilibili.com'),
    StunServerPreset(label: 'Cloudflare', host: 'stun.cloudflare.com'),
    StunServerPreset(label: '自定义', host: '', custom: true),
  ];

  static const _bindingRequest = 0x0001;
  static const _bindingSuccess = 0x0101;
  static const _magicCookie = 0x2112A442;
  static const _xorMappedAddress = 0x0020;
  static const _mappedAddress = 0x0001;

  static Future<StunMappedAddress> query(
    StunServerPreset server, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final addresses = await InternetAddress.lookup(
      server.host,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) {
      throw const SocketException('STUN 地址解析失败');
    }

    final socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
    try {
      return await queryWithSocket(socket, server, timeout: timeout);
    } finally {
      socket.close();
    }
  }

  static Future<StunMappedAddress> queryWithSocket(
    RawDatagramSocket socket,
    StunServerPreset server, {
    Stream<RawSocketEvent>? events,
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final addresses = await InternetAddress.lookup(
      server.host,
      type: InternetAddressType.IPv4,
    );
    if (addresses.isEmpty) {
      throw const SocketException('STUN 地址解析失败');
    }

    final transactionId = _transactionId();
    final request = _bindingRequestBytes(transactionId);
    final stopwatch = Stopwatch()..start();

    socket.send(request, addresses.first, server.port);
    final completer = Completer<StunMappedAddress>();
    late StreamSubscription<RawSocketEvent> sub;
    sub = (events ?? socket).listen((event) {
      if (event != RawSocketEvent.read || completer.isCompleted) {
        return;
      }
      final datagram = socket.receive();
      if (datagram == null) {
        return;
      }
      final mapped = _parseResponse(datagram.data, transactionId);
      if (mapped == null) {
        return;
      }
      stopwatch.stop();
      completer.complete(
        StunMappedAddress(
          host: mapped.$1,
          port: mapped.$2,
          elapsed: stopwatch.elapsed,
        ),
      );
    });

    try {
      return await completer.future.timeout(timeout);
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

  static Uint8List _bindingRequestBytes(Uint8List transactionId) {
    final bytes = Uint8List(20);
    final data = ByteData.sublistView(bytes);
    data.setUint16(0, _bindingRequest);
    data.setUint16(2, 0);
    data.setUint32(4, _magicCookie);
    bytes.setRange(8, 20, transactionId);
    return bytes;
  }

  static (String, int)? _parseResponse(
    Uint8List bytes,
    Uint8List transactionId,
  ) {
    if (bytes.length < 20) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    if (data.getUint16(0) != _bindingSuccess ||
        data.getUint32(4) != _magicCookie) {
      return null;
    }
    for (var i = 0; i < transactionId.length; i++) {
      if (bytes[8 + i] != transactionId[i]) {
        return null;
      }
    }

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
      if (type == _xorMappedAddress || type == _mappedAddress) {
        return _parseAddress(
          bytes,
          valueOffset,
          length,
          xor: type == _xorMappedAddress,
        );
      }
      offset = valueOffset + ((length + 3) & ~3);
    }
    return null;
  }

  static (String, int)? _parseAddress(
    Uint8List bytes,
    int offset,
    int length, {
    required bool xor,
  }) {
    if (length < 8 || offset + length > bytes.length) {
      return null;
    }
    final data = ByteData.sublistView(bytes);
    final family = bytes[offset + 1];
    if (family != 0x01) {
      return null;
    }
    var port = data.getUint16(offset + 2);
    var address = data.getUint32(offset + 4);
    if (xor) {
      port ^= (_magicCookie >> 16);
      address ^= _magicCookie;
    }
    final host = [
      (address >> 24) & 0xFF,
      (address >> 16) & 0xFF,
      (address >> 8) & 0xFF,
      address & 0xFF,
    ].join('.');
    return (host, port);
  }
}
