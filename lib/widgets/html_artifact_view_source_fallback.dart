// lib/widgets/html_artifact_view_source_fallback.dart
// Plain-text source view for HTML artifacts on platforms without a
// working WebView (currently: Linux desktop).

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

class HtmlSourceFallback extends StatelessWidget {
  const HtmlSourceFallback({super.key, required this.html});

  final String html;

  @override
  Widget build(BuildContext context) {
    final iconFg = Theme.of(context).resolvedIconColor;
    return SingleChildScrollView(
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          border: Border.all(color: iconFg.withValues(alpha: 0.15)),
          borderRadius: BorderRadius.circular(8),
        ),
        child: SelectableText(
          html,
          style: TextStyle(
            color: iconFg,
            fontFamily: 'monospace',
            fontSize: 12,
            height: 1.35,
          ),
        ),
      ),
    );
  }
}
