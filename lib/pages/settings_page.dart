// lib/pages/settings_page.dart
import 'package:flutter/material.dart';
import 'package:chuk_chat/constants.dart'; // Import app constants for default colors
import 'package:chuk_chat/model_selector_page.dart'; // Import the ModelSelectorPage
import 'package:chuk_chat/pages/theme_page.dart'; // Import the new ThemePage
import 'package:chuk_chat/utils/color_extensions.dart'; // Import ColorExtension

class SettingsPage extends StatelessWidget {
  final Brightness currentThemeMode;
  final Color currentAccentColor;
  final Color currentIconFgColor;
  final Color currentBgColor; // Now passed for ThemePage to display initial
  final Function(Brightness) setThemeMode;
  final Function(Color) setAccentColor;
  final Function(Color) setIconFgColor;
  final Function(Color) setBgColor; // Now passed for ThemePage to use

  const SettingsPage({
    Key? key,
    required this.currentThemeMode,
    required this.currentAccentColor,
    required this.currentIconFgColor,
    required this.currentBgColor, // New
    required this.setThemeMode,
    required this.setAccentColor,
    required this.setIconFgColor,
    required this.setBgColor, // New
  }) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Access theme colors dynamically
    final Color scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final Color accent = Theme.of(context).colorScheme.primary;
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final TextStyle? titleTextStyle = Theme.of(context).appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Settings', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg), // Set back button color
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Setting: Theme Settings (NEW)
          _buildSettingsCard(
            context,
            title: 'Theme Settings',
            subtitle: 'Adjust app theme, colors, and appearance',
            icon: Icons.palette,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => ThemePage(
                    currentThemeMode: currentThemeMode,
                    currentAccentColor: currentAccentColor,
                    currentIconFgColor: currentIconFgColor,
                    currentBgColor: currentBgColor, // Pass current background color
                    setThemeMode: setThemeMode,
                    setAccentColor: setAccentColor,
                    setIconFgColor: setIconFgColor,
                    setBgColor: setBgColor, // Pass background color setter
                  ),
                ),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16), // Spacing between cards

          // Setting: Model Selection (Existing)
          _buildSettingsCard(
            context,
            title: 'Model Selection',
            subtitle: 'Choose and configure your AI models',
            icon: Icons.psychology_alt,
            onTap: () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (context) => const ModelSelectorPage()),
              );
            },
            accentColor: accent,
            iconFgColor: iconFg,
            bgColor: scaffoldBg,
          ),
          const SizedBox(height: 16), // Spacing between cards

          // Example of another setting option
          _buildSettingsCard(
            context,
            title: 'Account Settings',
            subtitle: 'Manage your profile and account',
            icon: Icons.person_outline,
            onTap: () {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('Account settings tapped!'),
                  backgroundColor: accent,
                ),
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

  // Helper method to build consistent looking setting cards
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
      color: bgColor.lighten(0.05), // Slightly lighter background for the card
      margin: EdgeInsets.zero, // No external margin, controlled by Column spacing
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: iconFgColor.withOpacity(0.3), width: 1),
      ),
      child: ListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        leading: Icon(icon, color: accentColor), // Accent color for the icon
        title: Text(
          title,
          style: TextStyle(
            color: Theme.of(context).textTheme.titleMedium?.color, // Use theme's text color
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