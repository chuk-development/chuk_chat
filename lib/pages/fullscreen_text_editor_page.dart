// lib/pages/fullscreen_text_editor_page.dart
//
// A whole screen for one text field.
//
// The identity fields (Soul, User, Memory, raw system prompt) hold
// paragraphs, and a box a few lines tall inside a scrolling settings page
// is the wrong instrument for writing them: the page scrolls under your
// thumb while you aim at a word, and you can never see what you wrote.
// This is a real route, not a sheet — the keyboard gets the bottom half and
// the text gets everything else.

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

/// Opens [initialText] in a fullscreen editor.
///
/// Returns the edited text, or null if the reader backed out without
/// saving.
Future<String?> showFullscreenTextEditor(
  BuildContext context, {
  required String initialText,
  required String title,
  String hintText = '',
  bool monospace = false,
}) {
  return Navigator.of(context).push<String>(
    MaterialPageRoute<String>(
      fullscreenDialog: true,
      builder: (_) => FullscreenTextEditorPage(
        initialText: initialText,
        title: title,
        hintText: hintText,
        monospace: monospace,
      ),
    ),
  );
}

class FullscreenTextEditorPage extends StatefulWidget {
  const FullscreenTextEditorPage({
    super.key,
    required this.initialText,
    required this.title,
    this.hintText = '',
    this.monospace = false,
  });

  final String initialText;
  final String title;
  final String hintText;
  final bool monospace;

  @override
  State<FullscreenTextEditorPage> createState() =>
      _FullscreenTextEditorPageState();
}

class _FullscreenTextEditorPageState extends State<FullscreenTextEditorPage> {
  late final TextEditingController _controller;
  late final FocusNode _focusNode;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialText);
    _controller.addListener(_onChanged);
    _focusNode = FocusNode();
    // Focus after the route settles so the keyboard animation does not
    // race the push transition.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onChanged);
    _controller.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onChanged() {
    // Only the character count and the Save state depend on the text, and
    // both live in this widget — no parent rebuild per keystroke.
    setState(() {});
  }

  bool get _isDirty => _controller.text != widget.initialText;

  Future<void> _confirmDiscard() async {
    if (!_isDirty) {
      Navigator.of(context).pop();
      return;
    }
    final bool? discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Discard changes?'),
        content: const Text('The edits on this screen will be lost.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (discard == true && mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final m3 = theme.m3;

    return PopScope<Object?>(
      canPop: !_isDirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
        backgroundColor: cs.surface,
        appBar: AppBar(
          backgroundColor: cs.surface,
          elevation: 0,
          scrolledUnderElevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.close),
            tooltip: 'Cancel',
            onPressed: _confirmDiscard,
          ),
          title: Text(widget.title),
          centerTitle: false,
          actions: [
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: TextButton(
                onPressed: _isDirty
                    ? () => Navigator.of(context).pop(_controller.text)
                    : null,
                child: const Text('Save'),
              ),
            ),
          ],
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Expanded(
                  child: TextField(
                    controller: _controller,
                    focusNode: _focusNode,
                    // expands + maxLines null is what makes the field own
                    // the screen instead of growing line by line.
                    maxLines: null,
                    expands: true,
                    keyboardType: TextInputType.multiline,
                    textCapitalization: TextCapitalization.sentences,
                    textAlignVertical: TextAlignVertical.top,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: cs.onSurface,
                      height: 1.5,
                      fontFamily: widget.monospace ? 'monospace' : null,
                    ),
                    decoration: InputDecoration(
                      hintText: widget.hintText,
                      filled: false,
                      border: InputBorder.none,
                      enabledBorder: InputBorder.none,
                      focusedBorder: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Text(
                    '${_controller.text.length} characters',
                    textAlign: TextAlign.end,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: m3.onSurfaceVariant,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
