// lib/widgets/compaction_divider.dart
//
// A quiet line above the first message a chat compaction kept: everything
// above it reaches the model only as a summary (lib/services/
// chat_compaction.dart). Hairline + small muted label, no shadow
// (docs/DESIGN.md).

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';

class CompactionDivider extends StatelessWidget {
  const CompactionDivider({super.key});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color line = theme.colorScheme.outlineVariant;
    final TextStyle style =
        (theme.textTheme.labelSmall ?? const TextStyle(fontSize: 11)).copyWith(
          color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
        );
    final String label =
        AppLocalizations.of(context)?.chatCompactedDivider ??
        'Earlier messages summarized';
    return Semantics(
      label: label,
      excludeSemantics: true,
      child: Padding(
        padding: const EdgeInsets.only(top: 14, bottom: 4),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Expanded(child: Container(height: 1, color: line)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10),
              child: Text(label, style: style),
            ),
            Expanded(child: Container(height: 1, color: line)),
          ],
        ),
      ),
    );
  }
}
