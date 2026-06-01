import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';

import '../settings/app_settings_service.dart';
import 'lan_multicast_lock.dart';
import 'lan_network_checker.dart';
import '../emulator_loop/emulator_loop_ffi.dart' as emu_loop;
import 'netplay_lockstep.dart';
import 'netplay_protocol.dart';
import 'netplay_room_state.dart';
import 'netplay_status.dart';
import 'player_info.dart';
import 'room_info.dart';

/// Local LAN netplay: mDNS/UDP discovery, TCP signaling, chunked ROM transfer.
class NetplayService {
  static const serviceType = '_retro-netplay._tcp';
  static const udpMagic = 'RETRO_NETPLAY:v1:';
  static const udpDiscover = 'RETRO_NETPLAY_DISCOVER';

  ServerSocket? _server;
  Socket? _clientSocket;
  final Map<String, _PeerConnection> _peers = {};
  int _peerIdSeq = 0;

  RawDatagramSocket? _udpSocket;
  RawDatagramSocket? _udpResponderSocket;
  Timer? _udpAnnounceTimer;
  Timer? _udpDiscoverTimer;
  Timer? _mdnsScanTimer;

  MDnsClient? _mdnsClient;
  /// mDNS browse is off until we also publish room services via Bonjour.
  bool _mdnsEnabled = false;
  String? _cachedLocalIp;
  String? _cachedBroadcastIp;
  NetplayStatus _status = NetplayStatus.none;
  RoomInfo? _hostedRoom;
  RoomInfo? _joinedRoom;
  NetplayRoomState? _roomState;
  String? _localPlayerName;
  String? _localPlayerId;
  int _localPlayerSlot = 0;

  bool _isHost = false;
  int _port = 7845;
  int _discoveryPort = 7846;
  int _discoveryEpoch = 0;
  final Map<String, int> _recentRoomEmitMs = {};

  NetplayMessage? _pendingRomBegin;
  bool _sendingRom = false;

  NetplayLockstepRunner? _lockstepRunner;
  Set<int> _lockstepRequiredSlots = {1};
  final Set<String> _lockstepReadyPeers = {};
  double _lockstepFps = 60.0;
  bool _awaitingReplacement = false;
  bool _exitingForReplacement = false;
  bool _deferGameExitToRoomScreen = false;
  bool _hostPromotionPending = false;
  bool _hostPromotionExit = false;
  Uint8List? _stashedResumeSaveState;
  Uint8List? _receivedResumeSaveState;
  final _lockstepStartController =
      StreamController<LockstepStartConfig>.broadcast();
  final _gameplayPeerLeftController = StreamController<void>.broadcast();
  final _saveStateReceivedController =
      StreamController<Uint8List>.broadcast();
  final _playerSlotAssignedController = StreamController<int>.broadcast();
  final _hostPromotedController = StreamController<RoomInfo>.broadcast();
  final _gameSpeedController = StreamController<int>.broadcast();

  int _gameSpeed = 1;

  final _statusController = StreamController<NetplayStatus>.broadcast();
  final _roomFoundController = StreamController<RoomInfo>.broadcast();
  final _playerJoinedController = StreamController<PlayerInfo>.broadcast();
  final _playerUpdatedController = StreamController<PlayerInfo>.broadcast();
  final _playerLeftController = StreamController<String>.broadcast();
  final _messageController = StreamController<NetplayMessage>.broadcast();
  final _romProgressController = StreamController<RomTransferProgress>.broadcast();
  final _startGameController = StreamController<NetplayStartGameEvent>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  final _roomStateController = StreamController<NetplayRoomState>.broadcast();

  NetplayService() {
    _port = AppSettingsService.instance.networkPort;
    _discoveryPort = _port + 1;
  }

  Stream<NetplayStatus> get onStatusChanged => _statusController.stream;
  Stream<RoomInfo> get onRoomFound => _roomFoundController.stream;
  Stream<PlayerInfo> get onPlayerJoined => _playerJoinedController.stream;
  Stream<PlayerInfo> get onPlayerUpdated => _playerUpdatedController.stream;
  Stream<String> get onPlayerLeft => _playerLeftController.stream;
  Stream<NetplayMessage> get onMessage => _messageController.stream;
  Stream<RomTransferProgress> get onRomProgress => _romProgressController.stream;
  Stream<NetplayStartGameEvent> get onStartGame => _startGameController.stream;
  Stream<bool> get onConnectionStateChanged => _connectionStateController.stream;
  Stream<NetplayRoomState> get onRoomStateChanged => _roomStateController.stream;
  Stream<LockstepStartConfig> get onLockstepStart =>
      _lockstepStartController.stream;
  Stream<void> get onGameplayPeerLeft => _gameplayPeerLeftController.stream;
  Stream<Uint8List> get onSaveStateReceived =>
      _saveStateReceivedController.stream;
  Stream<int> get onPlayerSlotAssigned =>
      _playerSlotAssignedController.stream;
  Stream<RoomInfo> get onHostPromoted => _hostPromotedController.stream;
  Stream<int> get onGameSpeedChanged => _gameSpeedController.stream;
  int get gameSpeed => _gameSpeed;

  bool get isPlayableParticipant => _isHost || _localPlayerSlot > 0;

  NetplayLockstepRunner? get lockstepRunner => _lockstepRunner;
  bool get awaitingReplacement => _awaitingReplacement;
  bool get isHostPromotionPending => _hostPromotionPending;
  Uint8List? takeResumeSaveState() {
    final state = _stashedResumeSaveState ?? _receivedResumeSaveState;
    _stashedResumeSaveState = null;
    _receivedResumeSaveState = null;
    return state;
  }

  NetplayStatus get status => _status;
  bool get isHost => _isHost;
  NetplayRoomState? get roomState => _roomState;
  int get localPlayerSlot => _localPlayerSlot;
  String? get localPlayerId => _localPlayerId;
  bool get isConnected =>
      _status == NetplayStatus.inLobby ||
      _status == NetplayStatus.transferringRom ||
      _status == NetplayStatus.gaming;
  RoomInfo? get hostedRoom => _hostedRoom;
  RoomInfo? get joinedRoom => _joinedRoom;
  RoomInfo? get activeRoom => _hostedRoom ?? _joinedRoom;
  String? get roomCode => activeRoom?.roomId;
  String? get hostIp => _isHost ? _hostedRoom?.hostIp : _joinedRoom?.hostIp;
  int get port => _port;
  bool get isDiscoverySocketReady => _udpSocket != null;
  bool get isHostingUdpReady => _udpResponderSocket != null;
  List<Socket> get clients => _peers.values.map((peer) => peer.socket).toList();

  /// First guest peer that has been assigned a player slot (for ROM transfer, etc.).
  String? get firstPlayablePeerId {
    for (final peer in _peers.values) {
      if (peer.playerSlot > 0) {
        return peer.id;
      }
    }
    return null;
  }

  /// Move from hosting broadcast into the staging room UI.
  void enterLobby() {
    if (_isHost &&
        (_status == NetplayStatus.hosting || _status == NetplayStatus.none)) {
      _setStatus(NetplayStatus.inLobby);
    }
  }

