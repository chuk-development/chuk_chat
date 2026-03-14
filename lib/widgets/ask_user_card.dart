// lib/widgets/ask_user_card.dart

import 'package:flutter/material.dart';

/// Interactive option buttons shown below messages that used the ask_user tool.
///
/// Displays styled, tappable chips for each option so the user can answer
/// by clicking instead of typing. Once an option is selected, the card is
/// replaced with a subtle "answered" indicator.
class AskUserCard extends StatelessWidget {
  const AskUserCard({super.key, required this.options, required this.onSelect});

  /// The option labels extracted from the ask_user tool call arguments.
  final List<String> options;

  /// Called with the selected option label when the user taps a button.
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
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
