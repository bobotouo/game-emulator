import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/network/lan_service.dart';
import 'emulator_screen.dart';

/// Multiplayer game screen — FC/NES uses lockstep netplay.
class NetplayEmulatorScreen extends StatefulWidget {
  const NetplayEmulatorScreen({
    super.key,
    this.romPath,
    this.romExtension,
    required this.netplayService,
    this.gameId,
    required this.isHost,
    this.resumeSaveState,
  });

  final String? romPath;
  final String? romExtension;
  final String? gameId;
  final NetplayService netplayService;
  final bool isHost;
  final Uint8List? resumeSaveState;

  @override
  State<NetplayEmulatorScreen> createState() => _NetplayEmulatorScreenState();
}

class _NetplayEmulatorScreenState extends State<NetplayEmulatorScreen> {
  late NetplayEmulatorSession _session;
  StreamSubscription<NetplayRoomState>? _roomStateSub;
  StreamSubscription<RoomInfo>? _hostPromotedSub;

  String? get _effectiveExtension =>
      widget.romExtension ??
      netplayExtensionFromPath(widget.romPath) ??
      netplayExtensionFromPath(
        widget.netplayService.activeRoom?.gameCode,
      );

  bool get _useLockstepNetplay =>
      isHostAuthoritativeNetplayExtension(_effectiveExtension);

  @override
  void initState() {
    super.initState();
    _session = NetplayEmulatorSession.fromNetplay(
      netplay: widget.netplayService,
      isHost: widget.isHost,
    );
    _roomStateSub =
        widget.netplayService.onRoomStateChanged.listen((_) => _syncSession());
    _hostPromotedSub = widget.netplayService.onHostPromoted.listen((_) {
      if (mounted) {
        widget.netplayService.markHostPromotionExit();
        Navigator.of(context).pop(false);
      }
    });
  }

  @override
  void dispose() {
    _roomStateSub?.cancel();
    _hostPromotedSub?.cancel();
    if (widget.netplayService.consumeDeferGameExitToRoomScreen()) {
      // Room screen handles leave / return to lobby.
    } else if (widget.netplayService.consumeExitingForReplacement()) {
      // Host keeps the room open while waiting for a replacement player.
    } else if (widget.netplayService.consumeHostPromotionExit()) {
      // Promoted to host — session continues in room screen.
    } else if (widget.netplayService.isHost) {
      widget.netplayService.exitGameAndHandoffHost();
    } else {
      widget.netplayService.exitGameAndLeaveRoom();
    }
    super.dispose();
  }

  void _syncSession() {
    if (!mounted) {
      return;
    }
    setState(() {
      _session = NetplayEmulatorSession.fromNetplay(
        netplay: widget.netplayService,
        isHost: widget.isHost,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return EmulatorScreen(
      romPath: widget.romPath ?? '',
      romExtension: _effectiveExtension,
      gameId: widget.gameId,
      useLockstepNetplay: _useLockstepNetplay,
      netplayService: widget.netplayService,
      isNetplayHost: widget.netplayService.isHost,
      netplaySession: _session,
      resumeSaveState: widget.resumeSaveState,
    );
  }
}
