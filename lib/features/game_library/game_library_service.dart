import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/libretro/emulator_core_resolver.dart';
import '../../core/libretro/thumbnail_generator.dart';
import '../../core/storage/storage_paths_service.dart';

/// Supported ROM file extensions (re-exported for UI).
List<String> get supportedRomExtensions =>
    EmulatorCoreResolver.supportedRomExtensions;

/// Result of adding a game to the library.
class AddGameResult {
  final GameRom game;
  final bool isDuplicate;

  const AddGameResult({required this.game, required this.isDuplicate});
}

/// Game ROM entry
class GameRom {
  final String id;
  final String name;
  final String path;
  final String extension;
  final String? md5;
  final String? thumbnailPath;
  final DateTime addedAt;
  final DateTime? lastPlayedAt;
  int playCount;

  GameRom({
    required this.id,
    required this.name,
    required this.path,
    required this.extension,
    this.md5,
    this.thumbnailPath,
    required this.addedAt,
    this.lastPlayedAt,
    this.playCount = 0,
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'path': path,
    'extension': extension,
    'md5': md5,
    'thumbnailPath': thumbnailPath,
    'addedAt': addedAt.toIso8601String(),
    'lastPlayedAt': lastPlayedAt?.toIso8601String(),
    'playCount': playCount,
  };

  factory GameRom.fromJson(Map<String, dynamic> json) => GameRom(
    id: json['id'],
    name: json['name'],
    path: json['path'],
    extension: json['extension'],
    md5: json['md5'] as String?,
    thumbnailPath: json['thumbnailPath'],
    addedAt: DateTime.parse(json['addedAt']),
    lastPlayedAt: json['lastPlayedAt'] != null
        ? DateTime.parse(json['lastPlayedAt'])
        : null,
    playCount: json['playCount'] ?? 0,
  );
}

/// Game library service for managing ROM files.
///
/// Shared singleton — home library and netplay must see the same ROM list.
class GameLibraryService {
  GameLibraryService._();
  static final GameLibraryService instance = GameLibraryService._();
  factory GameLibraryService() => instance;

  static const String _storageKey = 'game_library';
  List<GameRom> _games = [];
  final _gamesController = StreamController<List<GameRom>>.broadcast();
  Future<void> _thumbnailQueue = Future.value();
  Future<void>? _initFuture;
  bool _hydrated = false;
  bool _maintenanceStarted = false;

  List<GameRom> get games => List.unmodifiable(_games);
  Stream<List<GameRom>> get gamesStream => _gamesController.stream;

  /// Initialize and load saved games.
  Future<void> init({bool refreshThumbnails = true}) {
    return _initFuture ??= _initImpl(refreshThumbnails).whenComplete(() {
      _initFuture = null;
    });
  }

  Future<void> _initImpl(bool refreshThumbnails) async {
    if (!_hydrated) {
      await _loadGames();
      _hydrated = true;
    }
    _notifyGamesChanged();
    _startDeferredMaintenance(refreshThumbnails);
  }

  void _startDeferredMaintenance(bool refreshThumbnails) {
    if (_maintenanceStarted) {
      return;
    }
    _maintenanceStarted = true;
    unawaited(_runDeferredMaintenance(refreshThumbnails));
  }

  Future<void> _runDeferredMaintenance(bool refreshThumbnails) async {
    await _repairStoredRomPaths();
    await _backfillMissingMd5();
    final before = _games.length;
    _dedupeGames();
    if (_games.length != before) {
      await _saveGames();
      _notifyGamesChanged();
    }
    if (refreshThumbnails) {
      _refreshThumbnails();
    }
  }

