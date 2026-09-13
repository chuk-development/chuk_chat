/// The chat composer's shell: one rounded box, two rows.
///
/// Row one is what you are saying, row two what you can do about it. Every
/// number here — the 26 corner, the two-pixel hairline at a quarter alpha, the
/// 8 of padding, the flat neutral shadow — is the mobile chat composer's, so a
/// second screen that needs a composer stops inventing a third look. The box
/// owns the chrome and nothing else: the field, the notices above it and the
/// targets below it are all handed in, because those differ per screen while
/// the shape must not.
///
/// The one-to-one chat still draws this shape inline in
/// `platform_specific/chat/chat_ui_mobile.dart`; that call site should move
/// onto this widget so there is one copy of the numbers (bead cowork-4ciz).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/utils/theme_extensions.dart';

class ChatComposerBox extends StatelessWidget {
  const ChatComposerBox({
    super.key,
    required this.field,
    required this.actions,
    this.notices = const <Widget>[],
    this.borderColor,
  });

  /// Row one: the text field, already wrapped in whatever key handling the
  /// screen needs.
  final Widget field;

  /// Row two: the action targets, laid out left to right. A [Spacer] before
  /// the send target is the caller's job — the same as in the chat.
  final List<Widget> actions;

  /// Anything that has to sit above the field: a reply preview, an edit
  /// notice, a queue line. Drawn in order, stretched to the box.
  final List<Widget> notices;

  /// Overrides the hairline, for a state that has to be said in colour (the
  /// chat turns it red while recording). Null is the resting hairline.
  final Color? borderColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    return Container(
      decoration: BoxDecoration(
        color: theme.scaffoldBackgroundColor.withValues(alpha: 0.98),
        borderRadius: BorderRadius.circular(26),
        border: Border.all(
          color: borderColor ?? iconFg.withValues(alpha: 0.25),
          width: 2,
        ),
        // Neutral and small, never a coloured glow (docs/DESIGN.md §8).
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.06),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      padding: const EdgeInsets.all(8),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          ...notices,
          field,
          const SizedBox(height: 4),
          Row(crossAxisAlignment: CrossAxisAlignment.center, children: actions),
        ],
      ),
    );
  }
}

/// The composer's text field, with the chat's typography and its borderless
/// decoration. The caller owns the controller, the focus node and what the
/// action key does; everything the reader sees is here.
class ChatComposerField extends StatelessWidget {
  const ChatComposerField({
    super.key,
    required this.controller,
    required this.hintText,
    this.focusNode,
    this.enabled = true,
    this.minLines = 1,
    this.maxLines = 8,
    this.onSubmitted,
    this.semanticsIdentifier = 'message_input',
  });

  final TextEditingController controller;
  final String hintText;
  final FocusNode? focusNode;
  final bool enabled;
  final int minLines;
  final int maxLines;
  final VoidCallback? onSubmitted;
  final String semanticsIdentifier;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ScrollConfiguration(
      // A scrollbar inside a four-line field reads as clutter.
      behavior: ScrollConfiguration.of(context).copyWith(scrollbars: false),
      child: Semantics(
        identifier: semanticsIdentifier,
        child: TextField(
          controller: controller,
          focusNode: focusNode,
          enabled: enabled,
          autofocus: false,
          keyboardType: TextInputType.multiline,
          textInputAction: TextInputAction.newline,
          style: TextStyle(color: scheme.onSurface, fontSize: 15, height: 1.35),
          minLines: minLines,
          maxLines: maxLines,
          decoration: InputDecoration(
            hintText: hintText,
            hintStyle: TextStyle(
              color: scheme.onSurface.withValues(alpha: 0.5),
              fontSize: 15,
            ),
            filled: false,
            border: InputBorder.none,
            enabledBorder: InputBorder.none,
            focusedBorder: InputBorder.none,
            disabledBorder: InputBorder.none,
            contentPadding: const EdgeInsets.only(
              left: 8,
              top: 6,
              bottom: 6,
              right: 6,
            ),
            isDense: true,
          ),
          cursorColor: scheme.primary,
          cursorWidth: 1.5,
          onSubmitted: onSubmitted == null ? null : (_) => onSubmitted!(),
        ),
      ),
    );
  }
}
