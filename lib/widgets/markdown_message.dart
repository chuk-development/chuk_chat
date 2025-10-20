// lib/widgets/markdown_message.dart

import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;
import 'package:url_launcher/url_launcher_string.dart';

class MarkdownMessage extends StatelessWidget {
  const MarkdownMessage({
    super.key,
    required this.text,
    required this.textColor,
    required this.backgroundColor,
  });

  final String text;
  final Color textColor;
  final Color backgroundColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MarkdownStyleSheet
    baseSheet = MarkdownStyleSheet.fromTheme(theme).copyWith(
      p: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        height: 1.45,
        fontSize: 14,
      ),
      h1: theme.textTheme.headlineSmall?.copyWith(
        color: textColor,
        height: 1.3,
        fontWeight: FontWeight.w700,
      ),
      h2: theme.textTheme.titleLarge?.copyWith(
        color: textColor,
        height: 1.3,
        fontWeight: FontWeight.w700,
      ),
      h3: theme.textTheme.titleMedium?.copyWith(
        color: textColor,
        height: 1.3,
        fontWeight: FontWeight.w700,
      ),
      h4: theme.textTheme.titleSmall?.copyWith(
        color: textColor,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      h5: theme.textTheme.bodyLarge?.copyWith(
        color: textColor,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      h6: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        height: 1.35,
        fontWeight: FontWeight.w600,
      ),
      code: TextStyle(
        fontFamily: 'monospace',
        fontSize: 13,
        height: 1.4,
        color: textColor,
        backgroundColor: _codeBackground(),
      ),
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: 12,
        vertical: 4,
      ),
      blockquoteDecoration: BoxDecoration(
        border: Border(
          left: BorderSide(color: textColor.withValues(alpha: 0.35), width: 3),
        ),
      ),
      tableBorder: TableBorder.all(
        color: textColor.withValues(alpha: 0.2),
        width: 1,
      ),
      tableHead: theme.textTheme.bodyMedium?.copyWith(
        color: textColor,
        fontWeight: FontWeight.w600,
      ),
      tableBody: theme.textTheme.bodyMedium?.copyWith(color: textColor),
      horizontalRuleDecoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: textColor.withValues(alpha: 0.2), width: 1),
        ),
      ),
      listBullet: TextStyle(color: textColor),
      unorderedListAlign: WrapAlignment.start,
      orderedListAlign: WrapAlignment.start,
      blockSpacing: 10,
    );

    return MarkdownBody(
      data: text,
      selectable: true,
      softLineBreak: true,
      styleSheet: baseSheet,
      extensionSet: md.ExtensionSet.gitHubWeb,
      listItemCrossAxisAlignment: MarkdownListItemCrossAxisAlignment.start,
      onTapLink: (text, href, title) {
        if (href == null || href.trim().isEmpty) return;
        launchUrlString(href, mode: LaunchMode.externalApplication);
      },
    );
  }

  Color _codeBackground() {
    final HSLColor hsl = HSLColor.fromColor(backgroundColor);
    final double luminance = backgroundColor.computeLuminance();
    if (luminance > 0.6) {
      return hsl
          .withLightness((hsl.lightness - 0.1).clamp(0.0, 1.0))
          .toColor()
          .withValues(alpha: 0.6);
    }
    return hsl
        .withLightness((hsl.lightness + 0.2).clamp(0.0, 1.0))
        .toColor()
        .withValues(alpha: 0.6);
  }
}
