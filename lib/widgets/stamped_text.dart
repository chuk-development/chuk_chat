/// Text that carries the bubble stamp at the end of its last line.
///
/// The rule is the one every messenger uses: measure the LAST line of the
/// text; if that line plus a gap plus the stamp still fits inside the bubble,
/// the stamp rides at the end of that line and the bubble does not grow a
/// line. Only when it does not fit does the stamp drop onto its own line,
/// still at the end, and still tight against the text.
///
/// The measurement is done by the text layout itself, not by arithmetic: an
/// invisible copy of the stamp is appended to the text in a trailing
/// [WidgetSpan], so the line breaker reserves exactly the stamp's footprint
/// and wraps it like any other word. The real, visible stamp is then painted
/// over that reserved space, pinned to the bottom end corner. Nothing is
/// faked with spaces, and the box still shrink-wraps its content — the
/// reserved span is part of the intrinsic width, so a short message stays
/// short.
library;

import 'package:flutter/material.dart';

/// Text plus an optional bottom-end [stamp], laid out by the messenger rule.
class StampedText extends StatelessWidget {
  const StampedText({
    super.key,
    required this.text,
    required this.style,
    this.stamp,
    this.gap = 8,
    this.fillWidth = false,
  });

  /// The message body. Plain text only — a Markdown body keeps its own
  /// renderer and its own stamp placement.
  final String text;

  final TextStyle style;

  /// The stamp to place. Null renders the text alone.
  final Widget? stamp;

  /// Clear space between the end of the last line and the stamp.
  final double gap;

  /// Whether the box takes the width it is offered instead of shrink-wrapping.
  /// A coworker's bubble uses the full reading lane, so its stamp belongs in
  /// the bubble's corner; a user's bubble hugs its text.
  final bool fillWidth;

  @override
  Widget build(BuildContext context) {
    final Widget? stamp = this.stamp;
    if (stamp == null) {
      return fillWidth
          ? SizedBox(
              width: double.infinity,
              child: Text(text, style: style),
            )
          : Text(text, style: style);
    }
    final Widget body = Stack(
      children: <Widget>[
        Text.rich(
          TextSpan(
            style: style,
            children: <InlineSpan>[
              TextSpan(text: text),
              WidgetSpan(
                alignment: PlaceholderAlignment.bottom,
                child: ExcludeSemantics(
                  child: Opacity(
                    opacity: 0,
                    child: Padding(
                      padding: EdgeInsetsDirectional.only(start: gap),
                      child: stamp,
                    ),
                  ),
                ),
              ),
            ],
          ),
          // The style is given to the Text as well, so the ambient default
          // text style cannot leak into the line that only holds the reserved
          // space and make that line taller than a line of this text.
          style: style,
        ),
        PositionedDirectional(end: 0, bottom: 0, child: stamp),
      ],
    );
    if (!fillWidth) return body;
    return SizedBox(width: double.infinity, child: body);
  }
}

/// Everything that means "this is not a plain line of prose": emphasis, code,
/// links, headings, quotes, lists, tables, HTML, LaTeX, rules.
final RegExp _kMarkupMarker = RegExp(
  // Inline markers, HTML, tables, LaTeX and escapes.
  r'[`*_~#>|\[\]<>\\$]'
  // An indented code block.
  r'|^[ \t]{4,}\S'
  // A list item or a numbered item.
  r'|^[ \t]*(?:[-+][ \t]|\d+[.)][ \t])'
  // A setext underline or a thematic break.
  r'|^[ \t]*(?:={2,}|-{2,})[ \t]*$'
  // Anything the renderer would turn into a link by itself.
  r'|https?://|www\.|\bmailto:',
  multiLine: true,
);

/// A run of digits the phone linkifier would turn into a dial link.
final RegExp _kDialable = RegExp(r'\+?\d[\d ()./-]{5,}\d');

/// Whether [text] renders the same as a plain [Text] does — so the stamp can
/// ride inside it. Anything Markdown would treat as markup, and anything a
/// linkifier would rewrite, answers false and keeps the Markdown renderer.
///
/// The test is deliberately strict: a false negative only means the stamp
/// stays where it is today, while a false positive would silently drop a
/// heading, a list or a link out of an answer.
bool isPlainStampableText(String text) {
  final String trimmed = text.trim();
  if (trimmed.isEmpty) return false;
  // More than one paragraph: Markdown spaces paragraphs apart, plain text
  // does not, so the two renderings would not agree.
  if (trimmed.contains('\n\n')) return false;
  // The markers are read off the raw text: trimming would hide the four
  // leading spaces that make a line an indented code block.
  if (_kMarkupMarker.hasMatch(text)) return false;
  if (_kDialable.hasMatch(trimmed)) return false;
  return true;
}
