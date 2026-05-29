import 'package:flutter/material.dart';

import '../theme/app_theme.dart';

/// Immersive list page: transparent app bar, scroll down to hide title + actions.
class ImmersiveScrollPage extends StatelessWidget {
  const ImmersiveScrollPage({
    super.key,
    required this.title,
    required this.slivers,
    this.actions,
    this.floatingActionButton,
  });

  final String title;
  final List<Widget> slivers;
  final List<Widget>? actions;
  final Widget? floatingActionButton;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      extendBodyBehindAppBar: true,
      backgroundColor: AppColors.background,
      floatingActionButton: floatingActionButton,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            snap: true,
            backgroundColor: Colors.transparent,
            surfaceTintColor: Colors.transparent,
            shadowColor: Colors.transparent,
            elevation: 0,
            scrolledUnderElevation: 0,
            forceMaterialTransparency: true,
            title: Text(title),
            actions: actions,
          ),
          ...slivers,
        ],
      ),
    );
  }
}
