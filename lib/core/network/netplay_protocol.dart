import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'netplay_lockstep.dart';

/// JSON control messages exchanged over the netplay TCP channel.
abstract final class NetplayMessageType {
  static const join = 'JOIN';
  static const readyStatus = 'READY_STATUS';
  static const requestRom = 'REQUEST_ROM';
  static const romBegin = 'ROM_BEGIN';
  static const romChunk = 'ROM_CHUNK';
  static const romEnd = 'ROM_END';
  static const startGame = 'START_GAME';
  static const leave = 'LEAVE';
  static const ping = 'PING';
  static const pong = 'PONG';
  static const joinAck = 'JOIN_ACK';
  static const roomState = 'ROOM_STATE';
  static const lockstepReady = 'LOCKSTEP_READY';
  static const lockstepStart = 'LOCKSTEP_START';
  static const lockstepStartAck = 'LOCKSTEP_START_ACK';
  static const frameInput = 'FRAME_INPUT';
  static const frameBundle = 'FRAME_BUNDLE';
  static const saveStateBegin = 'SAVE_STATE_BEGIN';
  static const saveStateEnd = 'SAVE_STATE_END';
  static const gameExit = 'GAME_EXIT';
  static const hostPromote = 'HOST_PROMOTE';
  static const gameSpeed = 'GAME_SPEED';
  static const gbaNetpacket = 'GBA_NETPACKET';
  static const romProgress = 'ROM_PROGRESS';
  static const latencyReport = 'LATENCY_REPORT';
}

class NetplayMessage {
  const NetplayMessage(this.type, [this.payload = const {}]);

  final String type;
  final Map<String, dynamic> payload;

  Map<String, dynamic> toJson() => {'type': type, ...payload};

  factory NetplayMessage.fromJson(Map<String, dynamic> json) {
    final type = json['type'] as String? ?? '';
    final payload = Map<String, dynamic>.from(json)..remove('type');
    return NetplayMessage(type, payload);
  }

  static NetplayMessage join({required String playerName}) =>
      NetplayMessage(NetplayMessageType.join, {'playerName': playerName});

  static NetplayMessage joinAck({
    required int slot,
    required String playerId,
  }) => NetplayMessage(NetplayMessageType.joinAck, {
    'slot': slot,
    'playerId': playerId,
  });

  static NetplayMessage roomState(Map<String, dynamic> state) =>
      NetplayMessage(NetplayMessageType.roomState, state);

  static NetplayMessage ready({required bool ready}) => NetplayMessage(
    NetplayMessageType.readyStatus,
    {'status': ready ? 'ready' : 'idle'},
  );

  static NetplayMessage requestRom() =>
      const NetplayMessage(NetplayMessageType.requestRom);

  static NetplayMessage romBegin({
    required int size,
    required String fileName,
    required String md5,
    String? dataB64,
    bool chunked = false,
  }) {
    final safeName = NetplayWire.safeFileName(fileName);
    return NetplayMessage(NetplayMessageType.romBegin, {
      'size': size,
      'fileName': base64Encode(utf8.encode(safeName)),
      'fileNameEncoding': 'base64',
      'md5': md5.toLowerCase(),
      if (dataB64 != null) ...{'encoding': 'base64', 'data': dataB64},
      if (chunked) 'transferEncoding': 'chunks',
    });
  }

  static NetplayMessage romEnd() =>
      const NetplayMessage(NetplayMessageType.romEnd);

  static NetplayMessage romChunk({
    required int offset,
    required Uint8List bytes,
  }) => NetplayMessage(NetplayMessageType.romChunk, {
    'offset': offset,
    'data': base64Encode(bytes),
  });

  static NetplayMessage startGame({
    required String gameMd5,
    required String gameId,
    bool resume = false,
  }) => NetplayMessage(NetplayMessageType.startGame, {
    'gameMd5': gameMd5,
    'gameId': gameId,
    if (resume) 'resume': true,
  });

  static NetplayMessage leave() =>
      const NetplayMessage(NetplayMessageType.leave);

  static NetplayMessage ping(int sentAtMs) =>
      NetplayMessage(NetplayMessageType.ping, {'sentAt': sentAtMs});

  static NetplayMessage pong(int sentAtMs) =>
      NetplayMessage(NetplayMessageType.pong, {'sentAt': sentAtMs});

  static NetplayMessage lockstepReady({required double fps}) =>
      NetplayMessage(NetplayMessageType.lockstepReady, {'fps': fps});

