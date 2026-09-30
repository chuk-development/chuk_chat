// lib/platform_specific/chat/voice/chat_voice_call_button.dart
//
// The call target of a chat: a call glyph while no call runs for the chat,
// the hang-up glyph while one does. It reaches the chat screen that owns the
// chat through its [ChatVoiceBinding], so a header drawn outside the screen
// (the Agents thread header, the phone chat chrome) needs no plumbing.
//
// Build it only when `voiceCallUiEnabled` is true.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/voice/voice_call.dart';
import 'package:chuk_chat/voice/widgets/voice_call_controls.dart'
    show VoiceHangUpGlyph;
import 'package:chuk_chat/widgets/app_notification.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';

/// Which surface the target sits on.
enum ChatVoiceCallStyle {
  /// A bare round icon target: the desktop chat header and the Agents thread
  /// header (a 20 px glyph on round ink, no fill).
  bar,

  /// A round floating chip: the phone chat chrome (42 px chip, 48 px press).
  chip,

  /// A composer target next to the microphone: 38 px round ink, the glyph
  /// at the composer's quiet alpha, a tinted fill while on (the phone
  /// composer's `buildTinyIconButton`).
  composer,
}

class ChatVoiceCallButton extends StatelessWidget {
  /// The target of [binding]'s screen.
  const ChatVoiceCallButton({
    super.key,
    required ChatVoiceBinding this.binding,
    this.style = ChatVoiceCallStyle.bar,
    this.size = 40,
    this.agentName,
    this.semanticsId = 'voice-call-button',
  }) : agentsThread = false;

  /// The target of the Agents thread screen, found through
  /// [ChatVoiceSessions].
  const ChatVoiceCallButton.agentsThread({
    super.key,
    this.style = ChatVoiceCallStyle.bar,
    this.size = 40,
    this.agentName,
    this.semanticsId = 'voice-call-button',
  }) : binding = null,
       agentsThread = true;

  final ChatVoiceBinding? binding;
  final bool agentsThread;
  final ChatVoiceCallStyle style;

  /// The square hit box of the bar style.
  final double size;

  /// The coworker's name, for the worker's greeting.
  final String? agentName;
  final String semanticsId;

  @override
  Widget build(BuildContext context) {
    final VoiceCallController controller = VoiceCallController.instance;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        controller,
        ChatVoiceSessions.instance,
      ]),
      builder: (BuildContext context, Widget? _) {
        final ChatVoiceBinding? b =
            binding ?? ChatVoiceSessions.instance.forRole(agents: true);
        final String? chatId = b?.currentChatId();
        final bool ready = b != null && chatId != null && chatId.isNotEmpty;
        final bool live = ready && b.isLiveFor(chatId);
        final String tooltip = !ready
            ? 'Voice call (send a message first)'
            : (live ? 'Hang up' : 'Voice call');
        void onTap() {
          if (!ready) {
            AppNotifications.show(
              context,
              'Send a message first, then call',
              duration: const Duration(seconds: 2),
            );
            return;
          }
          unawaited(b.toggleCall(agentName: agentName));
        }

        return switch (style) {
          ChatVoiceCallStyle.bar => _bar(context, live, ready, tooltip, onTap),
          ChatVoiceCallStyle.chip => _chip(
            context,
            live,
            ready,
            tooltip,
            onTap,
          ),
          ChatVoiceCallStyle.composer => _composer(
            context,
            live,
            ready,
            tooltip,
            onTap,
          ),
        };
      },
    );
  }

  Widget _bar(
    BuildContext context,
    bool live,
    bool ready,
    String tooltip,
    VoidCallback onTap,
  ) {
    if (!live) {
      return Opacity(
        opacity: ready ? 1 : 0.45,
        child: VoiceCallButton(
          key: ValueKey<String>('$semanticsId-idle'),
          onPressed: onTap,
          size: size,
          tooltip: tooltip,
        ),
      );
    }
    final Color glyph = Theme.of(context).colorScheme.error;
    return Semantics(
      identifier: semanticsId,
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          key: ValueKey<String>('$semanticsId-live'),
          type: MaterialType.transparency,
          shape: const CircleBorder(),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            customBorder: const CircleBorder(),
            onTap: onTap,
            child: SizedBox.square(
              dimension: size,
              child: Center(child: VoiceHangUpGlyph(color: glyph)),
            ),
          ),
        ),
      ),
    );
  }

  Widget _composer(
    BuildContext context,
    bool live,
    bool ready,
    String tooltip,
    VoidCallback onTap,
  ) {
    final ThemeData theme = Theme.of(context);
    final Color base = live
        ? theme.colorScheme.error
        : theme.resolvedIconColor.withValues(alpha: ready ? 0.6 : 0.3);
    return Semantics(
      identifier: semanticsId,
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(size / 2),
            child: Container(
              width: size,
              height: size,
              decoration: BoxDecoration(
                color: live
                    ? theme.colorScheme.error.withValues(alpha: 0.15)
                    : Colors.transparent,
                shape: BoxShape.circle,
              ),
              child: Center(
                child: live
                    ? VoiceHangUpGlyph(color: base)
                    : HugeIcon(HugeIcons.call02, size: 20, color: base),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The phone chrome's chip: 42 px painted, 48 px pressed. Idle it is the
  /// chrome surface with the call glyph; live it is a flat error fill with
  /// the hang-up glyph (no shadow, no glow).
  Widget _chip(
    BuildContext context,
    bool live,
    bool ready,
    String tooltip,
    VoidCallback onTap,
  ) {
    const double chip = 42;
    const double press = 48;
    final ThemeData theme = Theme.of(context);
    final Color fill = live
        ? theme.colorScheme.error
        : FloatingChromeSurface.fillOf(context);
    final Color glyph = live
        ? theme.colorScheme.onError
        : theme.resolvedIconColor.withValues(alpha: ready ? 1 : 0.45);
    return Semantics(
      identifier: semanticsId,
      button: true,
      label: tooltip,
      child: Tooltip(
        message: tooltip,
        excludeFromSemantics: true,
        child: Material(
          type: MaterialType.transparency,
          child: InkResponse(
            onTap: onTap,
            containedInkWell: false,
            highlightShape: BoxShape.circle,
            radius: chip / 2,
            child: SizedBox.square(
              dimension: press,
              child: Center(
                child: Ink(
                  width: chip,
                  height: chip,
                  decoration: BoxDecoration(color: fill, shape: BoxShape.circle),
                  child: Center(
                    child: live
                        ? VoiceHangUpGlyph(color: glyph, size: 22)
                        : HugeIcon(HugeIcons.call02, size: 22, color: glyph),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
