import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

/// Keeps the widget of each transcript row while nothing it shows has
/// changed.
///
/// A [SliverList] with a builder delegate calls its builder again for every
/// row on screen whenever the chat screen rebuilds: a focus change of the
/// composer, a new composer height, a keyboard step, a chat switch. Each row
/// is a full message bubble (markdown, action buttons, tooltips, semantics),
/// so on a phone that rebuild cost 100 to 300 ms and showed as a hang after
/// the keyboard opened or closed. When the builder hands back the SAME widget
/// instance, Flutter skips the whole row subtree.
///
/// A row is reused only when its message map holds the same values as when
/// it was built (the send and stream code edits these maps in place, so the
/// map's identity says nothing) and every other input, listed in [inputs] by
/// the caller, is equal. Inherited widgets (theme, locale, media query)
/// still reach a reused row through its own dependencies.
class TranscriptRowMemo {
  final Map<int, _Row> _rows = <int, _Row>{};

  /// The kept widget of row [index], or null when [message] or [inputs]
  /// differ from the last [store] for that row.
  Widget? lookup(int index, Map<String, String> message, List<Object?> inputs) {
    final _Row? row = _rows[index];
    if (row == null) return null;
    if (!listEquals(row.inputs, inputs)) return null;
    if (!mapEquals(row.message, message)) return null;
    return row.widget;
  }

  /// Remembers [widget] as row [index], built from [message] and [inputs].
  /// [message] is copied: a later in-place edit must not change the copy.
  void store(
    int index,
    Map<String, String> message,
    List<Object?> inputs,
    Widget widget,
  ) {
    _rows[index] = _Row(Map<String, String>.of(message), inputs, widget);
  }

  /// Drops the rows at [length] and past it (the transcript got shorter).
  void trimTo(int length) {
    if (_rows.isEmpty) return;
    _rows.removeWhere((int index, _) => index >= length);
  }

  /// Drops every kept row (another chat, a cleared transcript).
  void clear() => _rows.clear();

  @visibleForTesting
  int get length => _rows.length;
}

class _Row {
  _Row(this.message, this.inputs, this.widget);

  final Map<String, String> message;
  final List<Object?> inputs;
  final Widget widget;
}
