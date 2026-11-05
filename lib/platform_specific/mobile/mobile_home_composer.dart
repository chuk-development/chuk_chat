/// The composer at the bottom of Home on a phone.
///
/// The owner's rule for the phone: the composer is always at the bottom, on
/// every page of the Agents half. In a thread that is chuk's own composer.
/// Home has no thread, so it gets this bar: the chat composer's box (the 26
/// corner, the 2 px hairline, the flat neutral shadow — `chat_composer_box`)
/// with the chat's field and send target in one row. Text sent here goes to
/// the main agent: the shell opens that agent's thread and sends it there.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/chat/widgets/composer_send_button.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/chat_composer_box.dart';

/// Height of the bar with one line of text, without the outer margin.
const double kMobileHomeComposerHeight = 8 + 48 + 8;

/// Room the bar takes at the bottom of Home, margins included: what the
/// dashboard keeps free under its last card.
const double kMobileHomeComposerSpace = kMobileHomeComposerHeight + 12 + 12;

class MobileHomeComposer extends StatefulWidget {
  const MobileHomeComposer({
    super.key,
    required this.hintText,
    required this.onSend,
  });

  /// "Ask <main agent>…".
  final String hintText;

  /// Gets the trimmed text. The bar clears itself after the call.
  final ValueChanged<String> onSend;

  @override
  State<MobileHomeComposer> createState() => _MobileHomeComposerState();
}

class _MobileHomeComposerState extends State<MobileHomeComposer> {
  final TextEditingController _text = TextEditingController();
  final FocusNode _focus = FocusNode(debugLabel: 'home-composer');

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _send() {
    final String text = _text.text.trim();
    if (text.isEmpty) return;
    _text.clear();
    _focus.unfocus();
    widget.onSend(text);
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color iconFg = theme.resolvedIconColor;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      child: Container(
        key: const ValueKey<String>('home-composer'),
        // The chat composer's box, number for number (ChatComposerBox).
        decoration: BoxDecoration(
          color: theme.scaffoldBackgroundColor.withValues(alpha: 0.98),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(color: iconFg.withValues(alpha: 0.25), width: 2),
          // Neutral and small, never a coloured glow (docs/DESIGN.md §8).
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.06),
              blurRadius: 10,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        padding: const EdgeInsets.all(6),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            Expanded(
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 48),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ChatComposerField(
                    controller: _text,
                    focusNode: _focus,
                    hintText: widget.hintText,
                    maxLines: 4,
                    onSubmitted: _send,
                    semanticsIdentifier: 'home_composer_input',
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            ComposerSendButton(
              controller: _text,
              onSend: _send,
              width: 48,
              height: 48,
              radius: 24,
              sendIcon: Icons.arrow_upward_rounded,
              iconSize: 24,
              semanticsId: 'home_composer_send',
            ),
          ],
        ),
      ),
    );
  }
}
