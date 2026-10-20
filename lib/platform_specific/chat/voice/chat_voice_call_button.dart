// lib/platform_specific/chat/voice/chat_voice_call_button.dart
//
// The voice target of a chat: VoiceIcon in the header and the chip. It
// reaches the chat screen that owns the chat through its [ChatVoiceBinding],
// so a header drawn outside the screen needs no plumbing.
//
// The composer has no voice target of its own: its send target turns into
// voice while the field is empty ([composerVoiceAction],
// `ComposerSendButton`).
//
// Build it only when `voiceCallUiEnabled` is true.

import 'dart:async';

import 'package:flutter/material.dart';

import 'package:chuk_chat/platform_specific/chat/voice/chat_voice_binding.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/voice/voice_call.dart';
import 'package:chuk_chat/widgets/floating_chrome_surface.dart';

/// Which surface the target sits on.
enum ChatVoiceCallStyle {
  /// A bare round icon target: the desktop chat header and the Agents thread
  /// header (a 20 px glyph on round ink, no fill).
  bar,

  /// A round floating chip: the phone chat chrome (42 px chip, 48 px press).
  chip,
}

/// Whether [binding] can start a call: a binding exists (the build offers
/// calls) and the chat has an id, or the binding can make one.
bool chatVoiceReady(ChatVoiceBinding? binding) {
  if (binding == null) return false;
  final String? chatId = binding.currentChatId();
  return (chatId != null && chatId.isNotEmpty) || binding.ensureChatId != null;
}

/// Starts the call of [binding] (unless one is live for its chat) and opens
/// the call page. The one tap behaviour of every voice target.
void openChatVoiceCall(
  BuildContext context,
  ChatVoiceBinding binding, {
  String? agentName,
}) {
  final bool live = binding.isLiveFor(binding.currentChatId());
  if (!live) unawaited(binding.startCall(agentName: agentName));
  unawaited(
    VoiceCallFullscreenPage.show(
      context,
      controller: VoiceCallController.instance,
    ),
  );
}

/// The composer's voice action for [binding]. Null when the build or the
/// chat cannot call ([chatVoiceReady]): the composer target stays send.
VoidCallback? composerVoiceAction(
  BuildContext context,
  ChatVoiceBinding? binding, {
  String? agentName,
}) {
  if (binding == null || !chatVoiceReady(binding)) return null;
  return () => openChatVoiceCall(context, binding, agentName: agentName);
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

  /// The agent's name, for the worker's greeting.
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
        // A new chat with no id yet can call too, when the binding can give
        // it one.
        final bool ready = chatVoiceReady(b);
        final bool live = ready && b!.isLiveFor(b.currentChatId());
        final String tooltip = live ? 'Open voice call' : 'Voice call';
        void onTap() {
          if (b == null) return;
          openChatVoiceCall(context, b, agentName: agentName);
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
    final Color glyph = Theme.of(context).colorScheme.primary;
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
              child: Center(child: HugeIcon(HugeIcons.voice, color: glyph)),
            ),
          ),
        ),
      ),
    );
  }

  /// The phone chrome's chip: 42 px painted, 48 px pressed. Idle it is the
  /// chrome surface with the call glyph; live it uses the active accent.
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
        ? theme.colorScheme.primary
        : FloatingChromeSurface.fillOf(context);
    final Color glyph = live
        ? theme.colorScheme.onPrimary
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
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                  ),
                  child: Center(
                    child: HugeIcon(HugeIcons.voice, size: 22, color: glyph),
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
