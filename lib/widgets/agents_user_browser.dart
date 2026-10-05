// lib/widgets/agents_user_browser.dart
//
// The user's own browser in the app (docs/WIRE_CONTRACT.md, "The user's own
// browser", app work list 1-6): the subtitle of the "Your browser" switch,
// the setup card, and the one-line notice at the end of a thread (which
// browser the run uses, "<Name> is using your browser", Stop).
//
// The host is the truth. Everything here reads the status the host sent
// (`agent_permissions.user_browser` or the `user_browser_status` push) and
// `run_state.browser_target`. Nothing is disabled on the app's side.
//
// There is no "Allow again" button here: the app has no frame that lifts a
// Stop. The user lifts it in the add-on, or by sending a new task.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';

/// The one command from the runbook (docs/RUNBOOK_2026-09-08_USER_BROWSER.md,
/// steps 1 and 2): build the add-on and register the bridge with the
/// browsers. No host address, no port.
const String kUserBrowserSetupCommand =
    'cd ~/git/chuk_chat/extension && ./build.sh chrome && '
    '../tools/agents-browser-bridge/install_host_manifest.py';

AppLocalizations _l(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

/// The subtitle of the "Your browser" switch, from the host's status.
/// [fallback] (the switch's own explanation) when the host sent none.
String userBrowserSubtitle(
  AppLocalizations l,
  UserBrowserStatus? status, {
  required String agentId,
  required bool heldByOther,
  required String fallback,
}) {
  final UserBrowserStatus? s = status;
  if (s == null) return fallback;
  if (!s.hostListening) return l.ubSubtitleNoBroker;
  if (s.stopped) return l.ubSubtitleStopped;
  if (!s.installed) return l.ubSubtitleNotSetUp;
  if (!s.connected) return l.ubSubtitleNotConnected;
  if (heldByOther) return l.ubInUseBy(s.inUseByName ?? l.ubAnotherCoworker);
  final String? browser = s.browser == null
      ? null
      : userBrowserDisplayName(s.browser!);
  final bool heldHere =
      s.inUse && (s.inUseByAgentId == agentId || s.inUseByThisAgent == true);
  if (heldHere && browser != null) return l.ubSubtitleInUseHere(browser);
  return browser == null
      ? l.ubSubtitlePairedGeneric
      : l.ubSubtitlePaired(browser);
}

/// What the thread's notice says.
enum UserBrowserNoticeKind {
  /// The user pressed Stop in the browser.
  stopped,

  /// Another coworker holds the user's browser.
  inUseByOther,

  /// The bridge is not registered with any browser.
  notSetUp,

  /// Registered, but no add-on is connected.
  notConnected,

  /// Nothing wrong: only which browser the run uses.
  label,
}

/// One notice at the end of a thread.
@immutable
class UserBrowserNotice {
  const UserBrowserNotice(
    this.kind, {
    this.name,
    this.browser,
    this.sandbox = false,
  });

  final UserBrowserNoticeKind kind;

  /// [UserBrowserNoticeKind.inUseByOther]: who holds it, when the host said.
  final String? name;

  /// [UserBrowserNoticeKind.label]: the connected browser's id, when known.
  final String? browser;

  /// [UserBrowserNoticeKind.label]: the run uses the sandbox browser.
  final bool sandbox;

  @override
  bool operator ==(Object other) =>
      other is UserBrowserNotice &&
      other.kind == kind &&
      other.name == name &&
      other.browser == browser &&
      other.sandbox == sandbox;

  @override
  int get hashCode => Object.hash(kind, name, browser, sandbox);

  @override
  String toString() => 'UserBrowserNotice($kind, $name, $browser, $sandbox)';
}

/// What the end of a thread says about the user's browser, or null for
/// nothing.
///
/// Only a coworker that has to do with the user's browser gets a notice:
/// its run says `browser_target: user_browser`, or its "Your browser" switch
/// is on. A problem (Stop, another holder, no add-on) shows whether or not a
/// run is going. The plain label ("Your browser" / "Sandbox browser") shows
/// only while a run is going: the sandbox label is there for a switch that
/// was turned on in the middle of a task (it applies from the next one).
UserBrowserNotice? userBrowserNoticeFor({
  required UserBrowserStatus? status,
  required bool heldByOther,
  required String? browserTarget,
  required bool? permissionOn,
  required bool running,
}) {
  final bool targetUser = browserTarget == kBrowserTargetUserBrowser;
  if (!targetUser && permissionOn != true) return null;
  final bool usesUser = browserTarget == null
      ? permissionOn == true
      : targetUser;
  final UserBrowserStatus? s = status;
  if (usesUser && s != null) {
    if (s.stopped) {
      return const UserBrowserNotice(UserBrowserNoticeKind.stopped);
    }
    if (heldByOther) {
      return UserBrowserNotice(
        UserBrowserNoticeKind.inUseByOther,
        name: s.inUseByName,
      );
    }
    if (s.hostListening && !s.installed) {
      return const UserBrowserNotice(UserBrowserNoticeKind.notSetUp);
    }
    if (s.hostListening && !s.connected) {
      return const UserBrowserNotice(UserBrowserNoticeKind.notConnected);
    }
  }
  if (!running) return null;
  return UserBrowserNotice(
    UserBrowserNoticeKind.label,
    sandbox: !usesUser,
    browser: usesUser ? s?.browser : null,
  );
}

/// The notice at the end of a thread. A plain pill for the label; a card for
/// a problem, with "How to set up" when the add-on is missing.
class AgentsUserBrowserNoticeView extends StatelessWidget {
  const AgentsUserBrowserNoticeView({
    super.key,
    required this.notice,
    this.onSetUp,
    this.dense = false,
  });

  final UserBrowserNotice notice;

  /// "How to set up": opens the setup card. Null hides the button.
  final VoidCallback? onSetUp;

  /// Desktop size (docs/DESIGN.md §14.8).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = _l(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    if (notice.kind == UserBrowserNoticeKind.label) {
      final String text = notice.sandbox
          ? l.ubLabelSandbox
          : notice.browser == null
          ? l.ubLabelUserBrowser
          : l.ubLabelUserBrowserNamed(userBrowserDisplayName(notice.browser!));
      return Align(
        alignment: Alignment.centerLeft,
        child: Container(
          key: const ValueKey<String>('agents-user-browser-label'),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: theme.m3.surfaceContainerHigh,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              HugeIcon(
                notice.sandbox ? HugeIcons.computer : HugeIcons.globe02,
                size: 15,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  text,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: scheme.onSurfaceVariant,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }
    final (HugeIconData icon, String text) = switch (notice.kind) {
      UserBrowserNoticeKind.stopped => (
        HugeIcons.stopCircle,
        l.ubNoticeStopped,
      ),
      UserBrowserNoticeKind.inUseByOther => (
        HugeIcons.userGroup,
        l.ubInUseBy(notice.name ?? l.ubAnotherCoworker),
      ),
      UserBrowserNoticeKind.notSetUp => (HugeIcons.globe02, l.ubNoticeNotSetUp),
      _ => (HugeIcons.unlink01, l.ubSetupTitleNotConnected),
    };
    final bool setup =
        notice.kind == UserBrowserNoticeKind.notSetUp ||
        notice.kind == UserBrowserNoticeKind.notConnected;
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        key: ValueKey<String>('agents-user-browser-${notice.kind.name}'),
        decoration: BoxDecoration(
          color: scheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(18),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Container(
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: scheme.secondaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: HugeIcon(
                    icon,
                    size: 20,
                    color: scheme.onSecondaryContainer,
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(
                      text,
                      style: theme.textTheme.bodyMedium?.copyWith(
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            if (setup && onSetUp != null) ...<Widget>[
              const SizedBox(height: 10),
              Padding(
                padding: const EdgeInsets.only(left: 48),
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: ExpressiveButton(
                    key: const ValueKey<String>(
                      'agents-user-browser-setup-open',
                    ),
                    label: l.ubSetupHowTo,
                    tonal: true,
                    dense: dense,
                    onTap: onSetUp!,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// The setup card: three plain steps, the one command with a copy button,
/// and "Check again", which asks the host for the status again.
class AgentsUserBrowserSetupCard extends StatelessWidget {
  const AgentsUserBrowserSetupCard({
    super.key,
    required this.status,
    required this.onCheckAgain,
    this.dense = false,
  });

  /// The host's status. Only [UserBrowserStatus.installed] changes the words.
  final UserBrowserStatus status;

  final VoidCallback onCheckAgain;

  /// Desktop size (docs/DESIGN.md §14.8).
  final bool dense;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = _l(context);
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    final bool installed = status.installed;
    final TextStyle? body = theme.textTheme.bodySmall?.copyWith(
      color: scheme.onSurfaceVariant,
      height: 1.4,
    );
    return Container(
      key: const ValueKey<String>('agents-user-browser-setup'),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(18),
      ),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            installed ? l.ubSetupTitleNotConnected : l.ubSetupTitleNotSetUp,
            key: const ValueKey<String>('agents-user-browser-setup-title'),
            style: theme.textTheme.titleSmall?.copyWith(
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            installed ? l.ubSetupIntroNotConnected : l.ubSetupIntro,
            style: body,
          ),
          const SizedBox(height: 12),
          _Step(number: 1, text: l.ubSetupStep1),
          Padding(
            padding: const EdgeInsets.only(left: 32, top: 6, bottom: 10),
            child: _CommandBox(
              command: kUserBrowserSetupCommand,
              copyLabel: l.ubSetupCopy,
              copiedLabel: l.ubSetupCopied,
            ),
          ),
          _Step(number: 2, text: l.ubSetupStep2),
          const SizedBox(height: 8),
          _Step(number: 3, text: l.ubSetupStep3),
          const SizedBox(height: 12),
          FittedBox(
            fit: BoxFit.scaleDown,
            alignment: Alignment.centerLeft,
            child: ExpressiveButton(
              key: const ValueKey<String>('agents-user-browser-check'),
              icon: Icons.refresh,
              label: l.ubSetupCheckAgain,
              tonal: true,
              dense: dense,
              onTap: onCheckAgain,
            ),
          ),
        ],
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({required this.number, required this.text});

  final int number;
  final String text;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Container(
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: scheme.secondaryContainer,
            shape: BoxShape.circle,
          ),
          child: Text(
            '$number',
            textScaler: TextScaler.noScaling,
            style: theme.textTheme.labelSmall?.copyWith(
              color: scheme.onSecondaryContainer,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(
                color: scheme.onSurface,
                height: 1.4,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// The command in a monospace block that wraps, with a copy button.
class _CommandBox extends StatelessWidget {
  const _CommandBox({
    required this.command,
    required this.copyLabel,
    required this.copiedLabel,
  });

  final String command;
  final String copyLabel;
  final String copiedLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme scheme = theme.colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 4, 6),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: SelectableText(
              command,
              key: const ValueKey<String>('agents-user-browser-command'),
              style: theme.textTheme.bodySmall?.copyWith(
                fontFamily: 'monospace',
                fontFamilyFallback: const <String>['Courier'],
                color: scheme.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 4),
          ExpressiveIconButton(
            key: const ValueKey<String>('agents-user-browser-copy'),
            hugeIcon: HugeIcons.copy01,
            size: 40,
            tooltip: copyLabel,
            semanticsId: 'agents_user_browser_copy',
            onTap: () {
              unawaited(Clipboard.setData(ClipboardData(text: command)));
              pillToast(context, copiedLabel);
            },
          ),
        ],
      ),
    );
  }
}

/// Opens the setup card in a sheet, for the thread's "How to set up". It
/// follows the service, so a push that says "connected" closes nothing but
/// shows the new words; "Check again" sends `agent_permissions_get`.
Future<void> showUserBrowserSetupSheet(
  BuildContext context, {
  required String agentId,
  AgentsPermissionsService? service,
}) {
  final AgentsPermissionsService s =
      service ?? AgentsPermissionsService.instance;
  final AppLocalizations l = _l(context);
  return expressiveSheet<void>(
    context,
    title: l.ubLabelUserBrowser,
    child: ListenableBuilder(
      listenable: s,
      builder: (BuildContext context, _) {
        final UserBrowserStatus status =
            s.userBrowserStatus ?? const UserBrowserStatus(hostListening: true);
        return AgentsUserBrowserSetupCard(
          status: status,
          onCheckAgain: () async {
            final bool sent = await s.refresh(agentId);
            if (!sent && context.mounted) {
              pillToast(context, l.ubSetupNotConnectedHost);
            }
          },
        );
      },
    ),
  );
}