  /// Pick and add a ROM file
  Future<AddGameResult?> addGame() async {
    try {
      // iOS cannot map .gba/.nes to stable UTIs (file_picker skips dyn.* types),
      // so use FileType.any and validate the extension in Dart instead.
      final romExtensions = supportedRomExtensions
          .map((e) => e.replaceFirst('.', ''))
          .toList();
      final result = await FilePicker.pickFiles(
        type: Platform.isIOS ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isIOS ? null : romExtensions,
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return null;

      final file = result.files.first;
      final path = file.path;
      if (path == null) {
        throw Exception('无法读取所选文件');
      }

      return addGameFromPath(path);
    } catch (e) {
      print('Error adding game: $e');
      rethrow;
    }
  }

  /// Add game from file path
  Future<AddGameResult?> addGameFromPath(String path) async {
    try {
      path = await _persistImportedRom(path);
      final file = File(path);
      if (!await file.exists()) {
        throw Exception('文件不存在: $path');
      }

      final extension = '.${path.split('.').last.toLowerCase()}';
      if (!supportedRomExtensions.contains(extension)) {
        throw Exception('不支持的文件格式: $extension');
      }

      final fileName = path.split('/').last;
      final name = _extractFileName(fileName);
      final md5Hash = await _computeFileMd5(path);
      final duplicate = await _findDuplicateByMd5(md5Hash);
      if (duplicate != null) {
        await _ensureGamePathPersisted(duplicate.id, path);
        final updated = getGame(duplicate.id) ?? duplicate;
        if (!_hasValidThumbnail(updated)) {
          _queueGenerateThumbnail(updated);
        }
        return AddGameResult(game: updated, isDuplicate: true);
      }

      final game = GameRom(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: name,
        path: path,
        extension: extension,
        md5: md5Hash,
        addedAt: DateTime.now(),
      );

      _games.add(game);
      await _saveGames();
      _notifyGamesChanged();
      _queueGenerateThumbnail(game);

      return AddGameResult(game: game, isDuplicate: false);
    } catch (e) {
      print('Error adding game from path: $e');
      rethrow;
    }
  }

  /// Remove a game
  Future<void> removeGame(String gameId) async {
    await ThumbnailGenerator.deleteThumbnail(gameId);
    _games.removeWhere((g) => g.id == gameId);
    await _saveGames();
    _notifyGamesChanged();
  }

  /// Update game last played time (in-memory immediately, disk write in background).
  Future<void> updateLastPlayed(String gameId) async {
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index >= 0) {
      final game = _games[index];
      _games[index] = _copyGame(
        game,
        lastPlayedAt: DateTime.now(),
        playCount: game.playCount + 1,
      );
      _notifyGamesChanged();
      unawaited(_saveGames());
    }
  }

  /// Get game by ID
  GameRom? getGame(String gameId) {
    try {
      return _games.firstWhere((g) => g.id == gameId);
    } catch (e) {
      return null;
    }
  }

  /// Find a library entry by ROM MD5 hash.
  GameRom? findGameByMd5(String md5Hash) {
    if (md5Hash.isEmpty) {
      return null;
    }
    try {
      return _games.firstWhere((g) => g.md5 == md5Hash);
    } catch (_) {
      return null;
    }
  }

  /// Whether a playable ROM with the given MD5 exists locally.
  Future<bool> hasLocalRom(String md5Hash) async {
    final game = findGameByMd5(md5Hash);
    if (game == null) {
      return false;
    }
    return (await resolvePlayableRomPath(game.path, md5: md5Hash)) != null;
  }

  /// Save a received ROM into the library folder, replacing same-name files.
  Future<AddGameResult?> importNetplayRom({
    required List<int> bytes,
    required String fileName,
  }) async {
    if (bytes.isEmpty) {
      throw Exception('ROM 数据为空');
    }

    final romsDir = await StoragePathsService.getRomsDirectory();
    final destPath = _netplayRomDestPath(romsDir.path, fileName);
    await File(destPath).writeAsBytes(bytes, flush: true);

    final destName = destPath.split(Platform.pathSeparator).last;
    final existingIndex = _games.indexWhere((game) {
      final name = game.path.split(Platform.pathSeparator).last;
      return game.path == destPath || name == destName;
    });
    if (existingIndex >= 0) {
      final md5Hash = await _computeFileMd5(destPath);
      final duplicateByMd5 = await _findDuplicateByMd5(md5Hash);
      final existing = _games[existingIndex];

      if (duplicateByMd5 != null && duplicateByMd5.id != existing.id) {
        _games.removeAt(existingIndex);
        await _ensureGamePathPersisted(duplicateByMd5.id, destPath);
        final updated = getGame(duplicateByMd5.id) ?? duplicateByMd5;
        _notifyGamesChanged();
        if (!_hasValidThumbnail(updated)) {
          _queueGenerateThumbnail(updated);
        }
        return AddGameResult(game: updated, isDuplicate: true);
      }

      final updated = _copyGame(existing, path: destPath, md5: md5Hash);
      _games[existingIndex] = updated;
      await _saveGames();
      _notifyGamesChanged();
      _queueGenerateThumbnail(updated);
      return AddGameResult(game: updated, isDuplicate: true);
    }

    return addGameFromPath(destPath);
  }

