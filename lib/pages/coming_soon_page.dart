// lib/pages/coming_soon_page.dart
//
// The placeholder behind `pricing`, `usage` and `workspace_management`. It is
// three of the app's screens, so it does not get to be a bare icon on a bare
// background: it uses the same tonal mark the coworker inbox uses for its own
// empty state (`mobile_agent_list.dart`, `_EmptyState`).
import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/expressive_screen.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/ui/expressive/staggered.dart';

class ComingSoonPage extends StatelessWidget {
  final String title;
  final String? message;

  const ComingSoonPage({super.key, required this.title, this.message});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;

    return ExpressiveScreen(
      title: title,
      builder: (BuildContext context) => Center(
        child: Padding(
          // A message never runs to the edge of a phone.
          padding: EdgeInsets.fromLTRB(
            32,
            MediaQuery.paddingOf(context).top,
            32,
            MediaQuery.paddingOf(context).bottom,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              StaggeredItem(
                index: 0,
                child: Container(
                  width: 104,
                  height: 104,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    shape: BoxShape.circle,
                  ),
                  child: AppIcon(
                    Icons.rocket_launch_rounded,
                    size: 48,
                    color: scheme.onPrimaryContainer,
                  ),
                ),
              ),
              const SizedBox(height: 20),
              StaggeredItem(
                index: 1,
                child: Text(
                  'Coming soon!',
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
              ),
              if (message != null) ...<Widget>[
                const SizedBox(height: 8),
                StaggeredItem(
                  index: 2,
                  child: Text(
                    message!,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
