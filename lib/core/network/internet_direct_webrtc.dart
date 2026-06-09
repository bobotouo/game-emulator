import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

enum InternetDirectIcePhase { turn }

class InternetDirectStats {
  const InternetDirectStats({
    this.rttMs,
    this.localCandidateType,
    this.remoteCandidateType,
  });

  final int? rttMs;
  final String? localCandidateType;
  final String? remoteCandidateType;

  @override
  String toString() =>
      'rtt=${rttMs ?? 0}ms local=${localCandidateType ?? '-'} '
      'remote=${remoteCandidateType ?? '-'}';
}

abstract final class InternetDirectWebRtc {
  static const dataChannelLabel = 'retro-netplay';
  static const realtimeDataChannelLabel = 'retro-netplay-rt';
  static const _connectTimeout = Duration(seconds: 15);
  static const _operationTimeout = Duration(seconds: 8);
  static const _gatherTimeout = Duration(seconds: 4);

  static Map<String, dynamic> iceConfig({
    required List<Map<String, dynamic>> iceServers,
  }) {
    return {
      'sdpSemantics': 'unified-plan',
      'iceServers': iceServers,
      'iceCandidatePoolSize': 8,
    };
  }

  static Future<RTCPeerConnection> createConnection({
    required List<Map<String, dynamic>> iceServers,
  }) {
    return createPeerConnection(iceConfig(iceServers: iceServers));
  }

  static Future<String> waitGatheringAndGetLocalSdp(
    RTCPeerConnection pc,
  ) async {
    if (pc.iceGatheringState ==
        RTCIceGatheringState.RTCIceGatheringStateComplete) {
      return (await pc.getLocalDescription())!.sdp!;
    }
    final completer = Completer<void>();
    pc.onIceGatheringState = (state) {
      if (state == RTCIceGatheringState.RTCIceGatheringStateComplete &&
          !completer.isCompleted) {
        completer.complete();
      }
    };
    try {
      await completer.future.timeout(_gatherTimeout);
    } on TimeoutException {
      debugPrint('[InternetDirect/WebRTC] ICE gathering timeout');
    }
    return (await pc.getLocalDescription())?.sdp ?? '';
  }

  static Future<bool> waitConnected(
    RTCPeerConnection pc, {
    Duration timeout = _connectTimeout,
  }) async {
    if (pc.iceConnectionState ==
            RTCIceConnectionState.RTCIceConnectionStateConnected ||
        pc.iceConnectionState ==
            RTCIceConnectionState.RTCIceConnectionStateCompleted) {
      return true;
    }
    final completer = Completer<bool>();
    pc.onIceConnectionState = (state) {
      if (completer.isCompleted) {
        return;
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        completer.complete(true);
      } else if (state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        completer.complete(false);
      }
    };
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      return false;
    }
  }

  static Future<void> closePeerConnection(RTCPeerConnection? pc) async {
    if (pc == null) {
      return;
    }
    try {
      await pc.close();
    } catch (_) {}
  }

  static Future<InternetDirectStats?> getSelectedStats(
    RTCPeerConnection? pc,
  ) async {
    if (pc == null) {
      return null;
    }
    try {
      final reports = await pc.getStats().timeout(_operationTimeout);
      StatsReport? selectedPair;
      for (final report in reports) {
        if (report.type != 'candidate-pair') {
          continue;
        }
        final values = report.values;
        final selected =
            values['selected'] == true ||
            values['nominated'] == true ||
            values['state'] == 'succeeded';
        if (selected) {
          selectedPair = report;
          if (values['selected'] == true) {
            break;
          }
        }
      }
      if (selectedPair == null) {
        return null;
      }
      final pairValues = selectedPair.values;
      final rttSeconds =
          _asDouble(pairValues['currentRoundTripTime']) ??
          _asDouble(pairValues['totalRoundTripTime']);
      final localId =
          pairValues['localCandidateId']?.toString() ??
          pairValues['localCandidateId']?.toString();
      final remoteId =
          pairValues['remoteCandidateId']?.toString() ??
          pairValues['remoteCandidateId']?.toString();
      String? candidateType(String? id) {
        if (id == null || id.isEmpty) {
          return null;
        }
        for (final report in reports) {
          if (report.id == id) {
            return report.values['candidateType']?.toString();
          }
        }
        return null;
      }

      return InternetDirectStats(
        rttMs: rttSeconds == null ? null : (rttSeconds * 1000).round(),
        localCandidateType: candidateType(localId),
        remoteCandidateType: candidateType(remoteId),
      );
    } catch (_) {
      return null;
    }
  }

  static double? _asDouble(Object? value) {
    if (value is num) {
      return value.toDouble();
    }
    if (value is String) {
      return double.tryParse(value);
    }
    return null;
  }
}

