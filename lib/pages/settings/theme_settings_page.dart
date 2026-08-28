import 'package:flutter/material.dart';

import 'package:cowork/services/settings/theme_controller.dart';
import 'package:cowork/widgets/expressive_settings.dart';

/// Picks the app theme: follow the system, or force light or dark. The choice
/// is live — the whole app repaints the moment a row is tapped — and stored,
/// so it holds across restarts.
class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key, required this.controller});

  final ThemeController controller;

  static IconData _iconFor(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return Icons.brightness_auto_outlined;
      case ThemeMode.light:
        return Icons.light_mode_outlined;
      case ThemeMode.dark:
        return Icons.dark_mode_outlined;
    }
  }

  static String _subtitleFor(ThemeMode mode) {
    switch (mode) {
      case ThemeMode.system:
        return 'Match the device setting';
      case ThemeMode.light:
        return 'Always light';
      case ThemeMode.dark:
        return 'Always dark';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Theme')),
      body: ValueListenableBuilder<ThemeMode>(
        valueListenable: controller,
        builder: (context, current, _) {
          return ListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
            children: [
              const ExpressiveTitle('Theme', subtitle: 'How CoWork looks'),
              const ExpressiveSectionHeader('Appearance'),
              ExpressiveGroup(
                children: [
                  for (final mode in ThemeMode.values)
                    ExpressiveRow(
                      icon: _iconFor(mode),
                      title: ThemeController.label(mode),
                      subtitle: _subtitleFor(mode),
                      trailing: current == mode
                          ? Icon(Icons.check,
                              color: Theme.of(context).colorScheme.primary)
                          : null,
                      onTap: () => controller.setMode(mode),
                    ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }
}
