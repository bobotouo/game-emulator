import 'dart:convert';
import 'dart:io';

import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';

/// Resolves user-accessible storage paths for saves and related data.
///
/// - Android: `/storage/emulated/0/GBAEmulator/` (public phone storage)
/// - iOS: `Documents/Saves/` (visible in Files app under "On My iPhone")
class StoragePathsService {
  StoragePathsService._();

  static const appFolderName = 'GBAEmulator';
  static const savesFolderName = 'Saves';
  static const romsFolderName = 'ROMs';
  static const androidPublicRoot = '/storage/emulated/0/$appFolderName';

  static Directory? _saveStatesDir;
  static Directory? _inGameSavesDir;

  /// Request Android storage permission needed for public folder access.
  static Future<bool> ensureStorageAccess() async {
    if (!Platform.isAndroid) return true;

    if (await Permission.storage.isGranted ||
        await Permission.manageExternalStorage.isGranted) {
      return true;
    }

    final storage = await Permission.storage.request();
    if (storage.isGranted) return true;

    final manage = await Permission.manageExternalStorage.request();
    return manage.isGranted;
  }

  /// Directory for auto save states (`.state` files).
  static Future<Directory> getSaveStatesDirectory() async {
    if (_saveStatesDir != null) return _saveStatesDir!;

    final root = await _getAccessibleRootDirectory();
    final dir = Directory('${root.path}/save_states');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    await _migrateLegacySaves(dir);
    _saveStatesDir = dir;
    return dir;
  }

  /// Permanent ROM storage (iOS file picker imports land in tmp otherwise).
  static Future<Directory> getRomsDirectory() async {
    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$romsFolderName');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }

    final root = await _getAccessibleRootDirectory();
    final dir = Directory('${root.path}/roms');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  /// Directory for in-game saves (`.sav` files written by the game itself).
  static Future<Directory> getInGameSavesDirectory() async {
    if (_inGameSavesDir != null) return _inGameSavesDir!;

    final root = await _getAccessibleRootDirectory();
    final dir = Directory('${root.path}/in_game_saves');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    _inGameSavesDir = dir;
    return dir;
  }

  /// Absolute path shown in settings.
  static Future<String> getSaveStatesPath() async {
    final dir = await getSaveStatesDirectory();
    return dir.path;
  }

  /// Build save-state filename from stable game library id.
  static String saveStateFileNameForGame(String gameId) => '$gameId.state';

  /// Build a readable save-state filename from the ROM path (legacy).
  static String saveStateFileName(String romPath) {
    final baseName = _basenameWithoutExtension(romPath);
    final sanitized = baseName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
    return '${sanitized.isEmpty ? 'game' : sanitized}.state';
  }

  /// Resolve the save-state file for writing.
  static Future<File> saveStateFileForGame({
    required String gameId,
    required String romPath,
  }) async {
    final saveDir = await getSaveStatesDirectory();
    return File('${saveDir.path}/${saveStateFileNameForGame(gameId)}');
  }

  /// Resolve the save-state file for a ROM, migrating legacy sandbox saves if needed.
  static Future<File> saveStateFileForRom(String romPath) async {
    final file = await findSaveStateFile(romPath);
    if (file != null) return file;

    final saveDir = await getSaveStatesDirectory();
    return File('${saveDir.path}/${saveStateFileName(romPath)}');
  }

  /// Find an existing save-state file for a game.
  static Future<File?> findSaveStateFile(
    String romPath, {
    String? gameId,
  }) async {
    final saveDir = await getSaveStatesDirectory();
    if (!await saveDir.exists()) return null;

    if (gameId != null) {
      final byId = File('${saveDir.path}/${saveStateFileNameForGame(gameId)}');
      if (await byId.exists()) return byId;
    }

    final expectedName = saveStateFileName(romPath);
    final expected = File('${saveDir.path}/$expectedName');
    if (await expected.exists()) {
      return _migrateToGameIdIfNeeded(expected, saveDir, gameId);
    }

    final legacyFile = await _legacySaveStateFile(romPath);
    if (await legacyFile.exists()) {
      final target = gameId != null
          ? File('${saveDir.path}/${saveStateFileNameForGame(gameId)}')
          : expected;
      if (!await target.exists()) {
        await legacyFile.copy(target.path);
      }
      return target;
    }

    final baseKey = _saveKeyFromRomPath(romPath);
    await for (final entity in saveDir.list()) {
      if (entity is! File || !entity.path.endsWith('.state')) continue;
      final name = _basenameWithoutExtension(entity.path).toLowerCase();
      if (name == baseKey) {
        return _migrateToGameIdIfNeeded(entity, saveDir, gameId);
      }
    }

    return null;
  }

  static Future<File> _migrateToGameIdIfNeeded(
    File source,
    Directory saveDir,
    String? gameId,
  ) async {
    if (gameId == null) return source;

    final target = File('${saveDir.path}/${saveStateFileNameForGame(gameId)}');
    if (!await target.exists()) {
      await source.copy(target.path);
    }
    return target;
  }

  static String _saveKeyFromRomPath(String romPath) {
    final baseName = _basenameWithoutExtension(romPath);
    return baseName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim().toLowerCase();
  }

  static Future<Directory> _getAccessibleRootDirectory() async {
    if (Platform.isAndroid) {
      await ensureStorageAccess();

      for (final path in [androidPublicRoot, '/sdcard/$appFolderName']) {
        try {
          final dir = Directory(path);
          if (!await dir.exists()) {
            await dir.create(recursive: true);
          }
          final test = File('${dir.path}/.write_test');
          await test.writeAsString('ok', flush: true);
          await test.delete();
          return dir;
        } catch (_) {
          continue;
        }
      }

      throw StateError(
        '无法写入公共存储目录 $androidPublicRoot，请在系统设置中授予「所有文件访问」权限后重试',
      );
    }

    if (Platform.isIOS) {
      final docs = await getApplicationDocumentsDirectory();
      final dir = Directory('${docs.path}/$savesFolderName');
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      return dir;
    }

    final docs = await getApplicationDocumentsDirectory();
    final dir = Directory('${docs.path}/$appFolderName');
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    return dir;
  }

  static Future<void> _migrateLegacySaves(Directory targetDir) async {
    final sources = <Directory>[];

    final appDir = await getApplicationDocumentsDirectory();
    sources.add(Directory('${appDir.path}/save_states'));

    final downloads = await getDownloadsDirectory();
    if (downloads != null) {
      sources.add(Directory('${downloads.path}/$appFolderName/save_states'));
    }

    for (final source in sources) {
      if (!await source.exists()) continue;
      await for (final entity in source.list()) {
        if (entity is! File || !entity.path.endsWith('.state')) continue;
        final dest = File('${targetDir.path}/${entity.uri.pathSegments.last}');
        if (!await dest.exists()) {
          try {
            await entity.copy(dest.path);
          } catch (_) {}
        }
      }
    }
  }

  static Future<File> _legacySaveStateFile(String romPath) async {
    final appDir = await getApplicationDocumentsDirectory();
    final saveDir = Directory('${appDir.path}/save_states');
    final id = base64Url.encode(utf8.encode(romPath)).replaceAll('=', '');
    return File('${saveDir.path}/$id.state');
  }

  static String _basenameWithoutExtension(String filePath) {
    final name = filePath.split('/').last.split(r'\').last;
    final dotIndex = name.lastIndexOf('.');
    if (dotIndex > 0) {
      return name.substring(0, dotIndex);
    }
    return name;
  }
}
