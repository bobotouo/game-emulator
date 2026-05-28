import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import '../settings/app_settings_service.dart';

/// LAN multiplayer service for room discovery and communication
class LANService {
  // Server
  ServerSocket? _server;
  final List<Socket> _clients = [];

  // Client
  Socket? _socket;

  // Discovery
  RawDatagramSocket? _discoverySocket;
  Timer? _discoveryTimer;

  // State
  bool _isHost = false;
  bool _isConnected = false;
  String? _roomCode;
  String? _hostIp;
  int _port = 7845;
  int _discoveryPort = 7846;

  // Callbacks
  final _roomFoundController = StreamController<RoomInfo>.broadcast();
  final _playerJoinedController = StreamController<PlayerInfo>.broadcast();
  final _playerLeftController = StreamController<String>.broadcast();
  final _dataReceivedController = StreamController<NetworkData>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();

  LANService() {
    _port = AppSettingsService.instance.networkPort;
    _discoveryPort = _port + 1;
  }

  // Streams
  Stream<RoomInfo> get onRoomFound => _roomFoundController.stream;
  Stream<PlayerInfo> get onPlayerJoined => _playerJoinedController.stream;
  Stream<String> get onPlayerLeft => _playerLeftController.stream;
  Stream<NetworkData> get onDataReceived => _dataReceivedController.stream;
  Stream<bool> get onConnectionStateChanged =>
      _connectionStateController.stream;

  // Getters
  bool get isHost => _isHost;
  bool get isConnected => _isConnected;
  String? get roomCode => _roomCode;
  String? get hostIp => _hostIp;
  int get port => _port;
  List<Socket> get clients => _clients;

