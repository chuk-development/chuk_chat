// lib/voice/widgets/voice_call_button.dart
//
// The call target in a chat header. Same look as the header's other icon
// targets (`ChromeIconButton` in agents_thread_header.dart): a 20 px glyph in
// the icon colour on round ink, a tooltip, no fill. Draws the HugeIcon
// directly (docs/DESIGN.md §5: new code names the HugeIcon).
//
// Show it only when `VoiceCallService.isAvailable`.

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

class VoiceCallButton extends StatelessWidget {
  const VoiceCallButton({
    super.key,
    required this.onPressed,
    this.size = 40,
    this.tooltip = 'Voice call',
    this.active = false,
  });

  final VoidCallback onPressed;

  /// The square hit box. 40 matches the chat header slot.
  final double size;
  final String tooltip;

  /// A call is running in this chat: the glyph takes the accent.
  final bool active;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color glyph = active
        ? theme.colorScheme.primary
        : theme.resolvedIconColor;
    return Semantics(
      identifier: 'voice-call-button',
      button: true,
      toggled: active ? true : null,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onPressed,
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: HugeIcon(HugeIcons.call02, size: 20, color: glyph),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