  static NetplayMessage lockstepStart({
    required int frame,
    required double fps,
    required List<int> slots,
    int inputDelayFrames = kDefaultNetplayInputDelayFrames,
  }) => NetplayMessage(NetplayMessageType.lockstepStart, {
    'frame': frame,
    'fps': fps,
    'slots': slots,
    'inputDelay': inputDelayFrames,
  });

  static NetplayMessage lockstepStartAck() =>
      const NetplayMessage(NetplayMessageType.lockstepStartAck);

  static NetplayMessage frameInput({
    required int frame,
    required int slot,
    required int buttons,
  }) => NetplayMessage(NetplayMessageType.frameInput, {
    'frame': frame,
    'slot': slot,
    'buttons': buttons,
  });

  static NetplayMessage frameBundle({
    required int frame,
    required Map<int, int> inputs,
  }) => NetplayMessage(NetplayMessageType.frameBundle, {
    'frame': frame,
    'inputs': inputs.map((slot, mask) => MapEntry('$slot', mask)),
  });

  static NetplayMessage saveStateBegin({
    required int size,
    String purpose = 'initial',
    int? frame,
  }) {
    final payload = <String, dynamic>{'size': size, 'purpose': purpose};
    if (frame != null) {
      payload['frame'] = frame;
    }
    return NetplayMessage(NetplayMessageType.saveStateBegin, payload);
  }

  static NetplayMessage saveStateEnd() =>
      const NetplayMessage(NetplayMessageType.saveStateEnd);

  static NetplayMessage gameExit() =>
      const NetplayMessage(NetplayMessageType.gameExit);

  static NetplayMessage hostPromote({
    required Map<String, dynamic> room,
    required String playerName,
    int gameSpeed = 1,
    Map<String, dynamic>? internetDirectInvite,
    String? targetPlayerId,
  }) => NetplayMessage(NetplayMessageType.hostPromote, {
    'room': room,
    'playerName': playerName,
    'gameSpeed': gameSpeed.clamp(1, 3),
    if (targetPlayerId != null && targetPlayerId.isNotEmpty)
      'targetPlayerId': targetPlayerId,
    // ignore: use_null_aware_elements
    if (internetDirectInvite != null)
      'internetDirectInvite': internetDirectInvite,
  });

  static NetplayMessage gameSpeed({required int speed}) => NetplayMessage(
    NetplayMessageType.gameSpeed,
    {'speed': speed.clamp(1, 3)},
  );

  static NetplayMessage gbaNetpacket({
    required int sourceClientId,
    required int targetClientId,
    required int flags,
    required Uint8List bytes,
  }) => NetplayMessage(NetplayMessageType.gbaNetpacket, {
    'sourceClientId': sourceClientId.clamp(0, 0xFFFF),
    'targetClientId': targetClientId.clamp(0, 0xFFFF),
    'flags': flags,
    'data': base64Encode(bytes),
  });

  static NetplayMessage romProgress({required int received}) =>
      NetplayMessage(NetplayMessageType.romProgress, {'received': received});

  static NetplayMessage latencyReport({required int latency}) => NetplayMessage(
    NetplayMessageType.latencyReport,
    {'latency': latency.clamp(0, 60000)},
  );
}

class NetplayLineCodec {
  static Uint8List encode(NetplayMessage message) {
    return Uint8List.fromList(utf8.encode('${jsonEncode(message.toJson())}\n'));
  }

  static NetplayMessage? tryDecodeLine(String line) {
    final trimmed = line.trim();
    if (trimmed.isEmpty || !trimmed.startsWith('{')) {
      return null;
    }
    try {
      final decoded = jsonDecode(trimmed);
      if (decoded is! Map) {
        return null;
      }
      return NetplayMessage.fromJson(Map<String, dynamic>.from(decoded));
    } catch (_) {
      return null;
    }
  }
}

/// Wire-safe helpers for netplay payloads.
abstract final class NetplayWire {
  /// Strip path separators and non-printable chars from ROM file names.
  static String safeFileName(String fileName) {
    final base = fileName.split(RegExp(r'[/\\]')).last;
    return base.replaceAll(RegExp(r'[\x00-\x1f\x7f<>"|?*:]'), '_').trim();
  }

  static String decodeRomFileName(Map<String, dynamic> payload) {
    final encoding = payload['fileNameEncoding'] as String?;
    final raw = payload['fileName'] as String? ?? 'game.nes';
    if (encoding == 'base64') {
      try {
        return utf8.decode(base64Decode(raw));
      } catch (_) {
        return safeFileName(raw);
      }
    }
    return safeFileName(raw);
  }

