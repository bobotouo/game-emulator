import 'dart:io';

import 'package:network_info_plus/network_info_plus.dart';

/// Whether the device can participate in LAN-only netplay.
enum LanNetworkKind {
  /// Private LAN address on Wi‑Fi / Ethernet (same subnet discovery).
  localArea,

  /// Mobile data, public IP, or otherwise not on a local network.
  wideArea,

  /// No usable IPv4 connectivity.
  unavailable,
}

class LanNetworkSnapshot {
  const LanNetworkSnapshot({
    required this.kind,
    this.localIp,
    required this.userMessage,
  });

  final LanNetworkKind kind;
  final String? localIp;
  final String userMessage;

  bool get canUseLanLobby => kind == LanNetworkKind.localArea;
}

/// Detects if the device is on a local network suitable for LAN netplay.
class LanNetworkChecker {
  LanNetworkChecker._();

  static final NetworkInfo _networkInfo = NetworkInfo();

  static Future<LanNetworkSnapshot> evaluate() async {
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLinkLocal: false,
      );

      String? bestPrivateIp;
      var bestScore = -1;
      var hasCellularInterface = false;
      String? publicIp;

      for (final iface in interfaces) {
        final name = iface.name.toLowerCase();
        if (_isCellularInterface(name)) {
          hasCellularInterface = true;
        }

        for (final addr in iface.addresses) {
          if (addr.isLoopback) {
            continue;
          }
          final ip = addr.address;
          if (_isPrivateLan(ip)) {
            final score = _interfaceScore(name);
            if (score > bestScore) {
              bestScore = score;
              bestPrivateIp = ip;
            }
          } else {
            publicIp ??= ip;
          }
        }
      }

      if (bestPrivateIp != null) {
        return LanNetworkSnapshot(
          kind: LanNetworkKind.localArea,
          localIp: bestPrivateIp,
          userMessage: '',
        );
      }

      final wifiIp = await _networkInfo.getWifiIP();
      if (wifiIp != null && _isPrivateLan(wifiIp)) {
        return LanNetworkSnapshot(
          kind: LanNetworkKind.localArea,
          localIp: wifiIp,
          userMessage: '',
        );
      }

      if (hasCellularInterface || publicIp != null) {
        return const LanNetworkSnapshot(
          kind: LanNetworkKind.wideArea,
          userMessage: '当前为移动数据或公网环境。局域网联机仅支持连接同一 WiFi 的设备，不支持外网联机。',
        );
      }

      return const LanNetworkSnapshot(
        kind: LanNetworkKind.unavailable,
        userMessage: '未检测到可用局域网，请连接 WiFi 后再试。',
      );
    } catch (_) {
      return const LanNetworkSnapshot(
        kind: LanNetworkKind.unavailable,
        userMessage: '无法读取网络状态，请检查 WiFi 连接。',
      );
    }
  }

  static bool _isPrivateLan(String ip) {
    final parts = ip.split('.');
    if (parts.length != 4) {
      return false;
    }
    final octets = parts.map(int.tryParse).toList();
    if (octets.any((o) => o == null || o < 0 || o > 255)) {
      return false;
    }
    final a = octets[0]!;
    final b = octets[1]!;

    if (a == 10) {
      return true;
    }
    if (a == 172 && b >= 16 && b <= 31) {
      return true;
    }
    if (a == 192 && b == 168) {
      return true;
    }
    return false;
  }

  static bool _isCellularInterface(String name) {
    return name.contains('rmnet') ||
        name.contains('pdp') ||
        name.contains('wwan') ||
        name.contains('cell') ||
        name.contains('lte') ||
        name.contains('5g');
  }

  static int _interfaceScore(String name) {
    if (name.contains('wlan') || name.contains('wifi')) {
      return 100;
    }
    if (name.startsWith('en')) {
      return 90;
    }
    if (name.contains('eth')) {
      return 80;
    }
    if (_isCellularInterface(name)) {
      return 0;
    }
    return 10;
  }
}