  /// Backward-compatible alias for older screens.
  Stream<NetworkData> get onDataReceived => const Stream.empty();

  void sendData(Uint8List data) {
    if (_isHost) {
      for (final peer in _peers.values) {
        peer.socket.add(data);
      }
    } else {
      _clientSocket?.add(data);
    }
  }

  Future<String?> getLocalIp() async {
    final snapshot = await LanNetworkChecker.evaluate();
    return snapshot.localIp;
  }

  /// Sends an extra LAN discovery pulse (UDP broadcast).
  void pulseDiscovery() {
    if (_status != NetplayStatus.searching) {
      return;
    }
    unawaited(_pulseUdpDiscoveryAsync());
    if (_mdnsEnabled) {
      unawaited(_scanMdns());
    }
  }

  static Future<String> defaultRoomName() async {
    final host = Platform.localHostname;
    if (host.isNotEmpty && host != 'localhost') {
      return '$host的房间';
    }
    return '联机房间';
  }

  Future<bool> createRoom({
    required RoomInfo roomTemplate,
    String? playerName,
  }) async {
    await _resetConnections(keepDiscovery: false);
    _isHost = true;
    _localPlayerName = playerName ?? 'Player 1';
    _localPlayerSlot = 1;
    _localPlayerId = null;
    final hostIp = await getLocalIp() ?? '0.0.0.0';
    await _refreshNetworkTargets(hostIp);

    try {
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      _server!.listen(_onIncomingClient);

      _hostedRoom = roomTemplate.copyWith(
        hostIp: hostIp == '0.0.0.0' ? (_cachedLocalIp ?? hostIp) : hostIp,
        port: _port,
        currentPlayers: 1,
      );
      _joinedRoom = null;
      _localPlayerId = _hostedRoom!.hostIp;
      _applyRoomState(_buildRoomState());

      await _startUdpResponder();
      _startUdpAnnounce();
      await LanMulticastLock.acquire();
      _setStatus(NetplayStatus.hosting);
      _connectionStateController.add(true);
      return true;
    } catch (e) {
      await _resetConnections();
      return false;
    }
  }

  Future<bool> joinRoom(
    RoomInfo room, {
    String? playerName,
  }) async {
    await _resetConnections(keepDiscovery: false);
    _isHost = false;
    _localPlayerName = playerName ?? 'Player 2';
    _localPlayerSlot = 0;
    _localPlayerId = null;
    _joinedRoom = room;
    _hostedRoom = null;

    if (room.isFull) {
      await _resetConnections();
      return false;
    }

    try {
      final stopwatch = Stopwatch()..start();
      _clientSocket = await Socket.connect(room.hostIp, room.port);
      stopwatch.stop();
      _joinedRoom = room.copyWith(pingMs: stopwatch.elapsedMilliseconds);

      final peer = _PeerConnection(
        id: room.hostIp,
        socket: _clientSocket!,
        parser: NetplayStreamParser(),
      );
      _peers[peer.id] = peer;
      _clientSocket!.listen(
        (data) => _handlePeerData(peer, data),
        onDone: () => _handlePeerClosed(peer.id),
        onError: (_) => _handlePeerClosed(peer.id),
      );

      _sendToPeer(
        peer.id,
        NetplayMessage.join(playerName: _localPlayerName!),
      );
      _sendToHost(NetplayMessage.ping(DateTime.now().millisecondsSinceEpoch));
      _setStatus(NetplayStatus.inLobby);
      _connectionStateController.add(true);
      return true;
    } catch (e) {
      await _resetConnections();
      return false;
    }
  }

  void startDiscovery() {
    _setStatus(NetplayStatus.searching);
    unawaited(_startUdpDiscoveryListener());
    unawaited(LanMulticastLock.acquire());
    if (_mdnsEnabled) {
      _mdnsScanTimer?.cancel();
      _mdnsScanTimer = Timer.periodic(const Duration(seconds: 3), (_) {
        unawaited(_scanMdns());
      });
      unawaited(_scanMdns());
    }
  }

  void stopDiscovery() {
    _discoveryEpoch++;
    if (_status == NetplayStatus.searching) {
      _setStatus(NetplayStatus.none);
    }
    _mdnsScanTimer?.cancel();
    _mdnsScanTimer = null;
    _udpDiscoverTimer?.cancel();
    _udpDiscoverTimer = null;
    _mdnsClient?.stop();
    _mdnsClient = null;
    _udpSocket?.close();
    _udpSocket = null;
    _recentRoomEmitMs.clear();
    unawaited(LanMulticastLock.release());
  }

  void _closeUdpResponder() {
    _udpResponderSocket?.close();
    _udpResponderSocket = null;
  }

  Future<void> _refreshNetworkTargets([String? localIp]) async {
    _cachedLocalIp = localIp ?? await getLocalIp();
    _cachedBroadcastIp = _subnetBroadcast(_cachedLocalIp);
  }

  String? _subnetBroadcast(String? ip) {
    if (ip == null || ip == '0.0.0.0') {
      return null;
    }
    final parts = ip.split('.');
    if (parts.length != 4) {
      return null;
    }
    return '${parts[0]}.${parts[1]}.${parts[2]}.255';
  }

  bool get _hasDiscoveryNetwork {
    final ip = _cachedLocalIp;
    final broadcast = _cachedBroadcastIp;
    return ip != null &&
        ip.isNotEmpty &&
        ip != '0.0.0.0' &&
        broadcast != null &&
        broadcast.isNotEmpty;
  }

  bool _isValidDiscoveryTarget(InternetAddress address) {
    if (address.isLoopback) {
      return false;
    }
    if (address.type != InternetAddressType.IPv4) {
      return false;
    }
    final raw = address.rawAddress;
    if (raw.length == 4 && raw.every((octet) => octet == 0)) {
      return false;
    }
    return true;
  }

  List<InternetAddress> _discoveryBroadcastTargets() {
    final targets = <InternetAddress>[];
    void addHost(String? host) {
      if (host == null || host.isEmpty || host == '0.0.0.0') {
        return;
      }
      final addr = InternetAddress.tryParse(host);
      if (addr == null || !_isValidDiscoveryTarget(addr)) {
        return;
      }
      if (targets.any((existing) => existing.address == addr.address)) {
        return;
      }
      targets.add(addr);
    }

    addHost(_cachedBroadcastIp);
    // iOS/macOS global broadcast often triggers EHOSTUNREACH — use subnet only.
    if (!Platform.isIOS && !Platform.isMacOS) {
      addHost('255.255.255.255');
    }
    return targets;
  }

  void _sendUdpDiscoveryPacket(RawDatagramSocket socket, Uint8List payload) {
    try {
      for (final target in _discoveryBroadcastTargets()) {
        _sendUdpTo(socket, payload, target);
      }
    } catch (_) {}
  }