  String _netplayRomDestPath(String romsDirPath, String fileName) {
    final safeName = _safeRomFileName(fileName.split(RegExp(r'[/\\]')).last);
    var extension = '.${safeName.split('.').last.toLowerCase()}';
    if (!supportedRomExtensions.contains(extension)) {
      throw Exception('不支持的 ROM 格式: $extension');
    }

    var destName = safeName;
    if (!destName.toLowerCase().endsWith(extension)) {
      destName = '$destName$extension';
    }

    var destPath = '$romsDirPath/$destName';
    return destPath;
  }

  /// Check if ROM file exists
  Future<bool> isRomExists(String path, {String? md5}) async {
    return resolvePlayableRomPath(path, md5: md5) != null;
  }

  /// Returns a path that exists on disk, repairing the library entry when possible.
  Future<String?> resolvePlayableRomPath(String path, {String? md5}) async {
    if (await File(path).exists()) {
      return path;
    }

    final resolved = await _findRomInLibrary(
      fileName: path.split(Platform.pathSeparator).last,
      md5: md5,
    );
    if (resolved == null) {
      return null;
    }

    final index = _games.indexWhere((g) => g.path == path);
    if (index >= 0 && _games[index].path != resolved) {
      _games[index] = _gameWithPath(_games[index], resolved);
      await _saveGames();
      _notifyGamesChanged();
    }

    return resolved;
  }

  Future<String> _computeFileMd5(String path) async {
    final digest = await md5.bind(File(path).openRead()).first;
    return digest.toString();
  }

  Future<GameRom?> _findDuplicateByMd5(String md5Hash) async {
    for (final game in _games) {
      if (game.md5 == md5Hash) {
        return game;
      }
    }

    for (var i = 0; i < _games.length; i++) {
      final game = _games[i];
      if (game.md5 != null) {
        continue;
      }

      try {
        if (!await File(game.path).exists()) {
          continue;
        }
        final existingMd5 = await _computeFileMd5(game.path);
        _games[i] = _copyGame(game, md5: existingMd5);
        if (existingMd5 == md5Hash) {
          await _saveGames();
          return _games[i];
        }
      } catch (_) {}
    }

    return null;
  }

  Future<void> _backfillMissingMd5() async {
    var changed = false;

    for (var i = 0; i < _games.length; i++) {
      final game = _games[i];
      if (game.md5 != null && game.md5!.isNotEmpty) {
        continue;
      }

      try {
        if (!await File(game.path).exists()) {
          continue;
        }
        final hash = await _computeFileMd5(game.path);
        _games[i] = _copyGame(game, md5: hash);
        changed = true;
      } catch (_) {}
    }

    if (changed) {
      await _saveGames();
    }
  }

  void _dedupeGames() {
    final uniqueByMd5 = <String, GameRom>{};
    final fallback = <String, GameRom>{};

    for (final game in _games) {
      final md5Hash = game.md5;
      if (md5Hash != null && md5Hash.isNotEmpty) {
        uniqueByMd5.putIfAbsent(md5Hash, () => game);
        continue;
      }

      fallback.putIfAbsent(game.path, () => game);
    }

    _games = [...uniqueByMd5.values, ...fallback.values];
  }

  Future<void> _generateThumbnail(GameRom game) async {
    try {
      final thumbnailPath = await ThumbnailGenerator.generateThumbnail(
        game.path,
        game.id,
      );

      if (thumbnailPath != null) {
        final index = _games.indexWhere((g) => g.id == game.id);
        if (index >= 0) {
          _games[index] = _copyGame(
            _games[index],
            thumbnailPath: thumbnailPath,
          );
          await _saveGames();
          _notifyGamesChanged();
        }
      }
    } catch (e) {
      print('Error generating thumbnail: $e');
    }
  }

  /// On iOS, copy imports into Documents/ROMs (tmp/Inbox is cleared on restart).
  Future<String> _persistImportedRom(String path) async {
    if (!Platform.isIOS) {
      return path;
    }
    return _copyRomToLibrary(path);
  }

  /// Fix library entries that still point at ephemeral iOS paths.
  Future<void> _repairStoredRomPaths() async {
    if (!Platform.isIOS) {
      return;
    }

    var changed = false;
    final romsDir = await StoragePathsService.getRomsDirectory();

    for (var i = 0; i < _games.length; i++) {
      final game = _games[i];
      final file = File(game.path);

      if (await file.exists()) {
        if (!game.path.startsWith(romsDir.path)) {
          try {
            final stablePath = await _copyRomToLibrary(game.path);
            if (stablePath != game.path) {
              _games[i] = _gameWithPath(game, stablePath);
              changed = true;
            }
          } catch (_) {}
        }
        continue;
      }

      final resolved = await _findRomInLibrary(
        fileName: game.path.split('/').last,
        md5: game.md5,
      );
      if (resolved != null) {
        _games[i] = _gameWithPath(game, resolved);
        changed = true;
      }
    }

    if (changed) {
      await _saveGames();
    }
  }

