// lib/platform_specific/chat/handlers/desktop_clipboard_handler.dart
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:pasteboard/pasteboard.dart';

import 'package:chuk_chat/utils/clipboard_text_sanitizer.dart';
import 'package:chuk_chat/utils/io_helper.dart';
import 'package:chuk_chat/utils/path_provider_stub.dart'
    if (dart.library.io) 'package:path_provider/path_provider.dart';

/// Handles desktop-specific clipboard operations and context menus.
///
/// Encapsulates smart paste (Ctrl+V) with image and long-text-as-attachment
/// support, right-click context menus for the composer and message selection
/// areas, clipboard sanitization, and temp-directory cleanup.
class DesktopClipboardHandler {
  /// Threshold (characters) above which pasted text is auto-converted to an
  /// attached `.txt` file instead of being inserted into the composer.
  static const int kLongPasteThreshold = 3000;

  /// How long paste temp directories are kept before cleanup removes them.
  static const Duration kPasteTempRetention = Duration(hours: 24);

  /// Callback invoked to process one or more file paths (e.g. after pasting an
  /// image or creating a long-text attachment file).
  final Future<void> Function(List<String> paths) onProcessFilePaths;

  /// Creates a [DesktopClipboardHandler].
  ///
  /// [onProcessFilePaths] is called when a paste operation produces file(s)
  /// that should be attached to the current message.
  const DesktopClipboardHandler({required this.onProcessFilePaths});

  // ---------------------------------------------------------------------------
  // Text selection helper
  // ---------------------------------------------------------------------------

  /// Returns the selected text within [value], or the full text if nothing is
  /// selected.
  String selectedTextOrAll(TextEditingValue value) {
    final selection = value.selection;
    if (selection.isValid && !selection.isCollapsed) {
      return selection.textInside(value.text);
    }
    return value.text;
  }

  // ---------------------------------------------------------------------------
  // Context menus
  // ---------------------------------------------------------------------------

  /// Builds a right-click context menu for the text composer.
  ///
  /// The built-in copy action is replaced (or added if absent) with a variant
  /// that sanitizes clipboard content (strips embedded base64 image data).
  Widget buildComposerContextMenu(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final buttonItems = editableTextState.contextMenuButtonItems.map((item) {
      if (item.type != ContextMenuButtonType.copy) {
        return item;
      }

      return ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: () {
          final text = selectedTextOrAll(editableTextState.textEditingValue);
          if (text.isNotEmpty) {
            final sanitized = ClipboardTextSanitizer.sanitize(text);
            Clipboard.setData(ClipboardData(text: sanitized));
          }
          ContextMenuController.removeAny();
        },
      );
    }).toList();

    final hasCopy = buttonItems.any(
      (item) => item.type == ContextMenuButtonType.copy,
    );