  /// ROM payload is embedded as base64 in ROM_BEGIN (no trailing binary).
  static bool hasInlineRomData(Map<String, dynamic> payload) {
    final data = payload['data'];
    return data is String && data.isNotEmpty;
  }

  static bool isChunkedRomTransfer(Map<String, dynamic> payload) {
    return payload['transferEncoding'] == 'chunks';
  }
}

/// Parses newline JSON control messages and fixed-size ROM binary payloads.
class NetplayStreamParser {
  final List<int> _buffer = [];
  bool _receivingRom = false;
  bool get isReceivingBinary => _receivingRom || _receivingSaveState;
  int _romBytesRemaining = 0;
  NetplayMessage? _activeRomBegin;
  final BytesBuilder _romBuffer = BytesBuilder(copy: false);

  bool _receivingSaveState = false;
  int _saveStateBytesRemaining = 0;
  NetplayMessage? _activeSaveStateBegin;
  final BytesBuilder _saveStateBuffer = BytesBuilder(copy: false);

  void feed(
    Uint8List chunk, {
    required void Function(NetplayMessage message) onMessage,
    required void Function(Uint8List bytes, NetplayMessage beginMeta)
    onRomComplete,
    void Function(int received, int total, NetplayMessage beginMeta)?
    onRomProgress,
    void Function(Uint8List bytes, NetplayMessage beginMeta)?
    onSaveStateComplete,
  }) {
    _buffer.addAll(chunk);
    while (_buffer.isNotEmpty) {
      if (_receivingSaveState) {
        final take = min(_buffer.length, _saveStateBytesRemaining);
        _saveStateBuffer.add(_buffer.sublist(0, take));
        _buffer.removeRange(0, take);
        _saveStateBytesRemaining -= take;
        if (_saveStateBytesRemaining == 0) {
          _receivingSaveState = false;
          final meta = _activeSaveStateBegin;
          _activeSaveStateBegin = null;
          if (meta != null) {
            onSaveStateComplete?.call(_saveStateBuffer.takeBytes(), meta);
          }
        }
        continue;
      }

      if (_receivingRom) {
        final take = min(_buffer.length, _romBytesRemaining);
        _romBuffer.add(_buffer.sublist(0, take));
        _buffer.removeRange(0, take);
        _romBytesRemaining -= take;
        final meta = _activeRomBegin;
        if (meta != null) {
          final total = (meta.payload['size'] as num?)?.toInt() ?? 0;
          if (total > 0) {
            onRomProgress?.call(total - _romBytesRemaining, total, meta);
          }
        }
        if (_romBytesRemaining == 0) {
          _receivingRom = false;
          _activeRomBegin = null;
          if (meta != null) {
            onRomComplete(_romBuffer.takeBytes(), meta);
          }
        }
        continue;
      }

      final newlineIndex = _buffer.indexOf(10);
      if (newlineIndex < 0) {
        break;
      }

      final lineBytes = _buffer.sublist(0, newlineIndex);
      _buffer.removeRange(0, newlineIndex + 1);

      // Control messages are JSON objects; binary payloads may contain 0x0A.
      if (lineBytes.isEmpty || lineBytes.first != 0x7b) {
        continue;
      }

      late final String line;
      try {
        line = utf8.decode(lineBytes);
      } catch (_) {
        continue;
      }

      final message = NetplayLineCodec.tryDecodeLine(line);
      if (message == null) {
        continue;
      }

      if (message.type == NetplayMessageType.romBegin) {
        if (!NetplayWire.hasInlineRomData(message.payload) &&
            !NetplayWire.isChunkedRomTransfer(message.payload)) {
          _receivingRom = true;
          _activeRomBegin = message;
          _romBytesRemaining = (message.payload['size'] as num?)?.toInt() ?? 0;
          _romBuffer.clear();
        }
        onMessage(message);
        continue;
      }

      if (message.type == NetplayMessageType.saveStateBegin) {
        _receivingSaveState = true;
        _activeSaveStateBegin = message;
        _saveStateBytesRemaining =
            (message.payload['size'] as num?)?.toInt() ?? 0;
        _saveStateBuffer.clear();
      }

      onMessage(message);
    }
  }

  void reset() {
    _buffer.clear();
    _romBuffer.clear();
    _saveStateBuffer.clear();
    _receivingRom = false;
    _receivingSaveState = false;
    _romBytesRemaining = 0;
    _saveStateBytesRemaining = 0;
    _activeRomBegin = null;
    _activeSaveStateBegin = null;
  }
}

abstract final class NetplayRomTransfer {
  static const chunkSize = 32 * 1024;
}
