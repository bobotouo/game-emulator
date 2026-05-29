import 'dart:async';

import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../widgets/game_card.dart';
import '../../features/game_library/game_library_service.dart';
import 'emulator_screen.dart';

class GameLibraryScreen extends StatefulWidget {
  const GameLibraryScreen({super.key});

  @override
  State<GameLibraryScreen> createState() => _GameLibraryScreenState();
}

class _GameLibraryScreenState extends State<GameLibraryScreen> {
  final GameLibraryService _libraryService = GameLibraryService();
  final TextEditingController _searchController = TextEditingController();
  List<GameRom> _games = [];
  bool _isLoading = true;
  String _selectedCategory = '全部';
  String _searchQuery = '';
  StreamSubscription<List<GameRom>>? _gamesSubscription;

  @override
  void initState() {
    super.initState();
    _gamesSubscription = _libraryService.gamesStream.listen((games) {
      if (mounted) {
        setState(() {
          _games = games;
        });
      }
    });
    _loadGames();
  }

  @override
  void dispose() {
    _gamesSubscription?.cancel();
    _searchController.dispose();
    _libraryService.dispose();
    super.dispose();
  }

  Future<void> _loadGames() async {
    setState(() => _isLoading = true);
    await _libraryService.init();
    setState(() {
      _games = _libraryService.games;
      _isLoading = false;
    });
  }

  Future<void> _addGame() async {
    try {
      final result = await _libraryService.addGame();
      if (result == null) return;

      setState(() {
        _games = _libraryService.games;
      });

      if (!mounted) return;

      final message = result.isDuplicate
          ? '该游戏已在库中: ${result.game.name}'
          : '已添加: ${result.game.name}';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(message),
          backgroundColor: result.isDuplicate
              ? AppColors.onSurfaceVariant
              : AppColors.secondary,
        ),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('添加失败: $e'), backgroundColor: AppColors.error),
        );
      }
    }
  }

  Future<void> _launchGame(GameRom game) async {
    final romPath = await _libraryService.resolvePlayableRomPath(
      game.path,
      md5: game.md5,
    );
    if (romPath == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('ROM 文件不存在，请重新添加: ${game.name}'),
            backgroundColor: AppColors.error,
          ),
        );
      }
      return;
    }

    // Update last played
    await _libraryService.updateLastPlayed(game.id);

    // Navigate to emulator screen
    if (mounted) {
      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (context) => EmulatorScreen(
            romPath: romPath,
            gameId: game.id,
          ),
        ),
      ).then((_) {
        // Refresh game list when returning
        setState(() {
          _games = _libraryService.games;
        });
      });
    }
  }

  Future<void> _removeGame(GameRom game) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认删除'),
        content: Text('确定要删除 "${game.name}" 吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('删除', style: TextStyle(color: AppColors.error)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _libraryService.removeGame(game.id);
      setState(() {
        _games = _libraryService.games;
      });
    }
  }

  List<GameRom> get _filteredGames {
    List<GameRom> filtered;

    switch (_selectedCategory) {
      case '最近游玩':
        filtered = _games.where((g) => g.lastPlayedAt != null).toList()
          ..sort((a, b) => b.lastPlayedAt!.compareTo(a.lastPlayedAt!));
      default:
        filtered = List<GameRom>.from(_games);
    }

    final query = _searchQuery.trim().toLowerCase();
    if (query.isEmpty) {
      return filtered;
    }

    return filtered
        .where((game) => game.name.toLowerCase().contains(query))
        .toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      appBar: AppBar(
        title: const Text('游戏库'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            onPressed: _addGame,
            tooltip: '添加游戏',
          ),
        ],
      ),
      body: Column(
        children: [
          SizedBox(height: MediaQuery.paddingOf(context).top + kToolbarHeight),
          // Search Bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              onChanged: (value) {
                setState(() {
                  _searchQuery = value;
                });
              },
              decoration: InputDecoration(
                hintText: '搜索游戏...',
                hintStyle: TextStyle(color: AppColors.onSurfaceVariant),
                prefixIcon: const Icon(
                  Icons.search,
                  color: AppColors.onSurfaceVariant,
                ),
                suffixIcon: _searchQuery.isEmpty
                    ? null
                    : IconButton(
                        icon: const Icon(Icons.close),
                        color: AppColors.onSurfaceVariant,
                        tooltip: '清空搜索',
                        onPressed: () {
                          _searchController.clear();
                          setState(() {
                            _searchQuery = '';
                          });
                        },
                      ),
                filled: true,
                fillColor: AppColors.surfaceContainerLow,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.outlineVariant),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppColors.outlineVariant),
                ),
              ),
            ),
          ),

          // Category Chips
          SizedBox(
            height: 40,
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [_buildCategoryChip('全部'), _buildCategoryChip('最近游玩')],
            ),
          ),

          const SizedBox(height: 16),

          // Game List
          Expanded(
            child: _isLoading
                ? const Center(child: CircularProgressIndicator())
                : _filteredGames.isEmpty
                ? _buildEmptyState(
                    isSearchResult: _searchQuery.trim().isNotEmpty,
                  )
                : _buildGameList(),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState({bool isSearchResult = false}) {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.gamepad_outlined,
            size: 80,
            color: AppColors.onSurfaceVariant.withValues(alpha: 0.3),
          ),
          const SizedBox(height: 16),
          Text(
            isSearchResult ? '未找到游戏' : '暂无游戏',
            style: Theme.of(context).textTheme.headlineSmall?.copyWith(
              color: AppColors.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            isSearchResult ? '换个名字试试' : '点击右上角 + 添加 ROM 文件',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              color: AppColors.onSurfaceVariant.withValues(alpha: 0.7),
            ),
          ),
          if (!isSearchResult) ...[
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: _addGame,
              icon: const Icon(Icons.add),
              label: const Text('添加游戏'),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildGameList() {
    return GridView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 0.75,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
      ),
      itemCount: _filteredGames.length,
      itemBuilder: (context, index) {
        final game = _filteredGames[index];
        return GameCard(
          game: game,
          onTap: () => _launchGame(game),
          onLongPress: () => _removeGame(game),
        );
      },
    );
  }

  Widget _buildCategoryChip(String label) {
    final isSelected = _selectedCategory == label;
    return Container(
      margin: const EdgeInsets.only(right: 8),
      child: GestureDetector(
        onTap: () {
          setState(() {
            _selectedCategory = label;
          });
        },
        child: Chip(
          label: Text(
            label,
            style: TextStyle(
              color: isSelected
                  ? AppColors.onPrimary
                  : AppColors.onSurfaceVariant,
              fontSize: 12,
            ),
          ),
          backgroundColor: isSelected
              ? AppColors.primary
              : AppColors.surfaceContainer,
          side: BorderSide(
            color: isSelected ? AppColors.primary : AppColors.outlineVariant,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
      ),
    );
  }
}