class InternetDirectWebRtcHost {
  InternetDirectWebRtcHost({required this.iceServers, required this.onLog});

  final List<Map<String, dynamic>> iceServers;
  final void Function(String message) onLog;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  RTCDataChannel? _realtimeDataChannel;
  final _dataController = StreamController<Uint8List>.broadcast();
  final _realtimeDataController = StreamController<Uint8List>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  bool _disposed = false;

  Stream<Uint8List> get onData => _dataController.stream;
  Stream<Uint8List> get onRealtimeData => _realtimeDataController.stream;
  Stream<bool> get onConnected => _connectedController.stream;
  int get bufferedAmount => _dataChannel?.bufferedAmount ?? 0;
  Future<InternetDirectStats?> getStats() =>
      InternetDirectWebRtc.getSelectedStats(_peerConnection);

  Future<String> createOffer() async {
    await _disposePeerConnection();
    _peerConnection = await InternetDirectWebRtc.createConnection(
      iceServers: iceServers,
    ).timeout(InternetDirectWebRtc._operationTimeout);
    final pc = _peerConnection!;
    _attachPeerConnectionCallbacks(pc);
    final channel = await pc
        .createDataChannel(
          InternetDirectWebRtc.dataChannelLabel,
          RTCDataChannelInit()
            ..ordered = true
            ..binaryType = 'arraybuffer',
        )
        .timeout(InternetDirectWebRtc._operationTimeout);
    _attachDataChannel(channel);
    final realtimeChannel = await pc
        .createDataChannel(
          InternetDirectWebRtc.realtimeDataChannelLabel,
          RTCDataChannelInit()
            ..ordered = false
            ..maxRetransmits = 0
            ..binaryType = 'arraybuffer',
        )
        .timeout(InternetDirectWebRtc._operationTimeout);
    _attachRealtimeDataChannel(realtimeChannel);
    final offer = await pc
        .createOffer({
          'offerToReceiveAudio': false,
          'offerToReceiveVideo': false,
        })
        .timeout(InternetDirectWebRtc._operationTimeout);
    await pc
        .setLocalDescription(offer)
        .timeout(InternetDirectWebRtc._operationTimeout);
    return InternetDirectWebRtc.waitGatheringAndGetLocalSdp(pc);
  }

  Future<bool> applyAnswer(String answerSdp) async {
    final pc = _peerConnection;
    if (pc == null || answerSdp.isEmpty) {
      return false;
    }
    await pc.setRemoteDescription(RTCSessionDescription(answerSdp, 'answer'));
    final ok = await InternetDirectWebRtc.waitConnected(pc);
    onLog('webrtc host connected=$ok');
    if (ok) {
      _connectedController.add(true);
    }
    return ok;
  }

  void _attachPeerConnectionCallbacks(RTCPeerConnection pc) {
    pc.onIceConnectionState = (state) {
      onLog('webrtc host iceState=$state');
      if (state == RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _connectedController.add(false);
      }
    };
  }

