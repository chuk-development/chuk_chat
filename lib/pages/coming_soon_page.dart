// lib/pages/coming_soon_page.dart
import 'package:flutter/material.dart';

class ComingSoonPage extends StatelessWidget {
  final String title;
  final String? message;

  const ComingSoonPage({super.key, required this.title, this.message});

  @override
  Widget build(BuildContext context) {
    final Color scaffoldBg = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFg = Theme.of(context).iconTheme.color ?? Colors.white;
    final TextStyle titleStyle =
        Theme.of(context).textTheme.titleLarge?.copyWith(color: iconFg) ??
        TextStyle(color: iconFg, fontSize: 20, fontWeight: FontWeight.w600);

    final TextStyle subtitleStyle =
        Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: iconFg.withValues(alpha: 0.75),
        ) ??
        TextStyle(color: iconFg.withValues(alpha: 0.75), fontSize: 16);

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        title: Text(title, style: titleStyle),
        backgroundColor: scaffoldBg,
        elevation: 0,
        iconTheme: IconThemeData(color: iconFg),
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.rocket_launch, color: iconFg, size: 48),
            const SizedBox(height: 16),
            Text('Coming soon!', style: titleStyle),
            if (message != null) ...[
              const SizedBox(height: 8),
              Text(message!, style: subtitleStyle, textAlign: TextAlign.center),
            ],
          ],
        ),
      ),
    );
  }
}
