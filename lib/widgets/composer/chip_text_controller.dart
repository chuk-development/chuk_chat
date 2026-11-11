// lib/widgets/composer/chip_text_controller.dart
//
// The composer's text controller with atomic chips (deepseek-harness idea
// 68). An item picked from the `/` or `@` menu becomes a chip: its text stays
// in [text] as it is sent ("/deep-research", "@Project notes"), so every send
// path reads the message unchanged, but the field draws the range as one pill
// ([buildTextSpan], a WidgetSpan) and edits treat it as one character:
//
// * the caret never stops inside a chip;
// * the first Backspace at the end of a chip selects it, the second deletes
//   it (Delete before a chip does the same from the other side);
// * an edit that cuts into a chip turns it back into plain text.
import 'package:flutter/material.dart';

/// What a chip stands for. Drives its glyph.
enum ComposerChipKind { skill, mode, file, agent, workspace, chat, command }

/// One chip: the range [start, end) of the controller's text.
@immutable
class ComposerChip {
  const ComposerChip({
    required this.start,
    required this.end,
    required this.label,
    this.kind = ComposerChipKind.file,
  });

  final int start;
  final int end;
  final String label;
  final ComposerChipKind kind;

  int get length => end - start;

  ComposerChip shift(int delta) => ComposerChip(
    start: start + delta,
    end: end + delta,
    label: label,
    kind: kind,
  );

  bool containsInside(int offset) => offset > start && offset < end;
}

class ChipTextEditingController extends TextEditingController {
  ChipTextEditingController({super.text});

  List<ComposerChip> _chips = <ComposerChip>[];

  /// The chips, ordered by position.
  List<ComposerChip> get chips => List<ComposerChip>.unmodifiable(_chips);

  /// The chip that covers [offset] strictly inside, or null.
  ComposerChip? chipInside(int offset) {
    for (final ComposerChip c in _chips) {
      if (c.containsInside(offset)) return c;
    }
    return null;
  }

  /// Whether [offset] lies in a chip, its first character included.
  bool isInChip(int offset) =>
      _chips.any((ComposerChip c) => offset >= c.start && offset < c.end);

  /// Replaces [start, end) with [literal] plus one space and makes
  /// [literal] a chip drawn as [label]. The caret goes after the space.
  void insertChip({
    required int start,
    required int end,
    required String literal,
    required String label,
    ComposerChipKind kind = ComposerChipKind.file,
  }) {
    final String old = text;
    final int s = start.clamp(0, old.length);
    final int e = end.clamp(s, old.length);
    final String inserted = '$literal ';
    final String next = old.replaceRange(s, e, inserted);
    final int delta = inserted.length - (e - s);
    final List<ComposerChip> kept = <ComposerChip>[
      for (final ComposerChip c in _chips)
        if (c.end <= s) c else if (c.start >= e) c.shift(delta),
      ComposerChip(start: s, end: s + literal.length, label: label, kind: kind),
    ]..sort((ComposerChip a, ComposerChip b) => a.start.compareTo(b.start));
    _chips = kept;
    super.value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: s + inserted.length),
    );
  }

  /// Replaces [start, end) with [replacement] as plain text, moving the
  /// chips after it (the menu removes its trigger token this way).
  void replaceRangePlain(int start, int end, String replacement) {
    final String old = text;
    final int s = start.clamp(0, old.length);
    final int e = end.clamp(s, old.length);
    final int delta = replacement.length - (e - s);
    _chips = <ComposerChip>[
      for (final ComposerChip c in _chips)
        if (c.end <= s) c else if (c.start >= e) c.shift(delta),
    ];
    super.value = TextEditingValue(
      text: old.replaceRange(s, e, replacement),
      selection: TextSelection.collapsed(offset: s + replacement.length),
    );
  }

  @override
  set value(TextEditingValue newValue) {
    if (_chips.isEmpty) {
      super.value = newValue;
      return;
    }
    super.value = _applyAtomic(super.value, newValue);
  }

  TextEditingValue _applyAtomic(TextEditingValue old, TextEditingValue next) {
    if (old.text == next.text) {
      return next.copyWith(selection: _snapSelection(old.selection, next));
    }

    final _Edit edit = _Edit.between(old, next);

    // Backspace at the end of a chip, or Delete at its start: select the
    // chip first instead of cutting one character out of it.
    if (old.selection.isCollapsed && edit.inserted == 0 && edit.removed == 1) {
      final int caret = old.selection.baseOffset;
      for (final ComposerChip c in _chips) {
        final bool backspace = edit.start == caret - 1 && c.end == caret;
        final bool delete = edit.start == caret && c.start == caret;
        if (backspace || delete) {
          return old.copyWith(
            selection: TextSelection(baseOffset: c.start, extentOffset: c.end),
            composing: TextRange.empty,
          );
        }
      }
    }

    final int removedEnd = edit.start + edit.removed;
    final int delta = edit.inserted - edit.removed;
    _chips = <ComposerChip>[
      for (final ComposerChip c in _chips)
        if (c.end <= edit.start)
          c
        else if (c.start >= removedEnd)
          c.shift(delta),
    ];
    return next.copyWith(selection: _snapSelection(old.selection, next));
  }

  /// Keeps a collapsed caret out of chips: it goes to the chip edge in the
  /// direction it moved. A range selection grows to whole chips.
  TextSelection _snapSelection(TextSelection before, TextEditingValue next) {
    final TextSelection sel = next.selection;
    if (!sel.isValid || _chips.isEmpty) return sel;
    if (sel.isCollapsed) {
      final ComposerChip? c = chipInside(sel.baseOffset);
      if (c == null) return sel;
      final bool movingLeft =
          before.isValid && sel.baseOffset < before.baseOffset;
      return TextSelection.collapsed(offset: movingLeft ? c.start : c.end);
    }
    int base = sel.baseOffset;
    int extent = sel.extentOffset;
    final ComposerChip? atBase = chipInside(base);
    final ComposerChip? atExtent = chipInside(extent);
    if (atBase != null) base = base <= extent ? atBase.start : atBase.end;
    if (atExtent != null) {
      extent = extent >= base ? atExtent.end : atExtent.start;
    }
    return TextSelection(baseOffset: base, extentOffset: extent);
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final String t = text;
    final List<ComposerChip> chips = <ComposerChip>[
      for (final ComposerChip c in _chips)
        if (c.start >= 0 && c.end <= t.length && c.length > 0) c,
    ];
    if (chips.isEmpty) {
      return super.buildTextSpan(
        context: context,
        style: style,
        withComposing: withComposing,
      );
    }
    final TextRange composing = value.composing;
    final bool showComposing =
        withComposing && composing.isValid && !composing.isCollapsed;
    final List<InlineSpan> children = <InlineSpan>[];

    void plain(int from, int to) {
      if (to <= from) return;
      if (showComposing && composing.start < to && composing.end > from) {
        final int cs = composing.start.clamp(from, to);
        final int ce = composing.end.clamp(from, to);
        if (cs > from) children.add(TextSpan(text: t.substring(from, cs)));
        children.add(
          TextSpan(
            text: t.substring(cs, ce),
            style: const TextStyle(decoration: TextDecoration.underline),
          ),
        );
        if (to > ce) children.add(TextSpan(text: t.substring(ce, to)));
        return;
      }
      children.add(TextSpan(text: t.substring(from, to)));
    }

    int at = 0;
    for (final ComposerChip c in chips) {
      if (c.start < at) continue;
      plain(at, c.start);
      // One placeholder for the chip's first character; the rest of the
      // chip's text is laid out with no width, so every offset still maps
      // to the text and the caret skips across it.
      children.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.middle,
          child: ComposerChipPill(chip: c, textStyle: style),
        ),
      );
      if (c.length > 1) {
        children.add(
          TextSpan(
            text: t.substring(c.start + 1, c.end),
            style: const TextStyle(
              fontSize: 0.01,
              letterSpacing: 0,
              color: Color(0x00000000),
            ),
          ),
        );
      }
      at = c.end;
    }
    plain(at, t.length);
    return TextSpan(style: style, children: children);
  }
}

