import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:file_picker/file_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../core/libretro/thumbnail_generator.dart';

/// Supported GBA ROM file extensions
const List<String> supportedRomExtensions = ['.gba', '.gbc', '.gb'];

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

/// Game library service for managing ROM files
class GameLibraryService {
  static const String _storageKey = 'game_library';
  List<GameRom> _games = [];
  final _gamesController = StreamController<List<GameRom>>.broadcast();
  Future<void> _thumbnailQueue = Future.value();

  List<GameRom> get games => List.unmodifiable(_games);
  Stream<List<GameRom>> get gamesStream => _gamesController.stream;

  /// Initialize and load saved games
  Future<void> init() async {
    await _loadGames();
    await _backfillMissingMd5();
    final before = _games.length;
    _dedupeGames();
    if (_games.length != before) {
      await _saveGames();
    }
    _notifyGamesChanged();
    _refreshThumbnails();
  }

  /// Pick and add a ROM file
  Future<AddGameResult?> addGame() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: supportedRomExtensions
            .map((e) => e.replaceFirst('.', ''))
            .toList(),
        allowMultiple: false,
      );

      if (result == null || result.files.isEmpty) return null;

      final file = result.files.first;
      if (file.path == null) return null;

      return addGameFromPath(file.path!);
    } catch (e) {
      print('Error adding game: $e');
      rethrow;
    }
  }

  /// Add game from file path
  Future<AddGameResult?> addGameFromPath(String path) async {
    try {
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
        if (!_hasValidThumbnail(duplicate)) {
          _queueGenerateThumbnail(duplicate);
        }
        return AddGameResult(game: duplicate, isDuplicate: true);
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

  /// Update game last played time
  Future<void> updateLastPlayed(String gameId) async {
    final index = _games.indexWhere((g) => g.id == gameId);
    if (index >= 0) {
      final game = _games[index];
      _games[index] = GameRom(
        id: game.id,
        name: game.name,
        path: game.path,
        extension: game.extension,
        md5: game.md5,
        thumbnailPath: game.thumbnailPath,
        addedAt: game.addedAt,
        lastPlayedAt: DateTime.now(),
        playCount: game.playCount + 1,
      );
      await _saveGames();
      _notifyGamesChanged();
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

  /// Check if ROM file exists
  Future<bool> isRomExists(String path) async {
    return File(path).exists();
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
        _games[i] = GameRom(
          id: game.id,
          name: game.name,
          path: game.path,
          extension: game.extension,
          md5: existingMd5,
          thumbnailPath: game.thumbnailPath,
          addedAt: game.addedAt,
          lastPlayedAt: game.lastPlayedAt,
          playCount: game.playCount,
        );
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
        _games[i] = GameRom(
          id: game.id,
          name: game.name,
          path: game.path,
          extension: game.extension,
          md5: hash,
          thumbnailPath: game.thumbnailPath,
          addedAt: game.addedAt,
          lastPlayedAt: game.lastPlayedAt,
          playCount: game.playCount,
        );
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
          final current = _games[index];
          _games[index] = GameRom(
            id: current.id,
            name: current.name,
            path: current.path,
            extension: current.extension,
            md5: current.md5,
            thumbnailPath: thumbnailPath,
            addedAt: current.addedAt,
            lastPlayedAt: current.lastPlayedAt,
            playCount: current.playCount,
          );
          await _saveGames();
          _notifyGamesChanged();
        }
      }
    } catch (e) {
      print('Error generating thumbnail: $e');
    }
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
