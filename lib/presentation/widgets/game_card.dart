import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../core/libretro/emulator_core_resolver.dart';
import '../../features/game_library/game_library_service.dart';

class GameCard extends StatelessWidget {
  final GameRom game;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;
  final bool compact;
  final bool horizontal;

  const GameCard({
    super.key,
    required this.game,
    this.onTap,
    this.onLongPress,
    this.compact = false,
    this.horizontal = false,
  });

  @override
  Widget build(BuildContext context) {
    if (horizontal) {
      return _buildHorizontalCard(context);
    }
    final radius = compact ? 12.0 : 16.0;
    final infoPadding = compact ? 8.0 : 12.0;
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: AppColors.outlineVariant),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceContainerHigh,
              AppColors.surfaceContainer,
            ],
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.vertical(
                    top: Radius.circular(radius),
                  ),
                  color: AppColors.surfaceContainerHighest,
                ),
                child: _buildThumbnail(radius),
              ),
            ),
            Padding(
              padding: EdgeInsets.all(infoPadding),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.name,
                    style: (compact
                            ? Theme.of(context).textTheme.bodyMedium
                            : Theme.of(context).textTheme.bodyLarge)
                        ?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: compact ? 1 : 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  SizedBox(height: compact ? 2 : 4),
                  Row(
                    children: [
                      Container(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 4 : 6,
                          vertical: 2,
                        ),
                        decoration: BoxDecoration(
                          color: AppColors.surfaceContainerHighest,
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: AppColors.outlineVariant),
                        ),
                        child: Text(
                          _systemLabel(game.extension),
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                fontSize: compact ? 9 : 10,
                                color: AppColors.onSurfaceVariant,
                              ),
                        ),
                      ),
                      if (!compact && game.playCount > 0) ...[
                        const SizedBox(width: 4),
                        Text(
                          '${game.playCount}次',
                          style: Theme.of(context).textTheme.bodySmall
                              ?.copyWith(
                                color: AppColors.onSurfaceVariant,
                                fontSize: 10,
                              ),
                        ),
                      ],
                      const Spacer(),
                      Icon(
                        Icons.play_circle_outline,
                        size: compact ? 16 : 20,
                        color: AppColors.primary,
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalCard(BuildContext context) {
    const radius = 12.0;
    const thumbWidth = 84.0;
    const thumbInset = 8.0;
    const thumbRadius = 10.0;

    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(radius),
          border: Border.all(color: AppColors.outlineVariant),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [
              AppColors.surfaceContainerHigh,
              AppColors.surfaceContainer,
            ],
          ),
        ),
        child: Row(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(
                thumbInset,
                thumbInset,
                0,
                thumbInset,
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(thumbRadius),
                child: SizedBox(
                  width: thumbWidth,
                  height: double.infinity,
                  child: _buildHorizontalThumbnail(),
                ),
              ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(10, 10, 12, 10),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    Text(
                      game.name,
                      style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 6),
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: AppColors.surfaceContainerHighest,
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(color: AppColors.outlineVariant),
                          ),
                          child: Text(
                            _systemLabel(game.extension),
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  fontSize: 10,
                                  color: AppColors.onSurfaceVariant,
                                ),
                          ),
                        ),
                        const Spacer(),
                        const Icon(
                          Icons.play_circle_outline,
                          size: 20,
                          color: AppColors.primary,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHorizontalThumbnail() {
    if (game.thumbnailPath != null) {
      final file = File(game.thumbnailPath!);
      if (file.existsSync()) {
        return Image.file(
          file,
          fit: BoxFit.cover,
          width: double.infinity,
          height: double.infinity,
          errorBuilder: (context, error, stackTrace) =>
              _buildHorizontalPlaceholder(),
        );
      }
    }
    return _buildHorizontalPlaceholder();
  }

  Widget _buildHorizontalPlaceholder() {
    return Container(
      color: AppColors.surfaceContainerHighest,
      child: Center(
        child: Icon(
          _getExtensionIcon(game.extension),
          size: 32,
          color: AppColors.primary.withValues(alpha: 0.6),
        ),
      ),
    );
  }

  Widget _buildThumbnail(double radius) {
    // Check if thumbnail exists
    if (game.thumbnailPath != null) {
      final file = File(game.thumbnailPath!);
      if (file.existsSync()) {
        return ClipRRect(
          borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
          child: Image.file(
            file,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (context, error, stackTrace) {
              return _buildPlaceholder(radius);
            },
          ),
        );
      }
    }

    // Show placeholder
    return _buildPlaceholder(radius);
  }

  Widget _buildPlaceholder(double radius) {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.vertical(top: Radius.circular(radius)),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [
            AppColors.primary.withValues(alpha: 0.3),
            AppColors.surfaceContainerHighest,
          ],
        ),
      ),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _getExtensionIcon(game.extension),
              size: compact ? 28 : 48,
              color: AppColors.primary.withValues(alpha: 0.6),
            ),
            SizedBox(height: compact ? 4 : 8),
            Text(
              game.extension.toUpperCase(),
              style: TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                color: AppColors.onSurfaceVariant.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _systemLabel(String extension) {
    try {
      return EmulatorCoreResolver.resolve('game$extension').system.shortName;
    } catch (_) {
      return extension.replaceAll('.', '').toUpperCase();
    }
  }

  IconData _getExtensionIcon(String extension) {
    switch (extension.toLowerCase()) {
      case '.gba':
        return Icons.gamepad;
      case '.gbc':
        return Icons.gamepad_outlined;
      case '.gb':
        return Icons.gamepad_outlined;
      case '.nes':
      case '.fds':
        return Icons.videogame_asset;
      default:
        return Icons.insert_drive_file;
    }
  }
}
