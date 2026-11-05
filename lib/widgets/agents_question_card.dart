// lib/widgets/agents_question_card.dart
//
// The agent asks the user (docs/WIRE_CONTRACT.md, "Questions to the user:
// timed ask_user"). The card takes the composer's seat while it is open: one
// question per page, a pager for several, the options as tappable rows with
// the "(Recommended)" one preselected and tagged, several picks for a
// `multi_select` question, a field for an own answer, and Skip per question.
//
// While the card is on screen the host's wait does not count down: the card
// sends `ask_visible` true when it appears and false when it goes. A question
// that timed out (`pending`) stays answerable; its answer starts a new turn.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_thread_modes.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';

class AgentsQuestionCard extends StatefulWidget {
  const AgentsQuestionCard({
    super.key,
    required this.request,
    required this.onSubmit,
    this.onVisible,
    this.dense = false,
    this.keyboardShortcuts = false,
  });

  final AgentsQuestionRequest request;

  /// Sends the answers. Completes false when they could not be sent: the
  /// card stays and says so.
  final Future<bool> Function(List<AgentsQuestionAnswer> answers) onSubmit;

  /// `ask_visible`: true when the card shows, false when it goes.
  final ValueChanged<bool>? onVisible;
  final bool dense;

  /// Enter confirms the page (Next, or Send on the last one). The card takes
  /// the focus when it appears, so Enter works at once (idea 66).
  final bool keyboardShortcuts;

  @override
  State<AgentsQuestionCard> createState() => _AgentsQuestionCardState();
}

class _AgentsQuestionCardState extends State<AgentsQuestionCard> {
  int _page = 0;
  final Map<String, Set<String>> _picked = <String, Set<String>>{};
  final Map<String, TextEditingController> _custom =
      <String, TextEditingController>{};
  final Set<String> _skipped = <String>{};
  bool _sending = false;
  bool _failed = false;

  List<AgentsQuestion> get _questions => widget.request.questions;

  @override
  void initState() {
    super.initState();
    _seed();
    widget.onVisible?.call(true);
  }

  @override
  void didUpdateWidget(AgentsQuestionCard old) {
    super.didUpdateWidget(old);
    if (old.request.questionId != widget.request.questionId) {
      old.onVisible?.call(false);
      _page = 0;
      _picked.clear();
      _skipped.clear();
      for (final TextEditingController c in _custom.values) {
        c.dispose();
      }
      _custom.clear();
      _sending = false;
      _failed = false;
      _seed();
      widget.onVisible?.call(true);
    }
  }

  void _seed() {
    for (final AgentsQuestion q in _questions) {
      _picked[q.id] = q.preselected.toSet();
      _custom[q.id] = TextEditingController();
    }
  }

  @override
  void dispose() {
    widget.onVisible?.call(false);
    for (final TextEditingController c in _custom.values) {
      c.dispose();
    }
    super.dispose();
  }

  void _toggle(AgentsQuestion q, String label) {
    setState(() {
      _skipped.remove(q.id);
      final Set<String> set = _picked[q.id]!;
      if (q.multiSelect) {
        if (!set.remove(label)) set.add(label);
      } else {
        final bool was = set.contains(label);
        set.clear();
        if (!was) set.add(label);
      }
    });
  }

  void _skip(AgentsQuestion q) {
    setState(() {
      _skipped.add(q.id);
      _picked[q.id]!.clear();
      _custom[q.id]!.clear();
    });
    _next();
  }

  void _next() {
    if (_page < _questions.length - 1) {
      setState(() => _page++);
    } else {
      unawaited(_send());
    }
  }

