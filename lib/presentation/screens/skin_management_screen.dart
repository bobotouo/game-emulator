import 'package:flutter/material.dart';

import '../../core/settings/app_settings_service.dart';
import '../gamepad/gamepad_skin.dart';
import '../theme/app_theme.dart';
import '../widgets/immersive_scroll_page.dart';

class SkinManagementScreen extends StatefulWidget {
  const SkinManagementScreen({super.key});

  @override
  State<SkinManagementScreen> createState() => _SkinManagementScreenState();
}

class _SkinManagementScreenState extends State<SkinManagementScreen> {
  final AppSettingsService _settings = AppSettingsService.instance;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  String get _activeSkinId => _settings.gamepadSkinId;

  @override
  Widget build(BuildContext context) {
    return ImmersiveScrollPage(
      title: '皮肤管理',
      slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
          sliver: SliverList(
            delegate: SliverChildListDelegate([
              _sectionTitle('内置皮肤'),
              Card(
                child: Column(
                  children: [
                    for (var i = 0; i < GamepadSkins.all.length; i++) ...[
                      if (i > 0) const Divider(height: 1),
                      _builtinTile(GamepadSkins.all[i]),
                    ],
                  ],
                ),
              ),
            ]),
          ),
        ),
      ],
    );
  }

  Widget _sectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: Theme.of(context).textTheme.bodySmall?.copyWith(
          color: AppColors.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _builtinTile(GamepadSkin skin) {
    final selected = _activeSkinId == skin.id;

    return ListTile(
      leading: _skinColorPreview(skin.colorA, skin.colorB),
      title: Text(skin.name),
      subtitle: const Text('内置矢量按键'),
      trailing: selected
          ? const Icon(Icons.check_circle, color: AppColors.secondary)
          : null,
      onTap: () => _settings.setGamepadSkinId(skin.id),
    );
  }

  Widget _skinColorPreview(Color a, Color b) {
    return Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(colors: [a, b]),
        border: Border.all(color: AppColors.outlineVariant),
      ),
    );
  }
}
