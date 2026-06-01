import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../../core/network/netplay_emulator_session.dart';
import '../../core/network/player_info.dart';

enum NetplayPlayerBarStyle { portrait, fullscreen }

/// Compact P1/P2 circular avatars for netplay.
class NetplayPlayerBar extends StatelessWidget {
  const NetplayPlayerBar({
    super.key,
    required this.session,
    this.style = NetplayPlayerBarStyle.portrait,
  });

  final NetplayEmulatorSession session;
  final NetplayPlayerBarStyle style;

  static const _portraitAvatarSize = 28.0;
  static const _fullscreenAvatarSize = 20.0;

  bool get _isFullscreen => style == NetplayPlayerBarStyle.fullscreen;

  double get _avatarSize =>
      _isFullscreen ? _fullscreenAvatarSize : _portraitAvatarSize;

  @override
  Widget build(BuildContext context) {
    final slots = session.maxPlayers.clamp(2, 4);
    final avatars = [
      for (var i = 0; i < slots; i++)
        _PlayerAvatar(
          slot: i + 1,
          occupant:
              session.slotPlayers.length > i ? session.slotPlayers[i] : null,
          active: session.localPlayerSlot == i + 1,
          size: _avatarSize,
          fullscreen: _isFullscreen,
        ),
    ];

    if (_isFullscreen) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < avatars.length; i++) ...[
            if (i > 0) const SizedBox(width: 5),
            avatars[i],
          ],
        ],
      );
    }

    return DecoratedBox(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.38),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (var i = 0; i < avatars.length; i++) ...[
              if (i > 0) const SizedBox(width: 6),
              avatars[i],
            ],
          ],
        ),
      ),
    );
  }
}

class _PlayerAvatar extends StatelessWidget {
  const _PlayerAvatar({
    required this.slot,
    required this.occupant,
    required this.active,
    required this.size,
    required this.fullscreen,
  });

  final int slot;
  final PlayerInfo? occupant;
  final bool active;
  final double size;
  final bool fullscreen;

  @override
  Widget build(BuildContext context) {
    final occupied = occupant != null;
    final slotLabel = 'P$slot';

    return Tooltip(
      message: occupied ? '${occupant!.name} · P$slot' : 'P$slot 空位',
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: fullscreen
              ? (active
                  ? AppColors.secondary.withValues(alpha: 0.42)
                  : occupied
                      ? Colors.white.withValues(alpha: 0.24)
                      : Colors.white.withValues(alpha: 0.12))
              : (active
                  ? AppColors.secondary.withValues(alpha: 0.28)
                  : occupied
                      ? AppColors.surfaceContainerHigh.withValues(alpha: 0.92)
                      : AppColors.surfaceContainer.withValues(alpha: 0.55)),
          border: Border.all(
            color: fullscreen
                ? (active
                    ? AppColors.secondary.withValues(alpha: 0.95)
                    : occupied
                        ? Colors.white.withValues(alpha: 0.62)
                        : Colors.white.withValues(alpha: 0.28))
                : (active
                    ? AppColors.secondary
                    : occupied
                        ? AppColors.outline
                        : AppColors.outlineVariant.withValues(alpha: 0.7)),
            width: active ? 1.6 : 1,
          ),
        ),
        alignment: Alignment.center,
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2),
            child: Text(
              slotLabel,
              style: TextStyle(
                fontSize: fullscreen ? 9 : 10,
                fontWeight: FontWeight.w700,
                color: fullscreen
                    ? Colors.white.withValues(alpha: active ? 0.98 : 0.82)
                    : (active
                        ? AppColors.secondary
                        : occupied
                            ? AppColors.onSurface
                            : AppColors.onSurfaceVariant
                                .withValues(alpha: 0.65)),
                height: 1,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
