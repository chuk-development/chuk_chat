// lib/widgets/agents_context_chip.dart
//
// A row nobody typed (docs/WIRE_CONTRACT.md, "Typed source on synthetic
// rows"): a goal round, a fired schedule, a job wake, a mail, the plan-mode
// rules, a loaded skill, a settled subagent, the background review. It reads
// as a small notice in the transcript, never as a user bubble: the user did
// not say it. A tap shows the whole text.

import 'package:flutter/material.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';

/// The words of one source, localised.
String agentsSourceLabel(AppLocalizations l, String source) => switch (source) {
  'goal' => l.agentsSourceGoal,
  'schedule' => l.agentsSourceSchedule,
  'job' => l.agentsSourceJob,
  'skill' => l.agentsSourceSkill,
  'mail' => l.agentsSourceMail,
  'subagent' => l.agentsSourceSubagent,
  'review' => l.agentsSourceReview,
  'plan' => l.agentsSourcePlan,
  'time' => l.agentsSourceTime,
  'answer' => l.agentsSourceAnswer,
  _ => l.agentsSourceOther,
};

HugeIconData agentsSourceIcon(String source) => switch (source) {
  'goal' => HugeIcons.target01,
  'schedule' => HugeIcons.clock01,
  'job' => HugeIcons.terminal,
  'skill' => HugeIcons.sparkles,
  'mail' => HugeIcons.mail01,
  'subagent' => HugeIcons.robot01,
  'review' => HugeIcons.checkList,
  'plan' => HugeIcons.clipboardList,
  'time' => HugeIcons.clock01,
  'answer' => HugeIcons.helpCircle,
  _ => HugeIcons.informationCircle,
};

class AgentsContextChip extends StatefulWidget {
  const AgentsContextChip({
    super.key,
    required this.source,
    required this.text,
  });

  final String source;
  final String text;

  @override
  State<AgentsContextChip> createState() => _AgentsContextChipState();
}

class _AgentsContextChipState extends State<AgentsContextChip> {
  bool _open = false;

  /// The first line, without the host's tag (`<goal_round>`, `[subagent
  /// settled]`), so the chip says something a person reads.
  String get _preview {
    for (final String raw in widget.text.split('\n')) {
      final String line = raw
          .replaceAll(RegExp(r'</?[a-z_]+[^>]*>'), '')
          .replaceAll(RegExp(r'^\[[a-z ]+\]\s*'), '')
          .trim();
      if (line.isNotEmpty) return line;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final String label = agentsSourceLabel(l, widget.source);
    final String preview = _preview;
    final bool expandable = widget.text.trim().isNotEmpty;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Semantics(
          identifier: 'agents-context-${widget.source}',
          button: expandable,
          child: Material(
            key: ValueKey<String>('agents-context-chip-${widget.source}'),
            color: scheme.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(_open ? kRadiusLg : kRadiusSm),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: expandable ? () => setState(() => _open = !_open) : null,
              child: AnimatedSize(
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topLeft,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(10, 5, 12, 5),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          SizedBox(
                            height: 18,
                            child: Center(
                              child: HugeIcon(
                                agentsSourceIcon(widget.source),
                                size: 14,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            label,
                            style: theme.textTheme.labelMedium?.copyWith(
                              color: scheme.onSurfaceVariant,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                          if (!_open && preview.isNotEmpty) ...<Widget>[
                            const SizedBox(width: 6),
                            Flexible(
                              child: ConstrainedBox(
                                constraints: const BoxConstraints(
                                  maxWidth: 360,
                                ),
                                child: Text(
                                  preview,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: theme.textTheme.labelMedium?.copyWith(
                                    color: scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (_open)
                        Padding(
                          padding: const EdgeInsets.only(top: 6, bottom: 2),
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 560),
                            child: SelectableText(
                              widget.text.trim(),
                              key: const ValueKey<String>(
                                'agents-context-chip-text',
                              ),
                              style: theme.textTheme.bodySmall?.copyWith(
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
