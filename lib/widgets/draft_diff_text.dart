// lib/widgets/draft_diff_text.dart
//
// A revised draft with its changes marked (bead chuk_chat-gkt9): inserted
// words on a tonal fill, removed words struck through. Theme colours only,
// no glow (docs/DESIGN.md §8).

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/word_diff.dart';

/// Whether [before] -> [after] is a revision worth marking: something
/// changed, and enough stayed that it is the same draft and not a new mail
/// that happens to follow another one.
bool draftDiffWorthShowing(
  List<WordDiffSegment> segments, {
  double minKept = 0.3,
}) {
  if (!wordDiffHasChanges(segments)) return false;
  int kept = 0;
  int after = 0;
  for (final WordDiffSegment s in segments) {
    final int len = s.text.trim().length;
    if (s.op == WordDiffOp.equal) {
      kept += len;
      after += len;
    } else if (s.op == WordDiffOp.inserted) {
      after += len;
    }
  }
  if (after == 0) return true;
  return kept / after >= minKept;
}

/// The spans for [segments]: equal text in [base], inserted text on the
/// primary container, removed text struck through in the error colour.
List<InlineSpan> draftDiffSpans(
  List<WordDiffSegment> segments,
  ColorScheme scheme,
  TextStyle? base,
) {
  final TextStyle inserted = (base ?? const TextStyle()).copyWith(
    color: scheme.onPrimaryContainer,
    backgroundColor: scheme.primaryContainer,
    fontWeight: FontWeight.w600,
  );
  final TextStyle removed = (base ?? const TextStyle()).copyWith(
    color: scheme.error,
    decoration: TextDecoration.lineThrough,
    decorationColor: scheme.error,
    decorationThickness: 1.5,
  );
  return <InlineSpan>[
    for (final WordDiffSegment s in segments)
      TextSpan(
        text: s.text,
        style: switch (s.op) {
          WordDiffOp.equal => base,
          WordDiffOp.inserted => inserted,
          WordDiffOp.removed => removed,
        },
      ),
  ];
}

/// [after] with the changes against [before] marked.
class DraftDiffText extends StatelessWidget {
  const DraftDiffText({
    super.key,
    required this.before,
    required this.after,
    this.style,
    this.maxLines,
  });

  final String before;
  final String after;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? base =
        style ??
        Theme.of(
          context,
        ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    return Text.rich(
      TextSpan(children: draftDiffSpans(wordDiff(before, after), scheme, base)),
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: base,
    );
  }
}
