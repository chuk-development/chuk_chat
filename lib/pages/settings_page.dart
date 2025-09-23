// lib/pages/settings_page.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/model_selector_page.dart';
import 'package:chuk_chat/pages/theme_page.dart';
import 'package:chuk_chat/pages/account_settings_page.dart';
import 'package:chuk_chat/utils/color_extensions.dart';

class SettingsPage extends StatelessWidget {
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor;

  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor;

  // NEW: film grain
  final bool grainEnabled;
  final Function(bool) setGrainEnabled;

  const SettingsPage({
    Key? key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor,
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor,
    required this.grainEnabled,          // added
    required this.setGrainEnabled,       // added
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color scaffoldBg = theme.scaffoldBackgroundColor;
    final Color accent = theme.colorScheme.primary;
    final Color iconFg = theme.iconTheme.color!;
    final TextStyle? titleTextStyle = theme.appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Settings', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Theme Settings
          _buildSettingsCard(
            context,
            title: 'Theme Settings',
            subtitle: 'Adjust app theme, colors, and appearance',
            icon: Icons.palette,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (_) => ThemePage(
                    currentThemeMode: currentThemeMode,
                    currentAccentColor: currentAccentColor,
                    currentIconFgColor: currentIconFgColor,
                    currentBgColor: currentBgColor,
                    setThemeMode: setThemeMode,
                    setAccentColor: setAccentColor,
                    setIconFgColor: setIconFgColor,
                    setBgColor: setBgColor,
                    grainEnabled: grainEnabled,             // pass
                    setGrainEnabled: setGrainEnabled,       // pass
                  ),
                ),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16),

          // Model Selection
          _buildSettingsCard(
            context,
            title: 'Model Selection',
            subtitle: 'Choose and configure your AI models',
            icon: Icons.psychology_alt,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const ModelSelectorPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16),

          // Account Settings
          _buildSettingsCard(
            context,
            title: 'Account Settings',
            subtitle: 'Manage your profile and account',
            icon: Icons.person_outline,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const AccountSettingsPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
        ],
      ),
    );
  }

  Widget _buildSettingsCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required VoidCallback onTap,
    required Color accentColor,
    required Color iconFgColor,
    required Color bgColor,
  }) {
    return Card(
      color: bgColor.lighten(0.05),
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFgColor.withValues(alpha: 0.3), width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: accentColor),
        title: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).textTheme.titleMedium?.color,
            fontWeight: FontWeight.w600,
            fontSize: 16,
          ),
        ),
        subtitle: Text(
          subtitle,
          style: TextStyle(color: iconFgColor.lighten(0.3), fontSize: 13),
        ),
        trailing: Icon(Icons.arrow_forward_ios, color: iconFgColor),
        onTap: onTap,
      ),
    );
  }
}
