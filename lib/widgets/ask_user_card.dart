// lib/widgets/ask_user_card.dart

import 'package:flutter/material.dart';

import 'package:chuk_chat/widgets/icons/huge_icon.dart';

/// Interactive options shown below messages that used the ask_user tool.
///
/// Single choice (the default): tappable chips, a tap sends the option.
/// Multiple choice ([multiSelect]): a card with the question, a "choose all
/// that apply" line, one row per option with a filled letter badge (A, B,
/// C …) and a confirm button; the picked options go out as one message.
class AskUserCard extends StatelessWidget {
  const AskUserCard({
    super.key,
    required this.options,
    required this.onSelect,
    this.question = '',
    this.multiSelect = false,
  });

  /// The option labels extracted from the ask_user tool call arguments.
  final List<String> options;

  /// Called with the answer: the option label, or for [multiSelect] the
  /// picked labels joined with ", ".
  final ValueChanged<String> onSelect;

  /// The question, drawn as the card title in [multiSelect] mode. The
  /// single-choice chips sit under the answer text, which already asks it.
  final String question;

  /// Lets the reader pick several options and confirm them together.
  final bool multiSelect;

  @override
  Widget build(BuildContext context) {
    if (multiSelect) {
      return _MultiSelectCard(
        question: question,
        options: options,
        onSubmit: onSelect,
      );
    }
    final theme = Theme.of(context);
    final accent = theme.colorScheme.primary;
    final onSurface = theme.colorScheme.onSurface;

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        children: [
          for (var i = 0; i < options.length; i++)
            _OptionChip(
              index: i + 1,
              label: options[i],
              accent: accent,
              onSurface: onSurface,
              onTap: () => onSelect(options[i]),
            ),
        ],
      ),
    );
  }
}

/// The two fixed strings of the multi-select card. Kept here rather than in
/// `lib/l10n/` so the card stays one self-contained file; the languages are
/// the app's five.
const Map<String, (String, String)> _kMultiStrings = <String, (String, String)>{
  'en': ('Choose all that apply', 'Confirm'),
  'de': ('Wähle alles Passende', 'Bestätigen'),
  'es': ('Elige todo lo que corresponda', 'Confirmar'),
  'fr': ('Choisis tout ce qui convient', 'Confirmer'),
  'pt': ('Escolhe tudo o que se aplica', 'Confirmar'),
};

String _letter(int i) => i < 26 ? String.fromCharCode(65 + i) : '${i + 1}';

class _MultiSelectCard extends StatefulWidget {
  const _MultiSelectCard({
    required this.question,
    required this.options,
    required this.onSubmit,
  });

  final String question;
  final List<String> options;
  final ValueChanged<String> onSubmit;

  @override
  State<_MultiSelectCard> createState() => _MultiSelectCardState();
}

class _MultiSelectCardState extends State<_MultiSelectCard> {
  final Set<int> _picked = <int>{};

  void _submit() {
    if (_picked.isEmpty) return;
    final List<int> order = _picked.toList()..sort();
    widget.onSubmit(order.map((int i) => widget.options[i]).join(', '));
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final (String hint, String confirm) =
        _kMultiStrings[Localizations.maybeLocaleOf(context)?.languageCode] ??
        _kMultiStrings['en']!;

    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
        decoration: BoxDecoration(
          color: cs.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (widget.question.isNotEmpty)
              Text(
                widget.question,
                style: theme.textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.w700,
                  color: cs.onSurface,
                ),
              ),
            Padding(
              padding: const EdgeInsets.only(top: 2, bottom: 10),
              child: Text(
                hint,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: cs.onSurfaceVariant,
                ),
              ),
            ),
            for (int i = 0; i < widget.options.length; i++)
              _MultiRow(
                letter: _letter(i),
                label: widget.options[i],
                picked: _picked.contains(i),
                onTap: () => setState(() {
                  if (!_picked.remove(i)) _picked.add(i);
                }),
              ),
            const SizedBox(height: 10),
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FilledButton(
                onPressed: _picked.isEmpty ? null : _submit,
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  minimumSize: const Size(0, 44),
                  padding: const EdgeInsets.symmetric(horizontal: 22),
                ),
                child: Text(confirm),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MultiRow extends StatelessWidget {
  const _MultiRow({
    required this.letter,
    required this.label,
    required this.picked,
    required this.onTap,
  });

  final String letter;
  final String label;
  final bool picked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme cs = theme.colorScheme;
    final TextStyle? style = theme.textTheme.bodyLarge?.copyWith(
      color: cs.onSurface,
      height: 1.35,
    );
    final double lineHeight = (style?.fontSize ?? 16) * 1.35;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Material(
        color: picked ? cs.primary.withValues(alpha: 0.12) : Colors.transparent,
        borderRadius: BorderRadius.circular(14),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Semantics(
            checked: picked,
            label: label,
            excludeSemantics: true,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  // One text line high, so the badge sits on the first line of
                  // a wrapped option.
                  SizedBox(
                    height: lineHeight,
                    child: Center(
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 24,
                        height: 24,
                        alignment: Alignment.center,
                        decoration: BoxDecoration(
                          color: cs.primary,
                          borderRadius: BorderRadius.circular(7),
                        ),
                        child: picked
                            ? HugeIcon(
                                HugeIcons.tick02,
                                size: 15,
                                color: cs.onPrimary,
                              )
                            : Text(
                                letter,
                                style: TextStyle(
                                  color: cs.onPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  height: 1,
                                ),
                              ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: Text(label, style: style)),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _OptionChip extends StatefulWidget {
  const _OptionChip({
    required this.index,
    required this.label,
    required this.accent,
    required this.onSurface,
    required this.onTap,
  });

  final int index;
  final String label;
  final Color accent;
  final Color onSurface;
  final VoidCallback onTap;

  @override
  State<_OptionChip> createState() => _OptionChipState();
}

class _OptionChipState extends State<_OptionChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bgAlpha = _hovered ? 0.18 : 0.08;
    final borderAlpha = _hovered ? 0.7 : 0.4;

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: widget.accent.withValues(alpha: borderAlpha),
            ),
            color: widget.accent.withValues(alpha: bgAlpha),
          ),
          child: Text(
            '${widget.index}. ${widget.label}',
            style: TextStyle(
              color: widget.onSurface,
              fontWeight: FontWeight.w600,
              fontSize: 14,
            ),
          ),
        ),
      ),
    );
  }
}
