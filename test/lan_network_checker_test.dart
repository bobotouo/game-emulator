import 'package:flutter_test/flutter_test.dart';
import 'package:gba_emulator/core/network/lan_network_checker.dart';

void main() {
  test('wideArea snapshot is not LAN-ready and explains WiFi requirement', () {
    const snapshot = LanNetworkSnapshot(
      kind: LanNetworkKind.wideArea,
      userMessage: '当前为移动数据或公网环境。局域网联机仅支持连接同一 WiFi 的设备，不支持外网联机。',
    );
    expect(snapshot.canUseLanLobby, isFalse);
    expect(snapshot.userMessage, contains('WiFi'));
  });
}
