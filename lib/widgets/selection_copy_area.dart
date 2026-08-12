// lib/widgets/selection_copy_area.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show SelectedContent;
import 'package:flutter/services.dart';

import 'package:chuk_chat/utils/clipboard_text_sanitizer.dart';

/// Pure decision logic for the copy shortcut, kept out of the widget so it can
/// be unit-tested without a binding.
class SelectionCopyShortcut {
  const SelectionCopyShortcut._();

  /// Whether [event] is the "copy" shortcut for [platform].
  ///
  /// macOS uses Cmd+C, every other platform Ctrl+C. Shift and Alt must not be
  /// held — Ctrl+Shift+C is a different shortcut on most desktops.
  static bool isCopyIntent({
    required KeyEvent event,
    required bool isControlPressed,
    required bool isMetaPressed,
    required bool isShiftPressed,
    required bool isAltPressed,
    required TargetPlatform platform,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return false;
    }
    if (event.logicalKey != LogicalKeyboardKey.keyC) {
      return false;
    }
    if (isShiftPressed || isAltPressed) {
      return false;
    }
    if (platform == TargetPlatform.macOS) {
      return isMetaPressed && !isControlPressed;
    }
    return isControlPressed && !isMetaPressed;
  }
}

/// A [SelectionArea] whose Ctrl+C / Cmd+C does not depend on the focus tree.
///
/// Flutter routes the copy shortcut through focus: only the [SelectableRegion]
/// that owns the primary focus reacts to Ctrl+C. In a chat screen the composer
/// `TextField` normally owns the focus (it is `autofocus: true` and is
/// re-focused after nearly every action), so a mouse selection in the message
/// list was copied to nothing at all — the key event went to the text field,
/// whose own selection is empty.
///
/// This widget removes that dependency. It tracks the current selection of the
/// wrapped [SelectionArea] and registers a [HardwareKeyboard] handler.
/// Flutter always runs those handlers BEFORE the focus-based shortcut dispatch
/// (`KeyEventManager` calls `HardwareKeyboard.handleKeyEvent` first and
/// `keyMessageHandler` — which drives `Shortcuts`/`Actions` — afterwards), so
/// the selection is copied no matter where the focus currently sits.
///
/// The handler deliberately steps aside when:
///  * nothing is selected inside this area,
///  * an [EditableText] holds the focus (a text field must copy its own
///    selection),
///  * the enclosing route is not the top-most one (a dialog is open).
class SelectionCopyArea extends StatefulWidget {
  const SelectionCopyArea({
    super.key,
    required this.child,
    this.focusNode,
    this.contextMenuBuilder,
    this.onSelectionChanged,
  });

  /// The content whose text can be selected.
  final Widget child;

  /// Focus node handed to the inner [SelectableRegion]. Pass one in to be able
  /// to focus the region explicitly (e.g. on pointer down), which also makes
  /// Flutter's own shortcut path work.
  final FocusNode? focusNode;

  /// Right-click menu builder, forwarded to [SelectionArea].
  final SelectableRegionContextMenuBuilder? contextMenuBuilder;

  /// Forwarded to [SelectionArea]; called in addition to the internal tracking.
  final ValueChanged<SelectedContent?>? onSelectionChanged;

  @override
  State<SelectionCopyArea> createState() => SelectionCopyAreaState();
}

class SelectionCopyAreaState extends State<SelectionCopyArea> {
  String? _selectedText;

  /// Text currently selected inside this area. Exposed for tests.
  @visibleForTesting
  String? get selectedText => _selectedText;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(handleKeyEvent);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(handleKeyEvent);
    super.dispose();
  }

  void _handleSelectionChanged(SelectedContent? content) {
    _selectedText = content?.plainText;
    widget.onSelectionChanged?.call(content);
  }

  /// Returns true when the event was consumed. Public for tests.
  @visibleForTesting
  bool handleKeyEvent(KeyEvent event) {
    if (!mounted) {
      return false;
    }
    final keyboard = HardwareKeyboard.instance;
    final bool isCopy = SelectionCopyShortcut.isCopyIntent(
      event: event,
      isControlPressed: keyboard.isControlPressed,
      isMetaPressed: keyboard.isMetaPressed,
      isShiftPressed: keyboard.isShiftPressed,
      isAltPressed: keyboard.isAltPressed,
      platform: defaultTargetPlatform,
    );
    if (!isCopy) {
      return false;
    }

    final String? text = _selectedText;
    if (text == null || text.isEmpty) {
      // Nothing selected here — leave the shortcut to whoever else wants it.
      return false;
    }
    if (_focusedEditableHasSelection()) {
      // A text field holds a real selection of its own — that one wins.
      // A merely focused-but-collapsed field (the chat composer is focused
      // almost always) must NOT block the message copy: that was the bug.
      return false;
    }
    final ModalRoute<Object?>? route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) {
      // A dialog or another page sits on top of this area.
      return false;
    }

    unawaited(_copy(text));
    return true;
  }

  /// Whether the focused text field has a non-collapsed selection of its own.
  ///
  /// Only then does the field own the copy shortcut. A focused field with a
  /// plain caret has nothing to copy, so the message selection wins.
  static bool _focusedEditableHasSelection() {
    final BuildContext? focusContext =
        FocusManager.instance.primaryFocus?.context;
    if (focusContext == null) {
      return false;
    }
    final EditableTextState? editableState = focusContext
        .findAncestorStateOfType<EditableTextState>();
    if (editableState == null) {
      return false;
    }
    final TextSelection selection = editableState.textEditingValue.selection;
    return selection.isValid && !selection.isCollapsed;
  }

  Future<void> _copy(String text) async {
    await Clipboard.setData(
      ClipboardData(text: ClipboardTextSanitizer.sanitize(text)),
    );
    // Flutter's own focus-routed copy runs after this handler and would put the
    // unsanitized text back when the region happens to hold the focus. Clean the
    // clipboard once more after the event has been dispatched fully.
    await Future<void>.delayed(Duration.zero);
    await ClipboardTextSanitizer.sanitizeClipboardInPlace();
  }

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      focusNode: widget.focusNode,
      contextMenuBuilder: widget.contextMenuBuilder,
      onSelectionChanged: _handleSelectionChanged,
      child: widget.child,
    );
  }
}
