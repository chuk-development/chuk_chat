// Home note: the agent's Markdown, drawn by the same renderer as an answer.

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/markdown_message.dart';

class NoteTile extends StatelessWidget {
  const NoteTile({super.key, required this.note, required this.now});

  final NoteWidget note;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color fill = dashboardCardFill(theme);
    return DashboardCard(
      widget: note,
      now: now,
      leading: DashboardBadge(
        icon: dashboardTypeIcon(DashboardWidgetType.note),
      ),
      child: note.text.trim().isEmpty
          ? const SizedBox.shrink()
          : MarkdownMessage(
              text: note.text,
              textColor: theme.colorScheme.onSurface,
              backgroundColor: fill,
              wrapWithSelectionArea: false,
              paragraphFontSize: 14,
              paragraphHeight: 1.45,
            ),
    );
  }
}