  void _attachDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onMessage = (message) {
      if (!_disposed && message.isBinary) {
        _dataController.add(Uint8List.fromList(message.binary));
      }
    };
    channel.onDataChannelState = (state) {
      if (_disposed) {
        return;
      }
      onLog('webrtc host dcState=$state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _connectedController.add(true);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
          state == RTCDataChannelState.RTCDataChannelClosing) {
        _connectedController.add(false);
      }
    };
  }

  void _attachRealtimeDataChannel(RTCDataChannel channel) {
    _realtimeDataChannel = channel;
    channel.onMessage = (message) {
      if (!_disposed && message.isBinary) {
        _realtimeDataController.add(Uint8List.fromList(message.binary));
      }
    };
    channel.onDataChannelState = (state) {
      if (_disposed) {
        return;
      }
      onLog('webrtc host rtDcState=$state');
    };
  }

  bool send(List<int> bytes) {
    final channel = _dataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    try {
      channel.send(
        RTCDataChannelMessage.fromBinary(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        ),
      );
      return true;
    } catch (e) {
      onLog('webrtc host send failed: $e');
      return false;
    }
  }

  bool sendRealtime(List<int> bytes) {
    final channel = _realtimeDataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return send(bytes);
    }
    try {
      channel.send(
        RTCDataChannelMessage.fromBinary(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        ),
      );
      return true;
    } catch (e) {
      onLog('webrtc host rt send failed: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await _disposePeerConnection();
    await _dataController.close();
    await _realtimeDataController.close();
    await _connectedController.close();
  }

  Future<void> _disposePeerConnection() async {
    _dataChannel = null;
    _realtimeDataChannel = null;
    await InternetDirectWebRtc.closePeerConnection(_peerConnection);
    _peerConnection = null;
  }
}

class InternetDirectWebRtcGuest {
  InternetDirectWebRtcGuest({required this.iceServers, required this.onLog});

  final List<Map<String, dynamic>> iceServers;
  final void Function(String message) onLog;

  RTCPeerConnection? _peerConnection;
  RTCDataChannel? _dataChannel;
  RTCDataChannel? _realtimeDataChannel;
  final _dataController = StreamController<Uint8List>.broadcast();
  final _realtimeDataController = StreamController<Uint8List>.broadcast();
  final _connectedController = StreamController<bool>.broadcast();
  bool _disposed = false;

  Stream<Uint8List> get onData => _dataController.stream;
  Stream<Uint8List> get onRealtimeData => _realtimeDataController.stream;
  Stream<bool> get onConnected => _connectedController.stream;
  int get bufferedAmount => _dataChannel?.bufferedAmount ?? 0;
  Future<InternetDirectStats?> getStats() =>
      InternetDirectWebRtc.getSelectedStats(_peerConnection);