  void _sendUdpTo(
    RawDatagramSocket socket,
    Uint8List payload,
    InternetAddress target,
  ) {
    if (!_isValidDiscoveryTarget(target)) {
      return;
    }
    if (_status != NetplayStatus.searching && socket == _udpSocket) {
      return;
    }
    try {
      socket.send(payload, target, _discoveryPort);
    } on Object {
      // Offline hosts / closed socket — ignore.
    }
  }

  Future<RawDatagramSocket?> _bindUdpSocket({required int port}) async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        port,
        reuseAddress: true,
      );
      socket.broadcastEnabled = true;
      return socket;
    } catch (_) {
      final localIp = _cachedLocalIp;
      if (localIp == null || localIp == '0.0.0.0') {
        return null;
      }
      try {
        final socket = await RawDatagramSocket.bind(
          InternetAddress(localIp),
          port,
          reuseAddress: true,
        );
        socket.broadcastEnabled = true;
        return socket;
      } catch (_) {
        return null;
      }
    }
  }

  void _pulseUdpDiscovery() {
    try {
      if (!_hasDiscoveryNetwork) {
        return;
      }
      final socket = _udpSocket;
      if (socket == null || _status != NetplayStatus.searching) {
        return;
      }
      _sendUdpDiscoveryPacket(
        socket,
        Uint8List.fromList(udpDiscover.codeUnits),
      );
    } on Object {
      // ignore
    }
  }

  Future<void> _pulseUdpDiscoveryAsync() async {
    final epoch = _discoveryEpoch;
    try {
      await _refreshNetworkTargets();
      if (epoch != _discoveryEpoch || _status != NetplayStatus.searching) {
        return;
      }
      _pulseUdpDiscovery();
    } on Object {
      // ignore
    }
  }

  String _roomDiscoveryKey(RoomInfo room) =>
      '${room.roomId}|${room.hostIp}|${room.port}';

  void _emitRoomFound(RoomInfo room) {
    if (room.roomId.isEmpty) {
      return;
    }
    final key = _roomDiscoveryKey(room);
    final now = DateTime.now().millisecondsSinceEpoch;
    final last = _recentRoomEmitMs[key];
    if (last != null && now - last < 800) {
      return;
    }
    _recentRoomEmitMs[key] = now;
    _roomFoundController.add(room);
  }

  void sendReady(bool ready) {
    _broadcast(NetplayMessage.ready(ready: ready));
  }

  void requestRom() {
    _broadcast(NetplayMessage.requestRom());
  }

  Future<void> sendRomFile({
    required String peerId,
    required String filePath,
    required String fileName,
  }) async {
    if (!_isHost || _sendingRom) {
      return;
    }

    var targetPeerId = peerId;
    if (_peers[targetPeerId] == null) {
      targetPeerId = firstPlayablePeerId ?? '';
    }
    if (targetPeerId.isEmpty || _peers[targetPeerId] == null) {
      return;
    }

    final file = File(filePath);
    if (!await file.exists()) {
      return;
    }

    final bytes = await file.readAsBytes();
    final fileMd5 = md5.convert(bytes).toString().toLowerCase();
    _sendingRom = true;
    _setStatus(NetplayStatus.transferringRom);

    final safeName = NetplayWire.safeFileName(fileName);
    // LAN ROMs are small — send as base64 inside JSON to avoid binary/text mix-ups.
    _sendToPeer(
      targetPeerId,
      NetplayMessage.romBegin(
        size: bytes.length,
        fileName: safeName,
        md5: fileMd5,
        dataB64: base64Encode(bytes),
      ),
    );
    _romProgressController.add(
      RomTransferProgress(
        sent: bytes.length,
        total: bytes.length,
        isSending: true,
      ),
    );
    _sendToPeer(targetPeerId, NetplayMessage.romEnd());
    _sendingRom = false;
    if (_status == NetplayStatus.transferringRom) {
      _setStatus(NetplayStatus.inLobby);
    }
  }

  void startGame({required String gameMd5, required String gameId}) {
    if (!_isHost) {
      return;
    }

    if (_awaitingReplacement &&
        _stashedResumeSaveState != null &&
        _stashedResumeSaveState!.isNotEmpty) {
      for (final peer in _peers.values) {
        if (peer.playerSlot > 0) {
          unawaited(_resumeReplacementForPeer(peer.id));
          return;
        }
      }
    }

    if (_hostedRoom != null) {
      _hostedRoom = _hostedRoom!.copyWith(inGame: true, awaitingReplacement: false);
      _broadcastRoomState();
    }
    _broadcast(
      NetplayMessage.startGame(gameMd5: gameMd5, gameId: gameId),
    );
    _startGameController.add(
      NetplayStartGameEvent(gameMd5: gameMd5, gameId: gameId),
    );
    _setStatus(NetplayStatus.gaming);
    _broadcast(NetplayMessage.gameSpeed(speed: _gameSpeed));
  }

  bool _isResumeStartPayload(Map<String, dynamic> payload) {
    final resume = payload['resume'];
    return resume == true || resume == 'true' || resume == 1 || resume == '1';
  }

  /// 对局结束：恢复房间等待状态，更新 UDP 广播（inGame=false）。
  void endGame() {
    _stopLockstep();
    _awaitingReplacement = false;
    if (_isHost) {
      if (_hostedRoom == null) {
        return;
      }
      _hostedRoom = _hostedRoom!.copyWith(
        inGame: false,
        awaitingReplacement: false,
      );
      _setStatus(NetplayStatus.inLobby);
      emu_loop.clearInputs();
      _gameSpeed = 1;
      _broadcastRoomState();
      return;
    }
    if (_joinedRoom != null) {
      _joinedRoom = _joinedRoom!.copyWith(
        inGame: false,
        awaitingReplacement: false,
      );
    }
    if (_status == NetplayStatus.gaming) {
      _setStatus(NetplayStatus.inLobby);
    }
  }

  void markExitingForReplacement() {
    _exitingForReplacement = true;
  }

  void markDeferGameExitToRoomScreen() {
    _deferGameExitToRoomScreen = true;
  }

  bool consumeDeferGameExitToRoomScreen() {
    final value = _deferGameExitToRoomScreen;
    _deferGameExitToRoomScreen = false;
    return value;
  }

  void markHostPromotionExit() {
    _hostPromotionExit = true;
  }

  bool consumeExitingForReplacement() {
    final value = _exitingForReplacement;
    _exitingForReplacement = false;
    return value;
  }

  bool consumeHostPromotionExit() {
    final value = _hostPromotionExit;
    _hostPromotionExit = false;
    return value;
  }

  void stashResumeSaveState(Uint8List bytes) {
    if (bytes.isEmpty) {
      return;
    }
    _stashedResumeSaveState = Uint8List.fromList(bytes);
  }

  void setGameSpeed(int speed) {
    if (!_isHost) {
      return;
    }
    _publishGameSpeed(speed, broadcast: true);
  }

  void _publishGameSpeed(int speed, {required bool broadcast}) {
    final clamped = speed.clamp(1, 5);
    if (_gameSpeed == clamped) {
      return;
    }
    _gameSpeed = clamped;
    if (broadcast) {
      _broadcast(NetplayMessage.gameSpeed(speed: clamped));
    }
    _gameSpeedController.add(clamped);
  }

  void _applyRemoteGameSpeed(int speed) {
    if (_isHost) {
      return;
    }
    _publishGameSpeed(speed, broadcast: false);
  }

  /// Host left the game UI — hand off hosting if others remain, else disband.
  void exitGameAndHandoffHost() {
    if (!_isHost) {
      return;
    }

    _stopLockstep();

    final successor = _findHostSuccessor();
    if (successor != null) {
      if (_hostedRoom != null) {
        final resumePlay =
            _status == NetplayStatus.gaming ||
            _awaitingReplacement ||
            _hostedRoom!.inGame;
        _hostedRoom = _hostedRoom!.copyWith(
          inGame: resumePlay,
          awaitingReplacement: resumePlay,
        );
        _broadcastRoomState();
      }
      unawaited(_transferHostTo(successor));
      return;
    }

    if (_awaitingReplacement) {
      _setStatus(NetplayStatus.inLobby);
      return;
    }

    endGame();
    _disbandRoom();
  }

  /// Guest left the game UI and the room.
  void exitGameAndLeaveRoom() {
    _stopLockstep();
    _safeSendToHost(NetplayMessage.gameExit());
    leaveRoom();
  }

  /// Guest left an active game session without leaving the room.
  void exitGameAndLeave() {
    _stopLockstep();
    _safeSendToHost(NetplayMessage.gameExit());
    if (_status == NetplayStatus.gaming) {
      _setStatus(NetplayStatus.inLobby);
    }
  }

  void resumeGame({required String gameMd5, required String gameId}) {
    if (!_isHost) {
      return;
    }
    _awaitingReplacement = false;
    if (_hostedRoom != null) {
      _hostedRoom = _hostedRoom!.copyWith(
        inGame: true,
        awaitingReplacement: false,
      );
      _broadcastRoomState();
    }
    _broadcast(
      NetplayMessage.startGame(
        gameMd5: gameMd5,
        gameId: gameId,
        resume: true,
      ),
    );
    _startGameController.add(
      NetplayStartGameEvent(
        gameMd5: gameMd5,
        gameId: gameId,
        resume: true,
      ),
    );
    _setStatus(NetplayStatus.gaming);
    _broadcast(NetplayMessage.gameSpeed(speed: _gameSpeed));
  }

  Future<void> _resumeReplacementForPeer(String peerId) async {
    if (!_isHost || peerId.isEmpty) {
      return;
    }

    for (var attempt = 0; attempt < 50; attempt++) {
      final bytes = _stashedResumeSaveState;
      if (bytes != null && bytes.isNotEmpty) {
        await sendSaveStateToPeer(peerId: peerId, bytes: bytes);
        final resumeRoom = _hostedRoom;
        if (resumeRoom != null) {
          resumeGame(
            gameMd5: resumeRoom.gameMd5,
            gameId: resumeRoom.gameCode,
          );
        }
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
  }

  Future<void> sendSaveStateToPeer({
    required String peerId,
    required Uint8List bytes,
  }) async {
    if (!_isHost || bytes.isEmpty) {
      return;
    }
    _sendToPeer(
      peerId,
      NetplayMessage.saveStateBegin(size: bytes.length),
    );
    const chunkSize = NetplayRomTransfer.chunkSize;
    for (var offset = 0; offset < bytes.length; offset += chunkSize) {
      final end = min(offset + chunkSize, bytes.length);
      _peers[peerId]?.socket.add(bytes.sublist(offset, end));
    }
    _sendToPeer(peerId, NetplayMessage.saveStateEnd());
  }

  void configureLockstepRunner(NetplayLockstepRunner runner) {
    _lockstepRunner = runner;
  }

  /// Both sides call after [retro_load_game] — lockstep begins when all ready.
  void signalLockstepReady({
    required double fps,
    required Set<int> requiredSlots,
  }) {
    _lockstepFps = fps > 0 ? fps : 60.0;
    _lockstepRequiredSlots = requiredSlots;

    if (_isHost) {
      _lockstepReadyPeers.add('host');
      _tryStartLockstep();
    } else {
      _safeSendToHost(NetplayMessage.lockstepReady(fps: _lockstepFps));
    }
  }

  void sendFrameInput({
    required int slot,
    required int buttons,
  }) {
    if (_isHost) {
      return;
    }
    _safeSendToHost(
      NetplayMessage.frameInput(
        slot: slot,
        buttons: buttons,
      ),
    );
  }

  /// Host publishes one authoritative input bundle; both cores consume it.
  void publishFrameBundle({
    required int frame,
    required Map<int, int> inputs,
  }) {
    if (!_isHost) {
      return;
    }
    final message = NetplayMessage.frameBundle(frame: frame, inputs: inputs);
    _broadcast(message);
    _lockstepRunner?.applyFrameBundle(frame, inputs);
  }

  void _stopLockstep() {
    _lockstepRunner?.stop();
    _lockstepReadyPeers.clear();
  }

  void _tryStartLockstep() {
    if (!_isHost) {
      return;
    }

    final playablePeers = _peers.values.where((peer) => peer.playerSlot > 0);
    for (final peer in playablePeers) {
      if (!_lockstepReadyPeers.contains(peer.id)) {
        return;
      }
    }

    final slots = <int>{1};
    for (final peer in playablePeers) {
      slots.add(peer.playerSlot);
    }
    _lockstepRequiredSlots = slots;

    final config = LockstepStartConfig(
      startFrame: 0,
      fps: _lockstepFps,
      requiredSlots: slots.toList()..sort(),
    );
    _broadcast(
      NetplayMessage.lockstepStart(
        frame: config.startFrame,
        fps: config.fps,
        slots: config.requiredSlots,
      ),
    );
    _lockstepRunner?.setRequiredSlots(_lockstepRequiredSlots);
    _lockstepStartController.add(config);
    _lockstepRunner?.start(fps: config.fps, startFrame: config.startFrame);
  }

  void _handleLockstepReady(String peerId, double fps) {
    if (fps > 0) {
      _lockstepFps = fps;
    }
    _lockstepReadyPeers.add(peerId);
    if (_isHost) {
      _tryStartLockstep();
    }
  }

  void _handleLockstepStart(LockstepStartConfig config) {
    _lockstepRequiredSlots = config.requiredSlots.toSet();
    _lockstepRunner?.setRequiredSlots(_lockstepRequiredSlots);
    _lockstepStartController.add(config);
    _lockstepRunner?.start(
      fps: config.fps,
      startFrame: config.startFrame,
    );
  }

  void _handleFrameInput(String peerId, NetplayMessage message) {
    if (!_isHost) {
      return;
    }
    final slot = (message.payload['slot'] as num?)?.toInt() ?? 0;
    final buttons = (message.payload['buttons'] as num?)?.toInt() ?? 0;
    _lockstepRunner?.receiveRemoteInput(slot, buttons);
  }

  void _handleFrameBundle(NetplayMessage message) {
    final frame = (message.payload['frame'] as num?)?.toInt() ?? 0;
    final raw = message.payload['inputs'];
    if (raw is! Map) {
      return;
    }
    final inputs = <int, int>{};
    for (final entry in raw.entries) {
      final slot = int.tryParse(entry.key.toString());
      if (slot == null) {
        continue;
      }
      inputs[slot] = (entry.value as num?)?.toInt() ?? 0;
    }
    _lockstepRunner?.applyFrameBundle(frame, inputs);
  }

  void closeRoom() {
    if (!_isHost) {
      return;
    }
    final successor = _findHostSuccessor();
    if (successor != null) {
      unawaited(_transferHostTo(successor));
      return;
    }
    _disbandRoom();
  }

  void _disbandRoom() {
    if (!_isHost) {
      return;
    }
    final roomSnapshot = _hostedRoom;
    _udpAnnounceTimer?.cancel();
    _udpAnnounceTimer = null;
    _closeUdpResponder();
    _broadcast(NetplayMessage.leave());
    unawaited(_repeatRoomClosedAnnouncement(roomSnapshot));
    unawaited(Future<void>(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await _resetConnections(notifyDisconnected: false);
    }));
  }

  String? _findHostSuccessor() {
    _PeerConnection? candidate;
    for (final peer in _peers.values) {
      if (peer.playerSlot <= 0) {
        continue;
      }
      if (candidate == null || peer.playerSlot < candidate.playerSlot) {
        candidate = peer;
      }
    }
    return candidate?.id;
  }

  Future<void> _transferHostTo(String peerId) async {
    final peer = _peers[peerId];
    final room = _hostedRoom;
    if (peer == null || room == null) {
      _disbandRoom();
      return;
    }

    final resumePlay =
        _status == NetplayStatus.gaming || _awaitingReplacement || room.inGame;
    if (resumePlay) {
      _stopLockstep();
      _awaitingReplacement = true;
    } else if (_status == NetplayStatus.gaming) {
      endGame();
      _stopLockstep();
    }

    if (_stashedResumeSaveState != null) {
      await sendSaveStateToPeer(
        peerId: peerId,
        bytes: _stashedResumeSaveState!,
      );
    }

    _sendToPeer(
      peerId,
      NetplayMessage.hostPromote(
        room: room
            .copyWith(
              inGame: resumePlay,
              awaitingReplacement: resumePlay,
              currentPlayers: 1,
            )
            .toJson(),
        playerName: peer.playerName,
        gameSpeed: _gameSpeed,
      ),
    );

    await Future<void>.delayed(const Duration(milliseconds: 150));
    await _resetConnections(notifyDisconnected: false);
  }

  Future<void> _handleHostPromote(NetplayMessage message) async {
    final roomRaw = message.payload['room'];
    if (roomRaw is! Map) {
      return;
    }
    final playerName =
        message.payload['playerName'] as String? ?? _localPlayerName ?? 'Player 1';
    final parsed = RoomInfo.fromJson(
      Map<String, dynamic>.from(roomRaw),
      hostIp: '0.0.0.0',
    );
    final resumeSave = _receivedResumeSaveState;
    final roomTemplate = parsed.copyWith(currentPlayers: 1);

    await _clientSocket?.close();
    _clientSocket = null;
    _peers.clear();

    _localPlayerName = playerName;
    await _resetConnections(
      keepDiscovery: false,
      notifyDisconnected: false,
    );

    final ok = await createRoom(
      roomTemplate: roomTemplate,
      playerName: playerName,
    );
    if (!ok) {
      return;
    }

    _awaitingReplacement = roomTemplate.awaitingReplacement;
    if (_hostedRoom != null && roomTemplate.awaitingReplacement) {
      _hostedRoom = _hostedRoom!.copyWith(
        inGame: roomTemplate.inGame,
        awaitingReplacement: true,
      );
      _broadcastRoomState();
    }
    if (resumeSave != null) {
      _stashedResumeSaveState = Uint8List.fromList(resumeSave);
    }

    final promotedSpeed = (message.payload['gameSpeed'] as num?)?.toInt() ?? 1;
    _gameSpeed = promotedSpeed.clamp(1, 5);
    _gameSpeedController.add(_gameSpeed);

    enterLobby();
    final hosted = _hostedRoom;
    if (hosted != null) {
      _hostPromotedController.add(hosted);
    }
  }

  void leaveRoom({bool notifyHost = true}) {
    if (_isHost) {
      return;
    }
    if (notifyHost) {
      _safeSendToHost(NetplayMessage.leave());
    }
    unawaited(_resetConnections(notifyDisconnected: false));
  }

  /// 被动断开（房主解散/连接已断）时只清理本地状态，不再通知对端。
  void detachFromRoom() {
    leaveRoom(notifyHost: false);
  }

  Future<void> dispose() async {
    await _resetConnections();
    await _statusController.close();
    await _roomFoundController.close();
    await _playerJoinedController.close();
    await _playerUpdatedController.close();
    await _playerLeftController.close();
    await _messageController.close();
    await _romProgressController.close();
    await _startGameController.close();
    await _connectionStateController.close();
    await _roomStateController.close();
    await _lockstepStartController.close();
    await _gameplayPeerLeftController.close();
    await _saveStateReceivedController.close();
    await _playerSlotAssignedController.close();
    await _hostPromotedController.close();
    await _gameSpeedController.close();
  }

  void _setStatus(NetplayStatus status) {
    if (_status == status) {
      return;
    }
    _status = status;
    _statusController.add(status);
  }

  Future<void> _resetConnections({
    bool keepDiscovery = false,
    bool notifyDisconnected = true,
  }) async {
    _udpAnnounceTimer?.cancel();
    _udpAnnounceTimer = null;

    if (!keepDiscovery) {
      stopDiscovery();
    }
    _closeUdpResponder();
    unawaited(LanMulticastLock.release());

    for (final peer in _peers.values) {
      await peer.socket.close();
    }
    _peers.clear();

    await _clientSocket?.close();
    _clientSocket = null;

    await _server?.close();
    _server = null;

    _hostedRoom = null;
    _joinedRoom = null;
    _roomState = null;
    _localPlayerSlot = 0;
    _localPlayerId = null;
    _isHost = false;
    _sendingRom = false;
    _pendingRomBegin = null;
    _awaitingReplacement = false;
    _exitingForReplacement = false;
    _hostPromotionExit = false;
    _stashedResumeSaveState = null;
    _receivedResumeSaveState = null;
    _stopLockstep();

    if (!keepDiscovery) {
      _setStatus(NetplayStatus.none);
    }
    if (notifyDisconnected) {
      _connectionStateController.add(false);
    }
  }

  String _assignPeerId(Socket socket) {
    _peerIdSeq += 1;
    return '${socket.remoteAddress.address}:${socket.remotePort}#$_peerIdSeq';
  }

  void _onIncomingClient(Socket socket) {
    final id = _assignPeerId(socket);
    final peer = _PeerConnection(
      id: id,
      socket: socket,
      parser: NetplayStreamParser(),
    );
    _peers[id] = peer;

    socket.listen(
      (data) => _handlePeerData(peer, data),
      onDone: () => _handlePeerClosed(id),
      onError: (_) => _handlePeerClosed(id),
    );

    if (_hostedRoom != null) {
      _syncHostedRoomCounts();
    }
  }

  void _syncHostedRoomCounts() {
    final room = _hostedRoom;
    if (room == null) {
      return;
    }

    final playablePeers =
        _peers.values.where((peer) => peer.playerSlot > 0).length;

    _hostedRoom = room.copyWith(
      currentPlayers: min(1 + playablePeers, room.maxPlayers),
    );
  }

  NetplayRoomState _buildRoomState() {
    final room = _hostedRoom ?? _joinedRoom;
    final hostIp = room?.hostIp ?? 'host';
    final players = <PlayerInfo>[
      PlayerInfo(
        id: hostIp,
        name: _isHost ? (_localPlayerName ?? '房主') : '房主',
        isHost: true,
        isReady: true,
        slot: 1,
      ),
    ];

    if (_isHost) {
      for (final peer in _peers.values) {
        if (peer.playerSlot <= 0) {
          continue;
        }
        players.add(
          PlayerInfo(
            id: peer.id,
            name: peer.playerName,
            isHost: false,
            isReady: peer.isReady,
            slot: peer.playerSlot,
            latency: peer.latency,
          ),
        );
      }
    } else if (_roomState != null) {
      players
        ..clear()
        ..addAll(_roomState!.players);
    }

    return NetplayRoomState(
      players: players,
      maxPlayers: (room?.maxPlayers ?? 2).clamp(2, 4),
      inGame: room?.inGame ?? false,
      awaitingReplacement: _awaitingReplacement,
    );
  }

  void _applyRoomState(NetplayRoomState state) {
    _roomState = state;
    if (_hostedRoom != null) {
      _hostedRoom = _hostedRoom!.copyWith(
        currentPlayers: state.playableCount,
        inGame: state.inGame,
        awaitingReplacement: state.awaitingReplacement,
      );
    }
    if (_joinedRoom != null) {
      _joinedRoom = _joinedRoom!.copyWith(
        currentPlayers: state.playableCount,
        inGame: state.inGame,
        awaitingReplacement: state.awaitingReplacement,
      );
    }
    _roomStateController.add(state);
  }

  void _broadcastRoomState() {
    if (!_isHost) {
      return;
    }
    _syncHostedRoomCounts();
    final state = _buildRoomState();
    _applyRoomState(state);
    _broadcast(NetplayMessage.roomState(state.toPayload()));
  }

  void _ensurePeerPlayable(String peerId) {
    final peer = _peers[peerId];
    if (peer == null || peer.playerSlot > 0) {
      return;
    }
    final slot = _assignPlayerSlot(peerId: peerId);
    if (slot <= 0) {
      return;
    }
    peer.playerSlot = slot;
    _sendToPeer(
      peerId,
      NetplayMessage.joinAck(
        slot: slot,
        playerId: peerId,
      ),
    );
    _broadcastRoomState();
    _playerJoinedController.add(
      PlayerInfo(
        id: peerId,
        name: peer.playerName,
        isHost: false,
        slot: slot,
      ),
    );
  }

  int _assignPlayerSlot({required String peerId}) {
    final room = _hostedRoom;
    if (room == null) {
      return 0;
    }

    if (room.inGame && !_awaitingReplacement) {
      return 0;
    }

    final used = <int>{1};
    for (final peer in _peers.values) {
      if (peer.id != peerId && peer.playerSlot > 0) {
        used.add(peer.playerSlot);
      }
    }

    for (var slot = 2; slot <= room.maxPlayers; slot++) {
      if (!used.contains(slot)) {
        return slot;
      }
    }
    return 0;
  }

  void _handlePeerData(_PeerConnection peer, Uint8List data) {
    peer.parser.feed(
      data,
      onMessage: (message) => _handleMessage(peer.id, message),
      onRomComplete: (bytes, beginMeta) =>
          _handleRomComplete(peer.id, bytes, beginMeta),
      onSaveStateComplete: (bytes) => _handleSaveStateComplete(bytes),
    );
  }

  void _handleSaveStateComplete(Uint8List bytes) {
    if (bytes.isEmpty) {
      return;
    }
    _receivedResumeSaveState = Uint8List.fromList(bytes);
    _saveStateReceivedController.add(_receivedResumeSaveState!);
  }

  void _handleMessage(String peerId, NetplayMessage message) {
    _messageController.add(message);

    switch (message.type) {
      case NetplayMessageType.join:
        final name = message.payload['playerName'] as String? ?? 'Player 2';
        final peer = _peers[peerId];
        final slot = _assignPlayerSlot(peerId: peerId);
        if (peer != null) {
          peer.playerName = name;
          peer.playerSlot = slot;
        }
        if (slot <= 0) {
          _sendToPeer(peerId, NetplayMessage.leave());
          _handlePeerClosed(peerId);
        } else {
          if (_isHost) {
            _sendToPeer(
              peerId,
              NetplayMessage.joinAck(
                slot: slot,
                playerId: peerId,
              ),
            );
            _broadcastRoomState();
            _sendToPeer(
              peerId,
              NetplayMessage.pong(DateTime.now().millisecondsSinceEpoch),
            );
            final room = _hostedRoom;
            if (room != null && room.inGame && !_awaitingReplacement) {
              _sendToPeer(
                peerId,
                NetplayMessage.startGame(
                  gameMd5: room.gameMd5,
                  gameId: room.gameCode,
                ),
              );
            }
            if (_awaitingReplacement && slot > 0) {
              unawaited(_resumeReplacementForPeer(peerId));
            }
          }
          _playerJoinedController.add(
            PlayerInfo(
              id: peerId,
              name: name,
              isHost: false,
              slot: slot,
            ),
          );
        }
      case NetplayMessageType.joinAck:
        _localPlayerSlot = (message.payload['slot'] as num?)?.toInt() ?? 0;
        _localPlayerId = message.payload['playerId'] as String? ?? '';
        _playerSlotAssignedController.add(_localPlayerSlot);
      case NetplayMessageType.roomState:
        if (!_isHost) {
          final state = NetplayRoomState.fromPayload(message.payload);
          _applyRoomState(state);
        }
      case NetplayMessageType.readyStatus:
        _ensurePeerPlayable(peerId);
        final ready = message.payload['status'] == 'ready';
        final peer = _peers[peerId];
        if (peer != null) {
          peer.isReady = ready;
        }
        _playerUpdatedController.add(
          PlayerInfo(
            id: peerId,
            name: peer?.playerName ?? peerId,
            isReady: ready,
            slot: peer?.playerSlot ?? 0,
          ),
        );
        if (_isHost) {
          _broadcastRoomState();
        }
      case NetplayMessageType.requestRom:
        if (_isHost) {
          _ensurePeerPlayable(peerId);
          _messageController.add(message);
        }
      case NetplayMessageType.startGame:
        final gameMd5 = message.payload['gameMd5'] as String? ?? '';
        final gameId = message.payload['gameId'] as String? ?? '';
        final resume = _isResumeStartPayload(message.payload);
        _startGameController.add(
          NetplayStartGameEvent(
            gameMd5: gameMd5,
            gameId: gameId,
            resume: resume,
          ),
        );
        _setStatus(NetplayStatus.gaming);
      case NetplayMessageType.lockstepReady:
        if (_isHost) {
          final fps = (message.payload['fps'] as num?)?.toDouble() ?? 60.0;
          _handleLockstepReady(peerId, fps);
        }
      case NetplayMessageType.lockstepStart:
        if (!_isHost) {
          final frame = message.payload['frame'] as int? ?? 0;
          final fps = (message.payload['fps'] as num?)?.toDouble() ?? 60.0;
          final slots = (message.payload['slots'] as List?)
                  ?.map((e) => e as int)
                  .toList() ??
              const [1, 2];
          _handleLockstepStart(
            LockstepStartConfig(
              startFrame: frame,
              fps: fps,
              requiredSlots: slots,
            ),
          );
        }
      case NetplayMessageType.frameInput:
        _handleFrameInput(peerId, message);
      case NetplayMessageType.frameBundle:
        _handleFrameBundle(message);
      case NetplayMessageType.gameExit:
        if (_isHost && _status == NetplayStatus.gaming) {
          _handleGameplayPeerLeft(peerId);
        }
      case NetplayMessageType.gameSpeed:
        final speed = (message.payload['speed'] as num?)?.toInt() ?? 1;
        _applyRemoteGameSpeed(speed);
      case NetplayMessageType.hostPromote:
        if (!_isHost) {
          _hostPromotionPending = true;
          unawaited(
            _handleHostPromote(message).whenComplete(() {
              _hostPromotionPending = false;
            }),
          );
        }
      case NetplayMessageType.leave:
        _handlePeerClosed(peerId);
      case NetplayMessageType.ping:
        final sentAt = message.payload['sentAt'] as int? ?? 0;
        _sendToPeer(peerId, NetplayMessage.pong(sentAt));
      case NetplayMessageType.pong:
        final sentAt = message.payload['sentAt'] as int? ?? 0;
        final latency = max(0, DateTime.now().millisecondsSinceEpoch - sentAt);
        final peer = _peers[peerId];
        if (peer != null) {
          peer.latency = latency;
        }
        _playerUpdatedController.add(
          PlayerInfo(
            id: peerId,
            name: peer?.playerName ?? peerId,
            latency: latency,
            slot: peer?.playerSlot ?? 0,
          ),
        );
        if (_isHost) {
          _broadcastRoomState();
        }
      case NetplayMessageType.romBegin:
        if (!_isHost) {
          if (NetplayWire.hasInlineRomData(message.payload)) {
            try {
              final bytes = base64Decode(message.payload['data'] as String);
              _handleRomComplete(
                peerId,
                Uint8List.fromList(bytes),
                message,
              );
            } catch (_) {
              _setStatus(NetplayStatus.inLobby);
            }
          } else {
            _pendingRomBegin = message;
            _setStatus(NetplayStatus.transferringRom);
          }
        }
      case NetplayMessageType.romEnd:
        if (!_isHost && _pendingRomBegin == null) {
          _setStatus(NetplayStatus.inLobby);
        }
    }
  }

  void _handleRomComplete(
    String peerId,
    Uint8List bytes,
    NetplayMessage beginMeta,
  ) {
    final expectedSize = (beginMeta.payload['size'] as num?)?.toInt() ?? 0;
    if (expectedSize > 0 && bytes.length != expectedSize) {
      _pendingRomBegin = null;
      if (!_isHost) {
        _setStatus(NetplayStatus.inLobby);
      }
      return;
    }

    final md5Hash =
        (beginMeta.payload['md5'] as String? ?? '').toLowerCase();
    final fileName = NetplayWire.decodeRomFileName(beginMeta.payload);
    _romProgressController.add(
      RomTransferProgress(
        sent: bytes.length,
        total: bytes.length,
        isSending: false,
        bytes: bytes,
        fileName: fileName,
        md5: md5Hash,
      ),
    );
    _pendingRomBegin = null;
    if (!_isHost) {
      _setStatus(NetplayStatus.inLobby);
    }
  }

  void _handlePeerClosed(String peerId) {
    if (_isHost && _status == NetplayStatus.gaming) {
      _handleGameplayPeerLeft(peerId);
      return;
    }
    _peers.remove(peerId);
    _playerLeftController.add(peerId);
    if (_isHost) {
      _syncHostedRoomCounts();
      _broadcastRoomState();
    }
    if (!_isHost &&
        peerId == _joinedRoom?.hostIp &&
        !_hostPromotionPending) {
      unawaited(_resetConnections());
    }
  }

  void _handleGameplayPeerLeft(String peerId) {
    _peers.remove(peerId);
    _playerLeftController.add(peerId);
    _stopLockstep();
    _awaitingReplacement = true;
    if (_hostedRoom != null) {
      _hostedRoom = _hostedRoom!.copyWith(
        inGame: true,
        awaitingReplacement: true,
      );
    }
    _syncHostedRoomCounts();
    _broadcastRoomState();
    _gameplayPeerLeftController.add(null);
  }

  void _broadcast(NetplayMessage message) {
    final bytes = NetplayLineCodec.encode(message);
    if (_isHost) {
      for (final peer in _peers.values) {
        _safeSocketAdd(peer.socket, bytes);
      }
    } else {
      _safeSocketAdd(_clientSocket, bytes);
    }
  }

  void _sendToPeer(String peerId, NetplayMessage message) {
    final bytes = NetplayLineCodec.encode(message);
    _safeSocketAdd(_peers[peerId]?.socket, bytes);
  }

  void _sendToHost(NetplayMessage message) {
    _safeSendToHost(message);
  }

  void _safeSendToHost(NetplayMessage message) {
    _safeSocketAdd(_clientSocket, NetplayLineCodec.encode(message));
  }

  void _safeSocketAdd(Socket? socket, List<int> bytes) {
    if (socket == null) {
      return;
    }
    try {
      socket.add(bytes);
    } on StateError {
      // StreamSink already closed.
    } on SocketException {
      // Peer disconnected.
    }
  }

  Future<void> _startUdpResponder() async {
    try {
      await _refreshNetworkTargets(_hostedRoom?.hostIp);
      _closeUdpResponder();
      _udpResponderSocket = await _bindUdpSocket(port: _discoveryPort);
      final socket = _udpResponderSocket;
      if (socket == null) {
        return;
      }
      socket.listen((event) {
        if (event != RawSocketEvent.read) {
          return;
        }
        final datagram = socket.receive();
        if (datagram == null || _hostedRoom == null) {
          return;
        }
        final message = utf8.decode(datagram.data).trim();
        if (message == udpDiscover || message.startsWith(udpMagic)) {
          _syncHostedRoomCounts();
          final payload = utf8.encode('$udpMagic${_hostedRoom!.toUdpPayload()}');
          try {
            socket.send(payload, datagram.address, datagram.port);
          } on SocketException {
          } on OSError {
          } catch (_) {}
        }
      });
    } catch (_) {}
  }

  void _startUdpAnnounce() {
    _udpAnnounceTimer?.cancel();
    _udpAnnounceTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      unawaited(_broadcastUdpAnnouncement());
    });
    unawaited(_broadcastUdpAnnouncement());
  }

  Future<void> _repeatRoomClosedAnnouncement(RoomInfo? room) async {
    if (room == null) {
      return;
    }
    for (var i = 0; i < 5; i++) {
      await _sendRoomClosedAnnouncement(room);
      if (i < 4) {
        await Future<void>.delayed(const Duration(milliseconds: 150));
      }
    }
  }

  Future<void> _sendRoomClosedAnnouncement(RoomInfo room) async {
    try {
      await _refreshNetworkTargets(room.hostIp);
      if (!_hasDiscoveryNetwork) {
        return;
      }
      final socket = await _bindUdpSocket(port: 0);
      if (socket == null) {
        return;
      }
      final payload = utf8.encode(
        '$udpMagic${jsonEncode({...room.toJson(), 'closed': true})}',
      );
      _sendUdpDiscoveryPacket(socket, Uint8List.fromList(payload));
      socket.close();
    } catch (_) {}
  }

  Future<void> _broadcastRoomClosedAnnouncement() async {
    final room = _hostedRoom;
    if (room == null) {
      return;
    }
    await _sendRoomClosedAnnouncement(room);
  }

  Future<void> _broadcastUdpAnnouncement() async {
    if (_hostedRoom == null) {
      return;
    }
    _syncHostedRoomCounts();
    try {
      await _refreshNetworkTargets(_hostedRoom!.hostIp);
      if (!_hasDiscoveryNetwork) {
        return;
      }
      final socket = await _bindUdpSocket(port: 0);
      if (socket == null) {
        return;
      }
      final payload = utf8.encode('$udpMagic${_hostedRoom!.toUdpPayload()}');
      _sendUdpDiscoveryPacket(socket, Uint8List.fromList(payload));
      socket.close();
    } catch (_) {}
  }

  bool _discoveryListenerStarting = false;

  Future<void> _startUdpDiscoveryListener() async {
    if (_discoveryListenerStarting) {
      return;
    }
    _discoveryListenerStarting = true;
    try {
      await _refreshNetworkTargets();
      if (!_hasDiscoveryNetwork || _status != NetplayStatus.searching) {
        return;
      }

      _udpSocket?.close();
      _udpSocket = await _bindUdpSocket(port: 0);
      if (_udpSocket == null) {
        return;
      }

      final listenEpoch = _discoveryEpoch;
      _udpSocket!.listen((event) {
        if (event != RawSocketEvent.read || listenEpoch != _discoveryEpoch) {
          return;
        }
        final datagram = _udpSocket?.receive();
        if (datagram == null) {
          return;
        }
        final message = utf8.decode(datagram.data).trim();
        if (message.startsWith(udpMagic)) {
          final jsonStr = message.substring(udpMagic.length);
          try {
            final room = RoomInfo.fromUdpPayload(
              datagram.address.address,
              jsonStr,
            );
            if (room.roomId.isNotEmpty) {
              _emitRoomFound(room);
            }
          } catch (_) {}
        }
      });

      _udpDiscoverTimer?.cancel();
      _udpDiscoverTimer = Timer.periodic(const Duration(seconds: 2), (timer) {
        if (_status != NetplayStatus.searching) {
          timer.cancel();
          return;
        }
        unawaited(_pulseUdpDiscoveryAsync());
      });
      _pulseUdpDiscovery();
    } on Object {
      // ignore
    } finally {
      _discoveryListenerStarting = false;
    }
  }

  Future<void> _scanMdns() async {
    if (!_mdnsEnabled) {
      return;
    }
    try {
      _mdnsClient ??= MDnsClient();
      await _mdnsClient!.start();

      await for (final PtrResourceRecord ptr
          in _mdnsClient!.lookup<PtrResourceRecord>(
        ResourceRecordQuery.serverPointer('$serviceType.local'),
      )) {
      final serviceName = ptr.domainName;
      String? target;
      int? srvPort;

      await for (final SrvResourceRecord srv
          in _mdnsClient!.lookup<SrvResourceRecord>(
        ResourceRecordQuery.service(serviceName),
      )) {
        target = srv.target;
        srvPort = srv.port;
      }

      final txt = <String, String>{};
      await for (final TxtResourceRecord txtRecord
          in _mdnsClient!.lookup<TxtResourceRecord>(
        ResourceRecordQuery.text(serviceName),
      )) {
        _parseTxtRecord(txtRecord.text, txt);
      }

      if (target == null || srvPort == null) {
        continue;
      }

      final hostIp = await _resolveMdnsHost(target);
      if (hostIp == null) {
        continue;
      }

      final room = RoomInfo.fromTxtRecord(
        hostIp: hostIp,
        port: srvPort,
        txt: txt,
      );
      if (room.roomId.isNotEmpty) {
        _emitRoomFound(room);
      }
    }
    } catch (_) {
      _mdnsEnabled = false;
      _mdnsScanTimer?.cancel();
      _mdnsScanTimer = null;
      _mdnsClient?.stop();
      _mdnsClient = null;
    }
  }

  Future<String?> _resolveMdnsHost(String hostName) async {
    final normalized = hostName.endsWith('.') ? hostName : '$hostName.';
    await for (final IPAddressResourceRecord record
        in _mdnsClient!.lookup<IPAddressResourceRecord>(
      ResourceRecordQuery.addressIPv4(normalized),
    )) {
      return record.address.address;
    }
    return null;
  }

  void _parseTxtRecord(String text, Map<String, String> txt) {
    for (final segment in text.split('\x00')) {
      final eq = segment.indexOf('=');
      if (eq > 0) {
        txt[segment.substring(0, eq)] = segment.substring(eq + 1);
      }
    }
  }
}