/// The pill a chip is drawn as.
class ComposerChipPill extends StatelessWidget {
  const ComposerChipPill({super.key, required this.chip, this.textStyle});

  final ComposerChip chip;
  final TextStyle? textStyle;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final double size = (textStyle?.fontSize ?? 14) * 0.92;
    return Container(
      key: ValueKey<String>('composer-chip-${chip.start}'),
      margin: const EdgeInsets.symmetric(horizontal: 1),
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        // Below 28 px tall: the compact-chip corner (docs/DESIGN.md §6.1).
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        chip.label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: scheme.onSecondaryContainer,
          fontSize: size,
          fontWeight: FontWeight.w600,
          height: 1.2,
        ),
      ),
    );
  }
}

/// One edit between two texts: at [start], [removed] characters went and
/// [inserted] came.
class _Edit {
  const _Edit(this.start, this.removed, this.inserted);

  final int start;
  final int removed;
  final int inserted;

  static _Edit between(TextEditingValue old, TextEditingValue next) {
    final String a = old.text;
    final String b = next.text;
    // The selection tells where a keystroke happened; prefer it, because a
    // repeated character makes the plain prefix/suffix diff ambiguous.
    final TextSelection os = old.selection;
    final TextSelection ns = next.selection;
    if (os.isValid && ns.isValid && ns.isCollapsed) {
      final int from = os.start;
      final int to = os.end;
      final int caret = ns.baseOffset;
      final int inserted = caret - from;
      if (from >= 0 &&
          to <= a.length &&
          inserted >= 0 &&
          b.length - inserted == a.length - (to - from) &&
          b.startsWith(a.substring(0, from)) &&
          b.substring(caret) == a.substring(to)) {
        return _Edit(from, to - from, inserted);
      }
      // Backspace with a collapsed caret: one character before it went.
      if (os.isCollapsed &&
          caret == from - 1 &&
          a.length - b.length == 1 &&
          b == a.replaceRange(from - 1, from, '')) {
        return _Edit(from - 1, 1, 0);
      }
    }
    int p = 0;
    final int max = a.length < b.length ? a.length : b.length;
    while (p < max && a.codeUnitAt(p) == b.codeUnitAt(p)) {
      p++;
    }
    int s = 0;
    while (s < max - p &&
        a.codeUnitAt(a.length - 1 - s) == b.codeUnitAt(b.length - 1 - s)) {
      s++;
    }
    return _Edit(p, a.length - p - s, b.length - p - s);
  }
}