  List<AgentsQuestionAnswer> _answers() => <AgentsQuestionAnswer>[
    for (final AgentsQuestion q in _questions)
      _skipped.contains(q.id)
          ? AgentsQuestionAnswer(id: q.id)
          : AgentsQuestionAnswer(
              id: q.id,
              selected: <String>[
                for (final AgentsQuestionOption o in q.options)
                  if (_picked[q.id]!.contains(o.label)) o.label,
              ],
              custom: _custom[q.id]!.text.trim().isEmpty
                  ? null
                  : _custom[q.id]!.text.trim(),
            ),
  ];

  Future<void> _send() async {
    if (_sending) return;
    setState(() {
      _sending = true;
      _failed = false;
    });
    final bool ok = await widget.onSubmit(_answers());
    if (!mounted) return;
    setState(() {
      _sending = false;
      _failed = !ok;
    });
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final AgentsQuestion q = _questions[_page.clamp(0, _questions.length - 1)];
    final bool last = _page >= _questions.length - 1;
    final Widget card = _buildCard(context, theme, scheme, l, q, last);
    if (!widget.keyboardShortcuts) return card;
    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.enter): () {
          if (!_sending) _next();
        },
        const SingleActivator(LogicalKeyboardKey.numpadEnter): () {
          if (!_sending) _next();
        },
      },
      child: Focus(autofocus: true, child: card),
    );
  }

  Widget _buildCard(
    BuildContext context,
    ThemeData theme,
    ColorScheme scheme,
    AppLocalizations l,
    AgentsQuestion q,
    bool last,
  ) {
    return Semantics(
      container: true,
      liveRegion: true,
      identifier: 'agents-question-card',
      child: Container(
        key: const ValueKey<String>('agents-question-card'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(kRadiusXxl),
        ),
        padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
        child: AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Row(
                children: <Widget>[
                  HugeIcon(
                    HugeIcons.helpCircle,
                    size: 18,
                    color: scheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      q.header ?? l.agentsQuestionTitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: theme.textTheme.labelLarge?.copyWith(
                        color: scheme.onSurfaceVariant,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  if (_questions.length > 1)
                    Text(
                      l.agentsQuestionPager(
                        '${_page + 1}',
                        '${_questions.length}',
                      ),
                      key: const ValueKey<String>('agents-question-pager'),
                      style: theme.textTheme.labelMedium?.copyWith(
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                ],
              ),
              if (widget.request.isPending)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text(
                    l.agentsQuestionPending,
                    key: const ValueKey<String>('agents-question-pending'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              const SizedBox(height: 8),
              Text(
                q.question,
                key: const ValueKey<String>('agents-question-text'),
                style: theme.textTheme.titleSmall?.copyWith(
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              for (final AgentsQuestionOption o in q.options)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _OptionRow(
                    key: ValueKey<String>('agents-question-option-${o.label}'),
                    option: o,
                    multi: q.multiSelect,
                    selected: _picked[q.id]!.contains(o.label),
                    recommendedLabel: l.agentsQuestionRecommended,
                    onTap: _sending ? null : () => _toggle(q, o.label),
                  ),
                ),
              const SizedBox(height: 4),
              Container(
                decoration: BoxDecoration(
                  color: scheme.surfaceContainerHighest,
                  borderRadius: BorderRadius.circular(kRadiusMd),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: TextField(
                  key: ValueKey<String>('agents-question-custom-${q.id}'),
                  controller: _custom[q.id],
                  enabled: !_sending,
                  minLines: 1,
                  maxLines: 4,
                  onChanged: (_) => setState(() => _skipped.remove(q.id)),
                  decoration: InputDecoration(
                    border: InputBorder.none,
                    hintText: l.agentsQuestionCustomHint,
                  ),
                ),
              ),
              if (_failed)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l.agentsQuestionSendFailed,
                    key: const ValueKey<String>('agents-question-failed'),
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: scheme.error,
                    ),
                  ),
                ),
              const SizedBox(height: 12),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  if (_page > 0)
                    ExpressiveButton(
                      key: const ValueKey<String>('agents-question-back'),
                      label: l.agentsQuestionBack,
                      tonal: true,
                      dense: widget.dense,
                      onTap: () => setState(() => _page--),
                    ),
                  ExpressiveButton(
                    key: const ValueKey<String>('agents-question-skip'),
                    label: l.agentsQuestionSkip,
                    tonal: true,
                    dense: widget.dense,
                    onTap: _sending ? () {} : () => _skip(q),
                  ),
                  Opacity(
                    opacity: _sending ? 0.6 : 1,
                    child: ExpressiveButton(
                      key: const ValueKey<String>('agents-question-next'),
                      label: last ? l.agentsQuestionSend : l.agentsQuestionNext,
                      dense: widget.dense,
                      onTap: _sending ? () {} : _next,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _OptionRow extends StatelessWidget {
  const _OptionRow({
    super.key,
    required this.option,
    required this.multi,
    required this.selected,
    required this.recommendedLabel,
    required this.onTap,
  });

  final AgentsQuestionOption option;
  final bool multi;
  final bool selected;
  final String recommendedLabel;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final HugeIconData icon = multi
        ? (selected ? HugeIcons.checkmarkBadge01 : HugeIcons.square)
        : (selected ? HugeIcons.checkmarkCircle02 : HugeIcons.circle);
    return Semantics(
      selected: selected,
      button: true,
      child: Material(
        color: selected
            ? scheme.secondaryContainer
            : scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(kRadiusMd),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                SizedBox(
                  height: 20,
                  child: Center(
                    child: HugeIcon(
                      icon,
                      size: 18,
                      color: selected
                          ? scheme.onSecondaryContainer
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Wrap(
                        spacing: 6,
                        runSpacing: 2,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: <Widget>[
                          Text(
                            option.displayLabel,
                            style: theme.textTheme.bodyMedium?.copyWith(
                              height: 1.43,
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? scheme.onSecondaryContainer
                                  : scheme.onSurface,
                            ),
                          ),
                          if (option.recommended)
                            Container(
                              key: const ValueKey<String>(
                                'agents-question-recommended',
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 1,
                              ),
                              decoration: BoxDecoration(
                                color: scheme.primary.withValues(alpha: 0.14),
                                borderRadius: BorderRadius.circular(kRadiusXs),
                              ),
                              child: Text(
                                recommendedLabel,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.primary,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                        ],
                      ),
                      if (option.description != null)
                        Text(
                          option.description!,
                          style: theme.textTheme.bodySmall?.copyWith(
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// An answered question, as the user's own bubble: what they picked.
class AgentsQuestionAnsweredBubble extends StatelessWidget {
  const AgentsQuestionAnsweredBubble({super.key, required this.request});

  final AgentsQuestionRequest request;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final AppLocalizations l =
        AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));
    final List<Widget> lines = <Widget>[];
    for (final AgentsQuestion q in request.questions) {
      AgentsQuestionAnswer? a;
      for (final AgentsQuestionAnswer x in request.answers) {
        if (x.id == q.id) a = x;
      }
      final List<String> parts = <String>[
        if (a != null)
          for (final String s in a.selected)
            AgentsQuestionOption(label: s).displayLabel,
        if (a?.custom != null) a!.custom!.trim(),
      ];
      lines.add(
        Text(
          parts.isEmpty ? l.agentsQuestionSkipped : parts.join(', '),
          style: theme.textTheme.bodyMedium?.copyWith(
            color: scheme.onPrimary,
            fontStyle: parts.isEmpty ? FontStyle.italic : FontStyle.normal,
          ),
        ),
      );
    }
    return Align(
      alignment: Alignment.centerRight,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 480),
        child: Container(
          key: const ValueKey<String>('agents-question-answered'),
          decoration: BoxDecoration(
            color: scheme.primary,
            borderRadius: BorderRadius.circular(kRadiusLg),
          ),
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            mainAxisSize: MainAxisSize.min,
            children: lines,
          ),
        ),
      ),
    );
  }
}