class _PeerConnection {
  _PeerConnection({
    required this.id,
    required this.socket,
    required this.parser,
    this.playerName = 'Player',
    this.playerSlot = 0,
    this.isReady = false,
    this.latency = 0,
  });

  final String id;
  final Socket socket;
  final NetplayStreamParser parser;
  String playerName;
  int playerSlot;
  bool isReady;
  int latency;
}

class RomTransferProgress {
  const RomTransferProgress({
    required this.sent,
    required this.total,
    required this.isSending,
    this.bytes,
    this.fileName,
    this.md5,
  });

  final int sent;
  final int total;
  final bool isSending;
  final Uint8List? bytes;
  final String? fileName;
  final String? md5;

  double get progress => total == 0 ? 0 : sent / total;
}

class NetplayStartGameEvent {
  const NetplayStartGameEvent({
    required this.gameMd5,
    required this.gameId,
    this.resume = false,
  });

  final String gameMd5;
  final String gameId;
  final bool resume;
}

/// Legacy packet type kept for API compatibility.
class NetworkData {
  const NetworkData({
    required this.senderId,
    required this.data,
    required this.timestamp,
  });

  final String senderId;
  final Uint8List data;
  final DateTime timestamp;
}

/// Backward-compatible alias.
typedef LANService = NetplayService;
