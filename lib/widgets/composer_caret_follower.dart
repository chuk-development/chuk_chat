/// Keeps the composer's caret on screen after the text changes.
///
/// Flutter scrolls a multi-line field to the caret only for edits the field
/// makes itself (typing, its own paste). Every edit that goes through the
/// controller — the desktop smart paste, a restored draft, a transcript, an
/// edited message loaded back — leaves the field scrolled where it was, so a
/// long paste ends below the visible lines with the caret out of sight. This
/// listens to the controller and, one frame after any text change, scrolls the
/// caret into view; with no valid caret it scrolls to the end.
library;

import 'package:flutter/scheduler.dart';
import 'package:flutter/widgets.dart';

class ComposerCaretFollower {
  ComposerCaretFollower({
    required this.controller,
    required this.focusNode,
    required this.scrollController,
  }) : _lastText = controller.text {
    controller.addListener(_onChanged);
  }

  final TextEditingController controller;

  /// The field's focus node. Its context sits inside the field's
  /// [EditableText], which is how the caret is found.
  final FocusNode focusNode;

  /// The field's own scroll controller, the fallback when there is no caret.
  final ScrollController scrollController;

  String _lastText;
  bool _scheduled = false;
  bool _disposed = false;

  void _onChanged() {
    final String text = controller.text;
    // Selection-only changes are the user moving the caret or scrolling;
    // following them would fight the mouse.
    if (text == _lastText) return;
    _lastText = text;
    if (_scheduled) return;
    _scheduled = true;
    SchedulerBinding.instance.addPostFrameCallback((_) {
      _scheduled = false;
      if (!_disposed) _reveal();
    });
  }

  void _reveal() {
    final EditableTextState? editable = focusNode.context
        ?.findAncestorStateOfType<EditableTextState>();
    final TextSelection selection = controller.selection;
    if (editable != null && editable.mounted && selection.isValid) {
      editable.bringIntoView(selection.extent);
      return;
    }
    if (scrollController.hasClients) {
      scrollController.jumpTo(scrollController.position.maxScrollExtent);
    }
  }

  void dispose() {
    _disposed = true;
    controller.removeListener(_onChanged);
  }
}
