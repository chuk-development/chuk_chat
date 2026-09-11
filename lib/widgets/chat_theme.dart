import 'package:flutter/material.dart';

/// Shared look tokens for the CoWork chat surface.
///
/// The goal is the familiar ChatGPT transcript: one centered, width-capped
/// column, a generous vertical rhythm, a quiet grey pill for the user, and the
/// agent answer as plain full-width text with no bubble. Both the transcript
/// widgets and the composer read these numbers, so the column and the input box
/// line up on the same axis.
abstract final class ChatMetrics {
  /// The reading column width. ChatGPT caps its text near this value, so a wide
  /// window still reads as one narrow thread instead of a full-bleed page.
  static const double maxColumnWidth = 768;

  /// Space above the first row of a new turn (a side flip). Big enough that the
  /// eye reads the user and the agent as separate blocks.
  static const double turnGap = 26;

  /// Space above a row that continues the same side. Small, so a group tucks in.
  static const double tightGap = 6;

  /// The transcript's own outer padding inside the capped column.
  static const EdgeInsets listPadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 20,
  );

  /// The user pill corner radius and its inner padding.
  static const double userBubbleRadius = 22;
  static const EdgeInsets userBubblePadding = EdgeInsets.symmetric(
    horizontal: 16,
    vertical: 10,
  );

  /// The user pill never spans the whole column; it stops at this fraction of
  /// the available width, like ChatGPT.
  static const double userMaxWidthFactor = 0.82;

  /// The agent paragraph reads a little larger than default body text, with an
  /// airy line height — the single biggest driver of the ChatGPT feel.
  static const double assistantFontSize = 16;
  static const double assistantLineHeight = 1.65;
}

/// Role-based colours for the transcript, derived from the active theme so the
/// same widgets read right in light and dark.
///
/// Only the user pill and the agent text carry a fixed ChatGPT-like grey; every
/// other colour comes from the [ColorScheme] so a retuned app theme still flows
/// through.
class ChatPalette {
  const ChatPalette({
    required this.userBubble,
    required this.userText,
    required this.assistantText,
    required this.muted,
    required this.hairline,
    required this.copyIcon,
  });

  /// The user message pill background.
  final Color userBubble;

  /// The text inside the user pill.
  final Color userText;

  /// The agent answer text colour.
  final Color assistantText;

  /// A quiet colour for process detail and secondary labels.
  final Color muted;

  /// A faint divider colour.
  final Color hairline;

  /// The small action-icon colour under an answer.
  final Color copyIcon;

  factory ChatPalette.of(BuildContext context) {
    final theme = Theme.of(context);
    final dark = theme.brightness == Brightness.dark;
    return ChatPalette(
      // ChatGPT uses a soft grey pill: near-white in light, a raised grey in
      // dark. Fixed values keep the pill legible whatever the scaffold ground.
      userBubble: dark ? const Color(0xFF303030) : const Color(0xFFF4F4F4),
      userText: dark ? const Color(0xFFECECEC) : const Color(0xFF0D0D0D),
      assistantText: theme.colorScheme.onSurface,
      muted: theme.colorScheme.onSurfaceVariant,
      hairline: theme.dividerColor.withValues(alpha: 0.5),
      copyIcon: theme.colorScheme.onSurfaceVariant,
    );
  }

  /// The paragraph style the agent answer renders with.
  TextStyle assistantParagraph() => TextStyle(
    fontSize: ChatMetrics.assistantFontSize,
    height: ChatMetrics.assistantLineHeight,
    color: assistantText,
  );
}

/// Wraps [child] so any Markdown inside it reads at the chat's paragraph size.
///
/// [AgentMarkdown] paints its body text from `theme.textTheme.bodyMedium`, so
/// overriding that one role here — and nothing else — bumps the answer to the
/// ChatGPT reading size without touching the Markdown widget itself.
class ChatAssistantTextTheme extends StatelessWidget {
  const ChatAssistantTextTheme({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final palette = ChatPalette.of(context);
    final base = theme.textTheme.bodyMedium ?? const TextStyle();
    return Theme(
      data: theme.copyWith(
        textTheme: theme.textTheme.copyWith(
          bodyMedium: base.copyWith(
            fontSize: ChatMetrics.assistantFontSize,
            height: ChatMetrics.assistantLineHeight,
            color: palette.assistantText,
          ),
        ),
      ),
      child: child,
    );
  }
}

/// Centres its [child] in the reading column: horizontally capped at
/// [ChatMetrics.maxColumnWidth], full width on a narrow screen. Both the
/// transcript and the composer wrap in this, so they share one axis.
class ChatColumn extends StatelessWidget {
  const ChatColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: ChatMetrics.maxColumnWidth),
        child: child,
      ),
    );
  }
}
