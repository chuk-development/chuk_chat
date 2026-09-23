// lib/pages/coming_soon_page.dart
//
// The placeholder behind `pricing`, `usage` and `workspace_management`. It is
// three of the app's screens, so it does not get to be a bare icon on a bare
// background: it uses the same tonal mark the coworker inbox uses for its own
// empty state (`mobile_agent_list.dart`, `_EmptyState`).
//
// Merge note: upstream kept the Scaffold + FloatingAppBar chrome and Agents
// rewrote the body as a tonal mark with a staggered entrance. Those compose —
// upstream's chrome carries Agents's body here, so neither side is dropped.
import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/staggered.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

class ComingSoonPage extends StatelessWidget {
  final String title;
  final String? message;

  const ComingSoonPage({super.key, required this.title, this.message});

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final Color iconFg = theme.iconTheme.color ?? Colors.white;
    final TextStyle titleStyle =
        theme.textTheme.titleLarge?.copyWith(color: iconFg) ??
        TextStyle(color: iconFg, fontSize: 20, fontWeight: FontWeight.w600);

    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      // The page runs underneath the floating header.
      extendBodyBehindAppBar: true,
      appBar: FloatingAppBar(title: Text(title, style: titleStyle)),
      body: Center(
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
