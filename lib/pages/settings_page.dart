// lib/pages/settings_page.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/constants.dart'; // Import app constants for colors

class SettingsPage extends StatelessWidget {
  const SettingsPage({Key? key}) : super(key: key);
  @override
  Widget build(BuildContext context) => Scaffold(
        backgroundColor: bg,
        appBar: AppBar(title: const Text('Settings'), backgroundColor: bg, elevation: 0),
        body: Center(child: Text('Settings page – add options here', style: TextStyle(color: iconFg))),
      );
}