  /// Get local IP address
  Future<String?> getLocalIp() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      for (final interface in interfaces) {
        for (final addr in interface.addresses) {
          if (!addr.isLoopback) {
            return addr.address;
          }
        }
      }
    } catch (e) {
      print('Error getting local IP: $e');
    }
    return null;
  }

  /// Create a room (host)
  Future<bool> createRoom({String? roomName}) async {
    try {
      _isHost = true;
      _roomCode = _generateRoomCode();

      // Start TCP server
      _server = await ServerSocket.bind(InternetAddress.anyIPv4, _port);
      _server!.listen(_onClientConnected);

      // Start UDP discovery responder
      _startDiscoveryResponder();

      _isConnected = true;
      _connectionStateController.add(true);

      print('Room created: $_roomCode on port $_port');
      return true;
    } catch (e) {
      print('Error creating room: $e');
      return false;
    }
  }

  /// Join a room (client)
  Future<bool> joinRoom(String hostIp, {String? playerName}) async {
    try {
      _isHost = false;
      _hostIp = hostIp;

      // Connect to host
      _socket = await Socket.connect(hostIp, _port);
      _socket!.listen(
        _onDataReceived,
        onDone: () => _onDisconnected(),
        onError: (error) => _onError(error),
      );

      // Send join request
      _sendJoinRequest(playerName ?? 'Player');

      _isConnected = true;
      _connectionStateController.add(true);

      print('Joined room at $hostIp:$_port');
      return true;
    } catch (e) {
      print('Error joining room: $e');
      return false;
    }
  }

  /// Start LAN discovery
  void startDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = Timer.periodic(const Duration(seconds: 2), (_) {
      _broadcastDiscovery();
    });
  }

  /// Stop LAN discovery
  void stopDiscovery() {
    _discoveryTimer?.cancel();
    _discoveryTimer = null;
  }

  void _startDiscoveryResponder() async {
    _discoverySocket = await RawDatagramSocket.bind(
      InternetAddress.anyIPv4,
      _discoveryPort,
      reuseAddress: true,
    );

    _discoverySocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final datagram = _discoverySocket!.receive();
        if (datagram != null) {
          _handleDiscoveryRequest(datagram);
        }
      }
    });
  }

  void _broadcastDiscovery() async {
    try {
      final socket = await RawDatagramSocket.bind(
        InternetAddress.anyIPv4,
        0,
        reuseAddress: true,
      );

      socket.broadcastEnabled = true;

      final message = Uint8List.fromList('GBA_EMU_DISCOVER'.codeUnits);
      socket.send(message, InternetAddress('255.255.255.255'), _discoveryPort);

      socket.close();
    } catch (e) {
      // Ignore discovery errors
    }
  }

  void _handleDiscoveryRequest(Datagram datagram) {
    final message = String.fromCharCodes(datagram.data);

    if (message == 'GBA_EMU_DISCOVER') {
      // Respond with room info
      final response = 'GBA_EMU_ROOM:$_roomCode:$_port';
      _discoverySocket!.send(
        Uint8List.fromList(response.codeUnits),
        datagram.address,
        datagram.port,
      );
    } else if (message.startsWith('GBA_EMU_ROOM:')) {
      // Parse room info
      final parts = message.split(':');
      if (parts.length >= 3) {
        final roomInfo = RoomInfo(
          code: parts[1],
          hostIp: datagram.address.address,
          port: int.tryParse(parts[2]) ?? _port,
          name: 'GBA Room',
        );
        _roomFoundController.add(roomInfo);
      }
    }
  }

  void _onClientConnected(Socket client) {
    _clients.add(client);
    client.listen(
      (data) => _onClientData(client, data),
      onDone: () => _onClientDisconnected(client),
      onError: (error) => _onClientError(client, error),
    );

    print('Client connected: ${client.remoteAddress.address}');
  }

  void _onClientData(Socket client, Uint8List data) {
    final networkData = NetworkData(
      senderId: client.remoteAddress.address,
      data: data,
      timestamp: DateTime.now(),
    );
    _dataReceivedController.add(networkData);
  }

  void _onClientDisconnected(Socket client) {
    _clients.remove(client);
    _playerLeftController.add(client.remoteAddress.address);
    print('Client disconnected: ${client.remoteAddress.address}');
  }

  void _onClientError(Socket client, dynamic error) {
    print('Client error: $error');
    _clients.remove(client);
  }

  void _onDataReceived(Uint8List data) {
    final networkData = NetworkData(
      senderId: _hostIp ?? 'unknown',
      data: data,
      timestamp: DateTime.now(),
    );
    _dataReceivedController.add(networkData);
  }

  void _onDisconnected() {
    _isConnected = false;
    _connectionStateController.add(false);
    print('Disconnected from host');
  }

  void _onError(dynamic error) {
    print('Connection error: $error');
    _isConnected = false;
    _connectionStateController.add(false);
  }

  void _sendJoinRequest(String playerName) {
    final request = 'JOIN:$playerName';
    _socket?.add(Uint8List.fromList(request.codeUnits));
  }

  /// Send data to all connected peers
  void sendData(Uint8List data) {
    if (_isHost) {
      // Send to all clients
      for (final client in _clients) {
        try {
          client.add(data);
        } catch (e) {
          print('Error sending to client: $e');
        }
      }
    } else {
      // Send to host
      _socket?.add(data);
    }
  }

  /// Send data to specific peer
  void sendDataTo(String peerId, Uint8List data) {
    if (_isHost) {
      final client = _clients.firstWhere(
        (c) => c.remoteAddress.address == peerId,
        orElse: () => throw Exception('Client not found'),
      );
      client.add(data);
    }
  }

  /// Generate room code
  String _generateRoomCode() {
    const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
    final random = DateTime.now().millisecondsSinceEpoch;
    return List.generate(6, (i) => chars[(random + i) % chars.length]).join();
  }

  /// Close room (host only)
  void closeRoom() {
    if (!_isHost) return;

    for (final client in _clients) {
      client.close();
    }
    _clients.clear();

    _server?.close();
    _server = null;

    _discoverySocket?.close();
    _discoverySocket = null;

    _isConnected = false;
    _connectionStateController.add(false);
  }

  /// Leave room (client only)
  void leaveRoom() {
    if (_isHost) return;

    _socket?.close();
    _socket = null;

    _isConnected = false;
    _connectionStateController.add(false);
  }

  /// Dispose all resources
  void dispose() {
    closeRoom();
    leaveRoom();
    stopDiscovery();

    _roomFoundController.close();
    _playerJoinedController.close();
    _playerLeftController.close();
    _dataReceivedController.close();
    _connectionStateController.close();
  }
}

/// Room information
class RoomInfo {
  final String code;
  final String hostIp;
  final int port;
  final String name;
  final int playerCount;
  final int maxPlayers;

  RoomInfo({
    required this.code,
    required this.hostIp,
    required this.port,
    required this.name,
    this.playerCount = 1,
    this.maxPlayers = 4,
  });
}

/// Player information
class PlayerInfo {
  final String id;
  final String name;
  final bool isHost;
  final bool isReady;
  final int latency;

  PlayerInfo({
    required this.id,
    required this.name,
    this.isHost = false,
    this.isReady = false,
    this.latency = 0,
  });
}

/// Network data packet
class NetworkData {
  final String senderId;
  final Uint8List data;
  final DateTime timestamp;

  NetworkData({
    required this.senderId,
    required this.data,
    required this.timestamp,
  });
}
