import 'package:flutter/material.dart';

import '../theme/app_theme.dart';
import '../widgets/immersive_scroll_page.dart';
import '../../core/network/lan_service.dart';
import '../../core/settings/app_settings_service.dart';
import '../gamepad/gamepad_layout.dart';
import '../screens/skin_management_screen.dart';
import '../gamepad/gamepad_skin.dart';
import '../../core/storage/storage_paths_service.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final AppSettingsService _settings = AppSettingsService.instance;
  final LANService _lanService = LANService();

  String _localIp = '获取中...';
  String _saveLocation = '获取中...';

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    _loadDeviceInfo();
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _lanService.dispose();
    super.dispose();
  }

  void _onSettingsChanged() {
    if (mounted) {
      setState(() {});
    }
  }

  Future<void> _loadDeviceInfo() async {
    final localIp = await _lanService.getLocalIp();
    var saveLocation = '获取中...';
    try {
      saveLocation = await StoragePathsService.getSaveStatesPath();
    } catch (e) {
      saveLocation = '无法访问存储：$e';
    }

    if (mounted) {
      setState(() {
        _localIp = localIp ?? '未获取到';
        _saveLocation = saveLocation;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = kBottomNavigationBarHeight +
        MediaQuery.paddingOf(context).bottom +
        16;

    return ImmersiveScrollPage(
      title: '设置',
      slivers: [
        SliverPadding(
          padding: EdgeInsets.fromLTRB(16, 8, 16, bottomInset),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
          _buildSectionHeader(context, '模拟器设置'),
          _buildSettingsCard(
            children: [
              _buildSwitchTile(
                icon: Icons.vibration,
                title: '触觉反馈',
                subtitle: '支持震动的游戏触发震动时，允许手机震动',
                value: _settings.hapticFeedbackEnabled,
                onChanged: _settings.setHapticFeedbackEnabled,
              ),
              _buildDivider(),
              _buildSwitchTile(
                icon: Icons.touch_app,
                title: '按键反馈',
                subtitle: '点击虚拟按键时轻微震动',
                value: _settings.buttonFeedbackEnabled,
                onChanged: _settings.setButtonFeedbackEnabled,
              ),
              _buildDivider(),
              _buildAspectRatioTile(),
              _buildDivider(),
              _buildBrightnessTile(),
              _buildDivider(),
              _buildGamepadSkinManagementTile(),
              _buildDivider(),
              _buildGamepadLayoutTile(),
              _buildDivider(),
              _buildStaticTile(
                icon: Icons.bluetooth,
                title: '蓝牙手柄',
                subtitle: '暂未接入',
                trailing: const Switch(value: false, onChanged: null),
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(context, '网络设置'),
          _buildSettingsCard(
            children: [
              _buildSwitchTile(
                icon: Icons.wifi,
                title: '联机设置',
                subtitle: _settings.networkEnabled ? '已开启局域网联机' : '已关闭',
                value: _settings.networkEnabled,
                onChanged: _settings.setNetworkEnabled,
              ),
              _buildDivider(),
              _buildStaticTile(
                icon: Icons.language,
                title: '本机 IP',
                subtitle: _localIp,
              ),
              _buildDivider(),
              _buildStaticTile(
                icon: Icons.settings_ethernet,
                title: '端口',
                subtitle: '${_settings.networkPort}',
                trailing: IconButton(
                  icon: const Icon(Icons.edit, size: 18),
                  tooltip: '修改端口',
                  color: AppColors.onSurfaceVariant,
                  onPressed: _editPort,
                ),
                onTap: _editPort,
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(context, '存档管理'),
          _buildSettingsCard(
            children: [
              _buildStaticTile(
                icon: Icons.folder,
                title: '存档位置',
                subtitle: _saveLocation,
              ),
              _buildDivider(),
              _buildStaticTile(
                icon: Icons.info_outline,
                title: '存档说明',
                subtitle: '退出游戏时自动保存进度，再次进入自动读取。文件名与游戏 ROM 同名，如 口袋妖怪.state',
              ),
            ],
          ),
          const SizedBox(height: 24),
          _buildSectionHeader(context, '关于'),
          _buildSettingsCard(
            children: [
              _buildStaticTile(
                icon: Icons.info_outline,
                title: '版本',
                subtitle: '1.0.0',
              ),
              _buildDivider(),
              _buildStaticTile(
                icon: Icons.description_outlined,
                title: '介绍说明',
                subtitle: '本应用用于管理和运行本地游戏（GBA / NES 等），支持游戏库、存档、局域网联机和虚拟手柄。',
              ),
            ],
          ),
          const SizedBox(height: 32),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _buildSectionHeader(BuildContext context, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppColors.primary,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.1,
        ),
      ),
    );
  }

  Widget _buildSettingsCard({required List<Widget> children}) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Column(children: children),
      ),
    );
  }

  Widget _buildSwitchTile({
    required IconData icon,
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return SwitchListTile(
      value: value,
      onChanged: onChanged,
      secondary: Icon(icon, color: AppColors.onSurfaceVariant, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
      ),
      activeThumbColor: AppColors.secondary,
      contentPadding: const EdgeInsets.only(left: 16, right: 12),
    );
  }

  Widget _buildStaticTile({
    required IconData icon,
    required String title,
    required String subtitle,
    Widget? trailing,
    VoidCallback? onTap,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.onSurfaceVariant, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
      ),
      trailing: trailing,
      onTap: onTap,
    );
  }

  Widget _buildDropdownSettingTile({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required List<DropdownMenuItem<String>> items,
    required ValueChanged<String?> onChanged,
  }) {
    return ListTile(
      leading: Icon(icon, color: AppColors.onSurfaceVariant, size: 22),
      title: Text(title, style: const TextStyle(fontSize: 14)),
      subtitle: Text(
        subtitle,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
      ),
      trailing: DropdownButtonHideUnderline(
        child: ButtonTheme(
          alignedDropdown: true,
          padding: EdgeInsets.zero,
          child: DropdownButton<String>(
            value: value,
            isDense: true,
            dropdownColor: AppColors.surfaceContainerHigh,
            style: const TextStyle(fontSize: 14, color: AppColors.onSurface),
            icon: const Icon(Icons.arrow_drop_down, size: 22),
            items: items,
            onChanged: onChanged,
          ),
        ),
      ),
    );
  }

  Widget _buildAspectRatioTile() {
    return _buildDropdownSettingTile(
      icon: Icons.aspect_ratio,
      title: '画面比例',
      value: _settings.displayAspectRatio,
      subtitle: _aspectRatioLabel(_settings.displayAspectRatio),
      items: const [
        DropdownMenuItem(
          value: AppSettingsService.aspectOriginal,
          child: Text('原始 3:2'),
        ),
        DropdownMenuItem(
          value: AppSettingsService.aspectFourThree,
          child: Text('4:3'),
        ),
        DropdownMenuItem(
          value: AppSettingsService.aspectStretch,
          child: Text('填满窗口'),
        ),
      ],
      onChanged: (value) {
        if (value != null) {
          _settings.setDisplayAspectRatio(value);
        }
      },
    );
  }

  String _activeSkinLabel() {
    return GamepadSkins.byId(_settings.gamepadSkinId).name;
  }

  Widget _buildGamepadSkinManagementTile() {
    return ListTile(
      leading: const Icon(
        Icons.palette_outlined,
        color: AppColors.onSurfaceVariant,
        size: 22,
      ),
      title: const Text('皮肤管理', style: TextStyle(fontSize: 14)),
      subtitle: Text(
        '当前：${_activeSkinLabel()}',
        style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
      ),
      trailing: const Icon(Icons.chevron_right),
      onTap: () {
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const SkinManagementScreen(),
          ),
        );
      },
    );
  }

  Widget _buildGamepadLayoutTile() {
    final layoutId = _settings.gamepadLayoutId;
    final value = layoutId.isEmpty
        ? AppSettingsService.gamepadLayoutAuto
        : layoutId;

    const autoValue = AppSettingsService.gamepadLayoutAuto;
    final menuItems = <DropdownMenuItem<String>>[
      const DropdownMenuItem(value: autoValue, child: Text('自动')),
      for (final layout in GamepadLayouts.all)
        DropdownMenuItem(
          value: layout.id,
          child: Text(_gamepadLayoutShortLabel(layout.id)),
        ),
    ];

    return _buildDropdownSettingTile(
      icon: Icons.gamepad_outlined,
      title: '按键布局',
      value: value,
      subtitle: _gamepadLayoutSubtitle(layoutId),
      items: menuItems,
      onChanged: (picked) {
        if (picked == null) return;
        _settings.setGamepadLayoutId(picked == autoValue ? '' : picked);
      },
    );
  }

  String _gamepadLayoutSubtitle(String layoutId) {
    if (layoutId.isEmpty) {
      return '按游戏类型自动匹配';
    }
    return _gamepadLayoutMenuHint(layoutId);
  }

  /// Short label for closed dropdown + menu row (keeps width tight).
  String _gamepadLayoutShortLabel(String layoutId) {
    if (layoutId.isEmpty) {
      return '自动';
    }
    switch (layoutId) {
      case 'gb':
        return 'GB / GBC';
      case 'gba':
        return 'GBA';
      case 'gba_full':
        return 'GBA 肩键';
      case 'nes':
        return 'NES';
      case 'snes':
        return 'SNES';
      case 'minimal':
        return '精简';
      default:
        return GamepadLayouts.byId(layoutId).name;
    }
  }

  String _gamepadLayoutMenuHint(String layoutId) {
    final layout = GamepadLayouts.byId(layoutId);
    switch (layoutId) {
      case 'gb':
        return 'GB / GBC · 十字键 + A/B';
      case 'gba':
      case 'gba_full':
        return 'GBA · 含 L/R 肩键';
      case 'nes':
        return 'NES · 十字键 + A/B';
      case 'snes':
        return 'SNES · 含 X/Y 与肩键';
      case 'minimal':
        return '精简 · 无 Select/Start';
      default:
        return layout.name;
    }
  }

  Widget _buildBrightnessTile() {
    final percent = (_settings.displayBrightness * 100).round();

    return Padding(
      padding: const EdgeInsets.only(top: 4, bottom: 8),
      child: Column(
        children: [
          ListTile(
            leading: const Icon(
              Icons.brightness_6,
              color: AppColors.onSurfaceVariant,
              size: 22,
            ),
            title: const Text('亮度', style: TextStyle(fontSize: 14)),
            subtitle: Text(
              '$percent%（默认 100%）',
              style: TextStyle(fontSize: 12, color: AppColors.onSurfaceVariant),
            ),
          ),
          Slider(
            value: _settings.displayBrightness,
            min: 0.5,
            max: 1.5,
            divisions: 20,
            label: '$percent%',
            onChanged: _settings.setDisplayBrightness,
          ),
        ],
      ),
    );
  }

  String _aspectRatioLabel(String value) {
    switch (value) {
      case AppSettingsService.aspectFourThree:
        return '4:3';
      case AppSettingsService.aspectStretch:
        return '填满窗口';
      case AppSettingsService.aspectOriginal:
      default:
        return '原始 3:2';
    }
  }

  Future<void> _editPort() async {
    final controller = TextEditingController(text: '${_settings.networkPort}');
    final result = await showDialog<int>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('端口'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: TextInputType.number,
          decoration: const InputDecoration(hintText: '1024 - 65535'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context, int.tryParse(controller.text));
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );

    controller.dispose();
    if (result == null) return;

    if (result < 1024 || result > 65535) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('端口范围需要在 1024 - 65535')));
      }
      return;
    }

    await _settings.setNetworkPort(result);
  }

  Widget _buildDivider() {
    return const Divider(
      height: 1,
      indent: 56,
      color: AppColors.outlineVariant,
    );
  }
}
