// lib/pages/projects_page.dart
import 'package:flutter/material.dart';

class ProjectsPage extends StatelessWidget {
  const ProjectsPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    // Access theme colors dynamically
    final Color scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFg = Theme.of(context).iconTheme.color!;
    final TextStyle? titleTextStyle = Theme.of(context).appBarTheme.titleTextStyle;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text('Projects', style: titleTextStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg), // Ensure back button has the right color
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