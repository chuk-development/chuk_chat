/// The floating top bar of a phone chat, after Grok Bot.
///
/// Grok Bot's chat has no app bar. Three things float over the messages on a
/// soft fade: a round back chip, a pill with the bot's face, presence dot and
/// name (tap: the bot's profile), and a round "computer" chip that opens the
/// bot's screen. CoWork has the same three things — the coworker, its
/// browser (`browser_view_page`) and its controls — plus the shell actions
/// that used to sit in the app bar, which fold into one "more" chip.
///
/// The bar draws nothing behind the status bar and reads only `paddingOf`, so
/// it never rebuilds on a keyboard frame. The chat body under it must reserve
/// [MobileLayout.chromeInset] at the top; [MobileChatScreen] does that.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/platform_specific/mobile/mobile_chips.dart';
import 'package:cowork/platform_specific/mobile/mobile_layout.dart';
import 'package:cowork/platform_specific/mobile/mobile_presence_avatar.dart';

class MobileChatChrome extends StatelessWidget {
  const MobileChatChrome({
    super.key,
    required this.agent,
    required this.onBack,
    this.onOpenProfile,
    this.onOpenBrowser,
    this.onMore,
  });

  final CoworkAgent agent;

  /// Back to the coworker list.
  final VoidCallback onBack;

  /// Tap on the bot pill. Null renders the pill flat (no ripple).
  final VoidCallback? onOpenProfile;

  /// The "computer" chip: the coworker's browser. Null hides the chip.
  final VoidCallback? onOpenBrowser;

  /// The "more" chip: the shell's secondary actions. Null hides the chip.
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final Color fg = theme.colorScheme.onSurface;
    return MobileBarFade(
      child: SafeArea(
        bottom: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
          child: SizedBox(
            height: MobileLayout.chipDiameter,
            child: Row(
              children: [
                MobileRoundChip(
                  icon: Icons.arrow_back_ios_new_rounded,
                  onTap: onBack,
                  tooltip: 'Agents',
                  semanticsId: 'mobile_chat_back',
                ),
                const SizedBox(width: 8),
                // Expanded + left alignment: a long name ellipsises inside the
                // pill instead of pushing the chips off the right edge, and a
                // short name hugs the back chip like Grok Bot's pill does.
                Expanded(
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: _BotPill(agent: agent, onTap: onOpenProfile, fg: fg),
                  ),
                ),
                if (onOpenBrowser != null) ...[
                  const SizedBox(width: 8),
                  MobileRoundChip(
                    icon: Icons.desktop_windows_outlined,
                    onTap: onOpenBrowser,
                    tooltip: "Agent's browser",
                    semanticsId: 'mobile_chat_browser',
                  ),
                ],
                if (onMore != null) ...[
                  const SizedBox(width: 8),
                  MobileRoundChip(
                    icon: Icons.more_horiz_rounded,
                    onTap: onMore,
                    tooltip: 'More',
                    semanticsId: 'mobile_chat_more',
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The bot pill: face, presence dot, name. As tall as a chip so it is one
/// touch target.
class _BotPill extends StatelessWidget {
  const _BotPill({required this.agent, required this.onTap, required this.fg});

  final CoworkAgent agent;
  final VoidCallback? onTap;
  final Color fg;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final String? role = agent.role?.trim();
    return Semantics(
      identifier: 'mobile_chat_bot_pill',
      button: onTap != null,
      label: agent.name,
      child: Tooltip(
        message: role == null || role.isEmpty
            ? agent.name
            : '${agent.name} · $role',
        child: DecoratedBox(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(MobileLayout.chipDiameter / 2),
            boxShadow: mobileChipShadow(theme),
          ),
          child: Material(
            color: theme.colorScheme.surface,
            borderRadius: BorderRadius.circular(MobileLayout.chipDiameter / 2),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 6, 14, 6),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    MobilePresenceAvatar(agent: agent, radius: 18),
                    const SizedBox(width: 8),
                    Flexible(
                      child: Text(
                        agent.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: fg.withValues(alpha: 0.92),
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
