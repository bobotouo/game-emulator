import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'presentation/theme/app_theme.dart';
import 'presentation/theme/system_ui.dart';
import 'presentation/screens/game_library_screen.dart';
import 'presentation/screens/multiplayer_lobby_screen.dart';
import 'presentation/screens/settings_screen.dart';
import 'core/settings/app_settings_service.dart';
import 'core/storage/storage_paths_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  AppSystemUi.apply();
  await AppSettingsService.instance.init();
  await StoragePathsService.ensureStorageAccess();
  runApp(const ProviderScope(child: GBAEmulatorApp()));
}

class GBAEmulatorApp extends StatelessWidget {
  const GBAEmulatorApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GBA Emulator',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.darkTheme,
      home: const MainScreen(),
    );
  }
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _currentIndex = 0;

  final List<Widget> _screens = [
    const GameLibraryScreen(),
    const MultiplayerLobbyScreen(),
    const SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: AppSystemUi.overlayStyle,
      child: Scaffold(
        backgroundColor: AppColors.background,
        body: IndexedStack(index: _currentIndex, children: _screens),
        bottomNavigationBar: BottomNavigationBar(
          currentIndex: _currentIndex,
          onTap: (index) {
            setState(() {
              _currentIndex = index;
            });
          },
          items: const [
            BottomNavigationBarItem(icon: Icon(Icons.gamepad), label: '游戏库'),
            BottomNavigationBarItem(icon: Icon(Icons.wifi), label: '联机'),
            BottomNavigationBarItem(icon: Icon(Icons.settings), label: '设置'),
          ],
        ),
      ),
    );
  }
}