    if (!hasCopy) {
      buttonItems.insert(
        0,
        ContextMenuButtonItem(
          type: ContextMenuButtonType.copy,
          onPressed: () {
            final text = selectedTextOrAll(editableTextState.textEditingValue);
            if (text.isNotEmpty) {
              final sanitized = ClipboardTextSanitizer.sanitize(text);
              Clipboard.setData(ClipboardData(text: sanitized));
            }
            ContextMenuController.removeAny();
          },
        ),
      );
    }

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  /// Builds a right-click context menu for the message selection area.
  ///
  /// Wraps the built-in copy action so that clipboard content is sanitized
  /// immediately after the native copy completes.
  Widget buildMessageContextMenu(
    BuildContext context,
    SelectableRegionState selectableRegionState,
  ) {
    final buttonItems = selectableRegionState.contextMenuButtonItems.map((
      item,
    ) {
      if (item.type != ContextMenuButtonType.copy) {
        return item;
      }

      return ContextMenuButtonItem(
        type: ContextMenuButtonType.copy,
        onPressed: () async {
          item.onPressed?.call();
          await Future<void>.delayed(Duration.zero);
          await sanitizeClipboardInPlace();
        },
      );
    }).toList();

    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  // ---------------------------------------------------------------------------
  // Clipboard sanitization
  // ---------------------------------------------------------------------------

  /// Reads the current clipboard text and, if it contains embedded base64 image
  /// data, replaces it with a sanitized version.
  Future<void> sanitizeClipboardInPlace() =>
      ClipboardTextSanitizer.sanitizeClipboardInPlace();

  // ---------------------------------------------------------------------------
  // Smart paste (Ctrl+V)
  // ---------------------------------------------------------------------------

  /// Handles a Ctrl+V paste.
  ///
  /// 1. If the clipboard contains an image, it is saved to a temp file and
  ///    forwarded via [onProcessFilePaths].
  /// 2. If the clipboard text exceeds [kLongPasteThreshold] characters, it is
  ///    written to a temp `.txt` file and forwarded via [onProcessFilePaths].
  /// 3. Otherwise, the text is inserted at the current cursor position in
  ///    [controller].
  Future<void> handleSmartPaste(TextEditingController controller) async {
    unawaited(cleanupOldPasteTempDirectories());

    // 1. Try image paste first
    try {
      final Uint8List? imageBytes = await Pasteboard.image;
      if (imageBytes != null && imageBytes.isNotEmpty) {
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final pasteDir = Directory('${tempDir.path}/paste_$timestamp');
        if (!await pasteDir.exists()) {
          await pasteDir.create(recursive: true);
        }
        final tempFile = File('${pasteDir.path}/clipboard_image.png');
        await tempFile.writeAsBytes(imageBytes);
        await onProcessFilePaths([tempFile.path]);
        return;
      }
    } catch (e) {
      // No image on clipboard or error reading it — fall through to text.
      if (kDebugMode) {
        debugPrint('Image paste skipped: $e');
      }
    }

    // 2. Handle text paste
    try {
      final clipData = await Clipboard.getData(Clipboard.kTextPlain);
      final String? text = clipData?.text;
      if (text == null || text.isEmpty) return;

      if (text.length > kLongPasteThreshold) {
        // Long text → create an attached .txt file
        final tempDir = await getTemporaryDirectory();
        final timestamp = DateTime.now().millisecondsSinceEpoch;
        final pasteDir = Directory('${tempDir.path}/paste_$timestamp');
        if (!await pasteDir.exists()) {
          await pasteDir.create(recursive: true);
        }
        final tempFile = File('${pasteDir.path}/clipboard_text.txt');
        await tempFile.writeAsString(text);
        await onProcessFilePaths([tempFile.path]);
      } else {
        // Short text → insert at cursor position normally
        final currentText = controller.text;
        final sel = controller.selection;
        final start = sel.isValid ? sel.start : currentText.length;
        final end = sel.isValid ? sel.end : currentText.length;
        final newText = currentText.replaceRange(start, end, text);
        controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: start + text.length),
        );
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Clipboard text paste error: $e');
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Temp directory cleanup
  // ---------------------------------------------------------------------------

  /// Removes paste temp directories older than [kPasteTempRetention].
  ///
  /// Directories are identified by the `paste_` prefix inside the system temp
  /// directory. Errors during cleanup are silently ignored.
  Future<void> cleanupOldPasteTempDirectories() async {
    if (kIsWeb) {
      return;
    }

    try {
      final tempDir = await getTemporaryDirectory();
      final dynamic tempDirDynamic = tempDir;
      final cutoff = DateTime.now().subtract(kPasteTempRetention);
      await for (final dynamic entity in tempDirDynamic.list(
        followLinks: false,
      )) {
        try {
          final String path = entity.path as String;
          final String name = path.split(Platform.pathSeparator).last;
          if (!name.startsWith('paste_')) {
            continue;
          }

          final dynamic stat = await entity.stat();
          final DateTime modified = stat.modified as DateTime;
          if (modified.isBefore(cutoff)) {
            await entity.delete(recursive: true);
          }
        } catch (_) {
          // Ignore cleanup failures for temp files.
        }
      }
    } catch (e) {
      if (kDebugMode) {
        debugPrint('Failed to clean old paste temp directories: $e');
      }
    }
  }
}
