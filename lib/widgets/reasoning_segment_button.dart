import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

/// The reasoning toggle as an oval (stadium) laid on the left end of the model
/// oval to form the merged `[ 🧠 | # Model ]` control pill. Wider than tall,
/// same rounding family as the outer oval: its left end coincides with the
/// oval's left rounding (same line) and its right end is the divider toward the
/// model name. Off → outline (opaque fill so the oval border underneath is
/// covered cleanly); on → filled bold with the inverted icon.
///
/// Shared by the desktop and mobile composers so both render an identical pill.
class ReasoningSegmentButton extends StatefulWidget {
  const ReasoningSegmentButton({
    super.key,
    required this.isActive,
    required this.onTap,
    required this.tooltip,
  });

  final bool isActive;
  final VoidCallback onTap;
  final String tooltip;

  static const double width = 50;
  static const double height = 36;

  @override
  State<ReasoningSegmentButton> createState() => _ReasoningSegmentButtonState();
}

class _ReasoningSegmentButtonState extends State<ReasoningSegmentButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final Color bg = Theme.of(context).scaffoldBackgroundColor;
    final Color iconFg = Theme.of(context).resolvedIconColor;
    // App accent — same fill as the send / voice-mode buttons (its icon is
    // black on the accent, so match that here).
    final Color accent = Theme.of(context).colorScheme.primary;
    final bool active = widget.isActive;

    // The gray outline stays put in BOTH states (only hover deepens it). Use
    // an OPAQUE gray (the off-state border's look flattened onto the bg) so it
    // stays visible over the accent fill when on — a translucent border washes
    // out against a bright fill.
    final Color borderColor = _hovered
        ? iconFg
        : Color.alphaBlend(iconFg.withValues(alpha: 0.4), bg);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 150),
            curve: Curves.easeOutCubic,
            width: ReasoningSegmentButton.width,
            height: ReasoningSegmentButton.height,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              // On → accent fill right up to the (still gray) border, no gap.
              // Opaque either way so the pill border underneath is covered.
              color: active ? accent : bg,
              borderRadius: BorderRadius.circular(
                ReasoningSegmentButton.height / 2,
              ),
              border: Border.all(color: borderColor, width: 1.8),
            ),
            child: Icon(
              Icons.psychology,
              color: active ? Colors.black : iconFg,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }
}