  Future<void> _ensureGamePathPersisted(String gameId, String sourcePath) async {
    if (!Platform.isIOS) {
      return;
    }

    final index = _games.indexWhere((g) => g.id == gameId);
    if (index < 0 || !await File(sourcePath).exists()) {
      return;
    }

    try {
      final stablePath = await _copyRomToLibrary(sourcePath);
      if (stablePath != _games[index].path) {
        _games[index] = _gameWithPath(_games[index], stablePath);
        await _saveGames();
      }
    } catch (_) {}
  }

  Future<String> _copyRomToLibrary(String sourcePath) async {
    final romsDir = await StoragePathsService.getRomsDirectory();
    if (sourcePath.startsWith(romsDir.path)) {
      return sourcePath;
    }

    final source = File(sourcePath);
    if (!await source.exists()) {
      throw Exception('文件不存在: $sourcePath');
    }

    final fileName = _safeRomFileName(sourcePath.split('/').last);
    final dest = File('${romsDir.path}/$fileName');
    if (await dest.exists()) {
      return dest.path;
    }
    await source.copy(dest.path);
    return dest.path;
  }

  Future<String?> _findRomInLibrary({
    required String fileName,
    String? md5,
  }) async {
    final romsDir = await StoragePathsService.getRomsDirectory();
    final names = {fileName, _safeRomFileName(fileName)};

    for (final name in names) {
      final candidate = File('${romsDir.path}/$name');
      if (!await candidate.exists()) {
        continue;
      }
      if (md5 == null) {
        return candidate.path;
      }
      try {
        if (await _computeFileMd5(candidate.path) == md5) {
          return candidate.path;
        }
      } catch (_) {}
    }

    if (md5 == null) {
      return null;
    }

    try {
      await for (final entity in romsDir.list()) {
        if (entity is! File) {
          continue;
        }
        try {
          if (await _computeFileMd5(entity.path) == md5) {
            return entity.path;
          }
        } catch (_) {}
      }
    } catch (_) {}

    return null;
  }

  GameRom _copyGame(
    GameRom game, {
    String? path,
    String? md5,
    String? thumbnailPath,
    DateTime? lastPlayedAt,
    int? playCount,
  }) =>
      GameRom(
        id: game.id,
        name: game.name,
        path: path ?? game.path,
        extension: game.extension,
        md5: md5 ?? game.md5,
        thumbnailPath: thumbnailPath ?? game.thumbnailPath,
        addedAt: game.addedAt,
        lastPlayedAt: lastPlayedAt ?? game.lastPlayedAt,
        playCount: playCount ?? game.playCount,
      );

  GameRom _gameWithPath(GameRom game, String path) => _copyGame(game, path: path);

  String _safeRomFileName(String fileName) {
    return fileName.replaceAll(RegExp(r'[<>:"/\\|?*]'), '_').trim();
  }

  String _extractFileName(String fileName) {
    final lastDot = fileName.lastIndexOf('.');
    if (lastDot > 0) {
      return fileName.substring(0, lastDot);
    }
    return fileName;
  }

  Future<void> _saveGames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = jsonEncode(_games.map((g) => g.toJson()).toList());
      await prefs.setString(_storageKey, json);
    } catch (e) {
      print('Error saving games: $e');
    }
  }

  Future<void> _loadGames() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final json = prefs.getString(_storageKey);
      if (json != null) {
        final List<dynamic> list = jsonDecode(json);
        _games = list.map((item) => GameRom.fromJson(item)).toList();
      }
    } catch (e) {
      print('Error loading games: $e');
      _games = [];
    }
  }

  void _notifyGamesChanged() {
    if (!_gamesController.isClosed) {
      _gamesController.add(games);
    }
  }

  void _refreshThumbnails() {
    for (final game in _games) {
      _queueGenerateThumbnail(game);
    }
  }

  void _queueGenerateThumbnail(GameRom game) {
    _thumbnailQueue = _thumbnailQueue.then((_) => _generateThumbnail(game));
  }

  bool _hasValidThumbnail(GameRom game) {
    final thumbnailPath = game.thumbnailPath;
    return thumbnailPath != null && File(thumbnailPath).existsSync();
  }

  void dispose() {
    _gamesController.close();
  }
}
