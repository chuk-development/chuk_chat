// lib/widgets/agents_todo_card.dart
//
// The agent's todo list (docs/WIRE_CONTRACT.md, "Todo list"): a sticky card
// above the composer from the last `todo` frame. Collapsed it is one line, the
// item in progress and "2 of 5 done"; open it lists every item. The one item
// in progress is highlighted, a done item is struck through.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';

class AgentsTodoCard extends StatefulWidget {
  const AgentsTodoCard({
    super.key,
    required this.todos,
    this.initiallyExpanded = false,
  });

  final List<AgentsTodo> todos;
  final bool initiallyExpanded;

  @override
  State<AgentsTodoCard> createState() => _AgentsTodoCardState();
}

class _AgentsTodoCardState extends State<AgentsTodoCard> {
  late bool _open = widget.initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final List<AgentsTodo> todos = widget.todos;
    final int done = todos.where((AgentsTodo t) => t.isCompleted).length;
    AgentsTodo? current;
    for (final AgentsTodo t in todos) {
      if (t.isInProgress) {
        current = t;
        break;
      }
    }
    final String headline = current?.content ?? l.agentsTodoTitle;
    return Semantics(
      container: true,
      identifier: 'agents-todo-card',
      child: Material(
        key: const ValueKey<String>('agents-todo-card'),
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(kRadiusLg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          key: const ValueKey<String>('agents-todo-toggle'),
          onTap: () => setState(() => _open = !_open),
          child: AnimatedSize(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            alignment: Alignment.topCenter,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 10, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      HugeIcon(
                        HugeIcons.checkList,
                        size: 18,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          _open ? l.agentsTodoTitle : headline,
                          key: const ValueKey<String>('agents-todo-headline'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        l.agentsTodoProgress('$done', '${todos.length}'),
                        key: const ValueKey<String>('agents-todo-progress'),
                        style: theme.textTheme.labelMedium?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(width: 4),
                      AnimatedRotation(
                        turns: _open ? 0.5 : 0,
                        duration: const Duration(milliseconds: 220),
                        child: HugeIcon(
                          HugeIcons.arrowDown01,
                          size: 18,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                  if (_open) ...<Widget>[
                    const SizedBox(height: 6),
                    for (int i = 0; i < todos.length; i++)
                      _TodoRow(key: ValueKey<String>('agents-todo-$i'), todo: todos[i]),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _TodoRow extends StatelessWidget {
  const _TodoRow({super.key, required this.todo});

  final AgentsTodo todo;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool now = todo.isInProgress;
    final HugeIconData icon = todo.isCompleted
        ? HugeIcons.checkmarkCircle02
        : now
        ? HugeIcons.playCircle
        : HugeIcons.circle;
    final Color colour = todo.isCompleted
        ? scheme.onSurfaceVariant
        : now
        ? scheme.primary
        : scheme.onSurfaceVariant;
    return Container(
      margin: const EdgeInsets.only(top: 2),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      decoration: now
          ? BoxDecoration(
              color: scheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(kRadiusSm),
            )
          : null,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          // One text line high, so the glyph sits on the first line's centre.
          SizedBox(
            height: 20,
            child: Center(child: HugeIcon(icon, size: 16, color: colour)),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              todo.content,
              style: theme.textTheme.bodyMedium?.copyWith(
                height: 1.43,
                color: todo.isCompleted
                    ? scheme.onSurfaceVariant
                    : scheme.onSurface,
                fontWeight: now ? FontWeight.w700 : FontWeight.w400,
                decoration: todo.isCompleted
                    ? TextDecoration.lineThrough
                    : TextDecoration.none,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