  Future<bool> connect({
    required String offerSdp,
    required Future<void> Function(String answerSdp) submitAnswer,
  }) async {
    await InternetDirectWebRtc.closePeerConnection(_peerConnection);
    _dataChannel?.close();
    _dataChannel = null;
    _realtimeDataChannel?.close();
    _realtimeDataChannel = null;

    _peerConnection = await InternetDirectWebRtc.createConnection(
      iceServers: iceServers,
    ).timeout(InternetDirectWebRtc._operationTimeout);
    final pc = _peerConnection!;
    final dataChannelOpen = Completer<void>();
    final realtimeDataChannelOpen = Completer<void>();
    pc.onDataChannel = (channel) {
      if (channel.label == InternetDirectWebRtc.realtimeDataChannelLabel) {
        _attachRealtimeDataChannel(
          channel,
          onOpen: () {
            if (!realtimeDataChannelOpen.isCompleted) {
              realtimeDataChannelOpen.complete();
            }
          },
        );
        if (channel.state == RTCDataChannelState.RTCDataChannelOpen &&
            !realtimeDataChannelOpen.isCompleted) {
          realtimeDataChannelOpen.complete();
        }
      } else {
        _attachDataChannel(channel);
      }
      if (channel.state == RTCDataChannelState.RTCDataChannelOpen &&
          !dataChannelOpen.isCompleted) {
        dataChannelOpen.complete();
      }
    };
    pc.onIceConnectionState = (state) {
      onLog('webrtc guest iceState=$state');
      if (_disposed) {
        return;
      }
      if (state == RTCIceConnectionState.RTCIceConnectionStateConnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateCompleted) {
        _connectedController.add(true);
      } else if (state ==
              RTCIceConnectionState.RTCIceConnectionStateDisconnected ||
          state == RTCIceConnectionState.RTCIceConnectionStateFailed ||
          state == RTCIceConnectionState.RTCIceConnectionStateClosed) {
        _connectedController.add(false);
      }
    };

    await pc
        .setRemoteDescription(RTCSessionDescription(offerSdp, 'offer'))
        .timeout(InternetDirectWebRtc._operationTimeout);
    final answer = await pc
        .createAnswer({
          'offerToReceiveAudio': false,
          'offerToReceiveVideo': false,
        })
        .timeout(InternetDirectWebRtc._operationTimeout);
    await pc
        .setLocalDescription(answer)
        .timeout(InternetDirectWebRtc._operationTimeout);
    final answerSdp = await InternetDirectWebRtc.waitGatheringAndGetLocalSdp(
      pc,
    );
    await submitAnswer(answerSdp);

    final iceOk = await InternetDirectWebRtc.waitConnected(pc);
    if (!iceOk) {
      return false;
    }
    try {
      await dataChannelOpen.future.timeout(const Duration(seconds: 3));
      try {
        await realtimeDataChannelOpen.future.timeout(
          const Duration(seconds: 1),
        );
      } on TimeoutException {
        onLog('webrtc guest rtDc open timeout');
      }
      return true;
    } on TimeoutException {
      return _dataChannel?.state == RTCDataChannelState.RTCDataChannelOpen;
    }
  }

  void _attachDataChannel(RTCDataChannel channel) {
    _dataChannel = channel;
    channel.onMessage = (message) {
      if (!_disposed && message.isBinary) {
        _dataController.add(Uint8List.fromList(message.binary));
      }
    };
    channel.onDataChannelState = (state) {
      if (_disposed) {
        return;
      }
      onLog('webrtc guest dcState=$state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        _connectedController.add(true);
      } else if (state == RTCDataChannelState.RTCDataChannelClosed ||
          state == RTCDataChannelState.RTCDataChannelClosing) {
        _connectedController.add(false);
      }
    };
  }

  void _attachRealtimeDataChannel(
    RTCDataChannel channel, {
    VoidCallback? onOpen,
  }) {
    _realtimeDataChannel = channel;
    channel.onMessage = (message) {
      if (!_disposed && message.isBinary) {
        _realtimeDataController.add(Uint8List.fromList(message.binary));
      }
    };
    channel.onDataChannelState = (state) {
      if (_disposed) {
        return;
      }
      onLog('webrtc guest rtDcState=$state');
      if (state == RTCDataChannelState.RTCDataChannelOpen) {
        onOpen?.call();
      }
    };
  }

  bool send(List<int> bytes) {
    final channel = _dataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return false;
    }
    try {
      channel.send(
        RTCDataChannelMessage.fromBinary(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        ),
      );
      return true;
    } catch (e) {
      onLog('webrtc guest send failed: $e');
      return false;
    }
  }

  bool sendRealtime(List<int> bytes) {
    final channel = _realtimeDataChannel;
    if (channel == null ||
        channel.state != RTCDataChannelState.RTCDataChannelOpen) {
      return send(bytes);
    }
    try {
      channel.send(
        RTCDataChannelMessage.fromBinary(
          bytes is Uint8List ? bytes : Uint8List.fromList(bytes),
        ),
      );
      return true;
    } catch (e) {
      onLog('webrtc guest rt send failed: $e');
      return false;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _dataChannel = null;
    _realtimeDataChannel = null;
    await InternetDirectWebRtc.closePeerConnection(_peerConnection);
    _peerConnection = null;
    await _dataController.close();
    await _realtimeDataController.close();
    await _connectedController.close();
  }
}
