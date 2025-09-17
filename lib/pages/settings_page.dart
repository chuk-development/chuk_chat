// lib/pages/settings_page.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/constants.dart'; // Import app constants for colors
import 'package:ui_elements_flutter/model_selector_page.dart'; // Import the ModelSelectorPage

class SettingsPage extends StatelessWidget {
  const SettingsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Settings'),
        backgroundColor: bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: iconFg), // Set back button color
        titleTextStyle: TextStyle(color: iconFg, fontSize: 20), // Set title text color
      ),
      body: ListView(
        padding: const EdgeInsets.all(16.0),
        children: [
          // Setting: Model Selection
          Card(
            color: bg.lighten(0.05), // Slightly lighter background for the card
            margin: const EdgeInsets.only(bottom: 16.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: iconFg.withOpacity(0.3), width: 1),
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: Icon(Icons.psychology_alt, color: accent), // Accent color for the icon
              title: const Text(
                'Model Selection',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                'Choose and configure your AI models',
                style: TextStyle(color: iconFg.lighten(0.3), fontSize: 13),
              ),
              trailing: Icon(Icons.arrow_forward_ios, color: iconFg),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (context) => const ModelSelectorPage()),
                );
              },
            ),
          ),
          // Example of another setting option
          Card(
            color: bg.lighten(0.05),
            margin: const EdgeInsets.only(bottom: 16.0),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: iconFg.withOpacity(0.3), width: 1),
            ),
            child: ListTile(
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              leading: Icon(Icons.dark_mode, color: accent),
              title: const Text(
                'Theme Settings',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w600,
                  fontSize: 16,
                ),
              ),
              subtitle: Text(
                'Adjust app theme and appearance',
                style: TextStyle(color: iconFg.lighten(0.3), fontSize: 13),
              ),
              trailing: Icon(Icons.arrow_forward_ios, color: iconFg),
              onTap: () {
                // Navigate to Theme Settings page or show a dialog
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Theme settings tapped!'),
                    backgroundColor: accent,
                  ),
                );
              },
            ),
          ),
          // Add more settings options as needed
        ],
      ),
    );
  }
}