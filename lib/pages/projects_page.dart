// lib/pages/projects_page.dart
import 'package:flutter/material.dart';
import 'package:ui_elements_flutter/constants.dart'; // Import app constants for theme

class ProjectsPage extends StatelessWidget {
  const ProjectsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: bg,
      appBar: AppBar(
        title: const Text('Projects'),
        backgroundColor: bg,
        elevation: 0,
        iconTheme: const IconThemeData(color: iconFg), // Ensure back button has the right color
        titleTextStyle: const TextStyle(color: iconFg, fontSize: 20),
      ),
      body: Center(
        child: Text(
          'Projects page - build your content here!',
          style: TextStyle(color: iconFg.withOpacity(0.8)),
        ),
      ),
    );
  }
}