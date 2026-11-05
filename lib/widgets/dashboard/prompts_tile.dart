// Home prompts: tonal buttons that open the main agent's thread with the
// prompt in the composer (not sent; the user reads it first).

import 'package:flutter/material.dart';

import 'package:chuk_chat/services/agents/main_agent_launcher.dart';
import 'package:chuk_chat/services/dashboard/dashboard_model.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/dashboard/dashboard_card.dart';
import 'package:chuk_chat/widgets/icons/huge_icon.dart';

class PromptsTile extends StatelessWidget {
  const PromptsTile({super.key, required this.prompts, required this.now});

  final PromptsWidget prompts;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    return DashboardCard(
      widget: prompts,
      now: now,
      leading: DashboardBadge(
        icon: dashboardTypeIcon(DashboardWidgetType.prompts),
      ),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: <Widget>[
          for (int i = 0; i < prompts.items.length; i++)
            DashboardPromptButton(
              key: ValueKey<String>('prompt-${prompts.id}-$i'),
              label: prompts.items[i].label,
              onTap: () => MainAgentLauncher.instance.openWithPrompt(
                prompts.items[i].prompt,
              ),
            ),
        ],
      ),
    );
  }
}

/// A tonal capsule with a leading spark: "ask an agent this". Also the
/// suggestion chips of the empty Home.
class DashboardPromptButton extends StatelessWidget {
  const DashboardPromptButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon = HugeIcons.sparkles,
    this.color,
  });

  final String label;
  final VoidCallback onTap;
  final HugeIconData icon;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final MaterialYouTokens m3 = theme.m3;
    final Color fill = color ?? m3.surfaceContainerHighest;
    final Color fg = theme.colorScheme.onSurface;
    return Semantics(
      button: true,
      child: MorphTap(
        onTap: onTap,
        color: fill,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        padding: const EdgeInsets.fromLTRB(12, 10, 14, 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            HugeIcon(icon, size: 16, color: fg),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: theme.textTheme.labelLarge?.copyWith(
                  color: fg,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
