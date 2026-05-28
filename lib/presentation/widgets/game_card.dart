import 'dart:io';
import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../features/game_library/game_library_service.dart';

class GameCard extends StatelessWidget {
  final GameRom game;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  const GameCard({super.key, required this.game, this.onTap, this.onLongPress});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: Container(
        decoration: BoxDecoration(
          color: AppColors.surfaceContainer,
          borderRadius: BorderRadius.circular(16),
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
            // Game Cover Image
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(16),
                  ),
                  color: AppColors.surfaceContainerHighest,
                ),
                child: _buildThumbnail(),
              ),
            ),

            // Game Info
            Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    game.name,
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 4),
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
                          'GBA',
                          style: Theme.of(context).textTheme.labelLarge
                              ?.copyWith(
                                fontSize: 10,
                                color: AppColors.onSurfaceVariant,
                              ),
                        ),
                      ),
                      if (game.playCount > 0) ...[
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
                        size: 20,
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

  Widget _buildThumbnail() {
    // Check if thumbnail exists
    if (game.thumbnailPath != null) {
      final file = File(game.thumbnailPath!);
      if (file.existsSync()) {
        return ClipRRect(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          child: Image.file(
            file,
            fit: BoxFit.cover,
            width: double.infinity,
            height: double.infinity,
            errorBuilder: (context, error, stackTrace) {
              return _buildPlaceholder();
            },
          ),
        );
      }
    }

    // Show placeholder
    return _buildPlaceholder();
  }

  Widget _buildPlaceholder() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
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
              size: 48,
              color: AppColors.primary.withValues(alpha: 0.6),
            ),
            const SizedBox(height: 8),
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

  IconData _getExtensionIcon(String extension) {
    switch (extension.toLowerCase()) {
      case '.gba':
        return Icons.gamepad;
      case '.gbc':
        return Icons.gamepad_outlined;
      case '.gb':
        return Icons.gamepad_outlined;
      default:
        return Icons.insert_drive_file;
    }
  }
}
