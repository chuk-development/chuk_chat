// lib/platform_specific/chat/widgets/fullscreen_composer.dart
//
// A whole screen for one long message.
//
// This used to be a bottom sheet of a fixed 75% height, padded up by the
// keyboard. With the keyboard open that is more than the screen holds: the
// card's own header slid up under the status bar, the composer underneath
// showed through the not-quite-opaque fill, and the one button that closes
// the thing sat at the bottom of a card that had been pushed past the top
// edge. A route has none of those problems — the keyboard takes the bottom
// half, the text takes the rest, and the action lives in the app bar where
// the keyboard can never reach it.

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/icons/icon_map.dart';

/// Opens the message being written on a screen of its own.
///
/// Returns the edited text. Every way out of the screen — the app bar
/// button, the close icon, the system back gesture — carries the text back,
/// because there is nothing here to cancel: this is the same message that
/// is already in the composer.
Future<String?> showFullscreenComposer(
  BuildContext context, {
  required String initialText,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => _FullscreenComposerPage(initialText: initialText),
    ),
  );
}

class _FullscreenComposerPage extends StatefulWidget {
  const _FullscreenComposerPage({required this.initialText});

  final String initialText;

  @override
  State<_FullscreenComposerPage> createState() =>
      _FullscreenComposerPageState();
}

class _FullscreenComposerPageState extends State<_FullscreenComposerPage> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _focusNode = FocusNode();
    // Focus after the route settles so the keyboard animation does not race
    // the push transition.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _close() => Navigator.of(context).pop(_controller.text);

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    return PopScope<Object?>(
      // Back never throws the edits away — it closes the screen the same way
      // the button does.
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _close();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const AppIcon(Icons.close_fullscreen_rounded),
            tooltip: 'Back to the chat',
            onPressed: _close,
          ),
          title: const Text('Compose'),
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: FilledButton(
                onPressed: _close,
                style: FilledButton.styleFrom(
                  shape: const StadiumBorder(),
                  visualDensity: VisualDensity.compact,
                ),
                child: const Text('Done'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: ExpressiveCard(
              padding: const EdgeInsets.fromLTRB(18, 16, 18, 16),
              child: TextField(
                controller: _controller,
                focusNode: _focusNode,
                // expands + maxLines null is what makes the field own the
                // card instead of growing line by line.
                maxLines: null,
                expands: true,
                keyboardType: TextInputType.multiline,
                textCapitalization: TextCapitalization.sentences,
                textAlignVertical: TextAlignVertical.top,
                style: TextStyle(
                  color: cs.onSurface,
                  fontSize: 15,
                  height: 1.4,
                ),
                decoration: InputDecoration(
                  hintText: 'Type your message here...',
                  hintStyle: TextStyle(
                    color: m3.onSurfaceVariant,
                    fontSize: 15,
                  ),
                  filled: false,
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: EdgeInsets.zero,
                ),
                cursorColor: cs.primary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
