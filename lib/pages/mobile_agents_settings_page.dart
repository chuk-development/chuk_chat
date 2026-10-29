import 'dart:async';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/agent_mailbox_page.dart';
import 'package:chuk_chat/pages/agent_model_page.dart';
import 'package:chuk_chat/pages/mobile_agent_permissions_page.dart'; // polish
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart'; // polish
import 'package:chuk_chat/services/agents/agents_relay_client.dart'
    show AgentsRelayController, AgentsRelayState;
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/agent_model_tile.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

/// An agent's settings: ONE content for every form factor (bead
/// chuk_chat-8hz4). The phone shows it as a page under the shared
/// transparent header ([MobileAgentsSettingsPage]); a wide window shows the
/// same content in the right-hand details pane ([framed] false). The
/// sections, the rows, their order and their words are the same in both.
///
/// Every destination is supplied by the shell, so this view never owns or
/// reconnects a transport and always acts on the agent whose name was tapped.
/// It draws the rows every other settings page draws (SettingsListView, the
/// Expressive rows). The agent's face, name and role head the list, where a
/// contact page puts them.
class AgentSettingsView extends StatefulWidget {
  const AgentSettingsView({
    super.key,
    this.framed = false,
    this.onClose,
    this.link,
    required this.agentId,
    required this.source,
    required this.onEdit,
    required this.onControls,
    required this.onModel,
    required this.onAutomations,
    required this.onSkills,
    required this.onConnectors,
    required this.onSecrets,
    required this.onRooms,
    required this.onSettings,
    this.onDocuments,
    this.onCopyChat,
    this.onBrowser,
    this.onDelete,
    this.profiles,
    this.preferences,
    this.onChat,
    this.chatId,
    this.permissions, // polish
  });

  /// True: a full page with the shared header (back chip, title pill, the
  /// edit action). False: the bare list, for a pane that has a header of its
  /// own.
  final bool framed;

  /// Leaves the view after Hide, Remove or Chat. Null pops the route (the
  /// page); the pane passes its own close.
  final VoidCallback? onClose;

  /// The host link, for the "Runs on the host" row. Defaults to
  /// [AgentsRelayLink.instance].
  final AgentsRelayLink? link;

  final String agentId;
  final String? chatId;
  final AgentRosterSource source;
  final AgentProfileStore? profiles;
  final MobileChatPreferences? preferences;
  /// [onModel] runs only for an agent with no thread yet; with one, the
  /// page opens the agent's model page itself.
  final VoidCallback onEdit,
      onControls,
      onModel,
      onAutomations,
      onSkills,
      onConnectors,
      onSecrets,
      onRooms,
      onSettings;
  final VoidCallback? onDocuments, onCopyChat, onBrowser, onDelete, onChat;

  // ── polish ──
  /// Where the Permissions page reads and sends (sandbox switches, approvals,
  /// weekly budget). Defaults to [AgentsPermissionsService.instance].
  final AgentsPermissionsService? permissions;
  // ── end polish ──

  @override
  State<AgentSettingsView> createState() => _AgentSettingsViewState();
}

/// [AgentSettingsView] as a phone page: the shared transparent header over
/// the same content.
class MobileAgentsSettingsPage extends AgentSettingsView {
  const MobileAgentsSettingsPage({
    super.key,
    required super.agentId,
    required super.source,
    required super.onEdit,
    required super.onControls,
    required super.onModel,
    required super.onAutomations,
    required super.onSkills,
    required super.onConnectors,
    required super.onSecrets,
    required super.onRooms,
    required super.onSettings,
    super.onDocuments,
    super.onCopyChat,
    super.onBrowser,
    super.onDelete,
    super.profiles,
    super.preferences,
    super.onChat,
    super.chatId,
    super.permissions,
    super.link,
  }) : super(framed: true);
}

class _AgentSettingsViewState extends State<AgentSettingsView> {
  /// Leaves the view: the pane's close, or back off the page.
  void _close() {
    final VoidCallback? close = widget.onClose;
    if (close != null) return close();
    Navigator.of(context).maybePop();
  }

  MobileChatPreferences get _preferences =>
      widget.preferences ?? MobileChatPreferences.instance;

  /// The page's words; English when the tree has no localisations (tests).
  AppLocalizations get _l =>
      AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

  @override
  void initState() {
    super.initState();
    unawaited(_preferences.load());
  }

  /// The agent's model page — the one place its model, provider and
  /// reasoning level are set. Without a thread there is nothing to store the
  /// choice under, and the shell's own action runs instead.
  void _openModel(AgentsAgent agent) {
    final String? chatId = widget.chatId;
    if (chatId == null) {
      widget.onModel();
      return;
    }
    unawaited(
      AgentModelPage.open(context, chatId: chatId, agentName: agent.name),
    );
  }

  Future<void> _remove(AgentsAgent agent) async {
    final AppLocalizations l = _l;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l.agentsCwRemoveTitle(agent.name)),
        content: Text(l.agentsCwRemoveBody),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(l.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(l.agentsCwRemove),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true) return;
    _close();
    widget.onDelete?.call();
  }

  @override
  Widget build(BuildContext context) {
    final profiles = widget.profiles ?? AgentProfileStore.instance;
    return AnimatedBuilder(
      animation: Listenable.merge([widget.source, profiles, _preferences]),
      builder: (context, _) {
        final AppLocalizations l = _l;
        final agent = widget.source.byId(widget.agentId);
        if (agent == null) {
          if (!widget.framed) return Center(child: Text(l.agentsCwGone));
          return Scaffold(
            // The page runs underneath the floating header.
            extendBodyBehindAppBar: true,
            appBar: FloatingAppBar(title: Text(l.agentsCwTitle)),
            body: Center(child: Text(l.agentsCwGone)),
          );
        }
        final ColorScheme scheme = Theme.of(context).colorScheme;
        // One screen owns each thing (bead chuk_chat-8hz4). This view only
        // links to them: on top what the agent is and may do; under
        // "Advanced" its abilities, channels, computer, the conversation,
        // the app, and the destructive actions last.
        final Widget list = SettingsListView(
            key: const ValueKey('agent-settings'),
            headerInset: widget.framed,
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _contact(agent, profiles),
              const SizedBox(height: 16),
              Center(
                child: ExpressiveButton(
                  key: const ValueKey('settings_Chat'),
                  icon: Icons.chat_rounded,
                  label: l.agentsCwActionChat,
                  tonal: true,
                  onTap: () {
                    _close();
                    widget.onChat?.call();
                  },
                ),
              ),
              // The top: what a normal user changes about an agent, in one
              // group (bead chuk_chat-pjom, docs/SETTINGS_ORDER.md): its
              // profile (name, face), its model, what it may do and what it
              // made. The rest sits in one closed "Advanced" fold, in the
              // order it had before.
              const SizedBox(height: 16),
              ExpressiveGroup(
                children: [
                  _row(
                    'Profile & preferences',
                    l.agentsCwProfile,
                    Icons.person_outline,
                    widget.onEdit,
                    subtitle: l.agentsCwProfileSubtitle,
                  ),
                  // One row, one page: the composer of its chat writes the
                  // same choice.
                  if (widget.chatId != null)
                    AgentModelTile(
                      key: const ValueKey('settings_Model'),
                      chatId: widget.chatId!,
                      agentName: agent.name,
                    )
                  else
                    _row(
                      'Model',
                      l.agentsCwModel,
                      Icons.auto_awesome_outlined,
                      () => _openModel(agent),
                      subtitle: l.agentsCwModelSubtitle,
                    ),
                  _row(
                    'Permissions',
                    l.agentsCwPermissions,
                    Icons.verified_rounded,
                    () => unawaited(
                      MobileAgentPermissionsPage.open(
                        context,
                        agentId: agent.id,
                        service: widget.permissions,
                      ),
                    ),
                    subtitle: l.agentsCwPermissionsSubtitle,
                  ),
                  if (widget.onDocuments != null)
                    _row(
                      'Documents & pages',
                      l.agentsCwDocuments,
                      Icons.folder_open_rounded,
                      widget.onDocuments!,
                      subtitle: l.agentsCwDocumentsSubtitle,
                    ),
                ],
              ),
              ExpressiveAdvancedSection(
                title: l.settingsAdvanced,
                toggleKey: const ValueKey<String>('settings_Advanced'),
                children: [
                  ExpressiveSectionHeader(l.agentsCwSectionAbilities),
                  ExpressiveGroup(
                    children: [
                      _row(
                        'Skills',
                        l.skills,
                        Icons.extension_outlined,
                        widget.onSkills,
                        subtitle: l.agentsCwSkillsSubtitle,
                      ),
                      _row(
                        'Connected apps',
                        l.agentsCwConnectedApps,
                        Icons.link_rounded,
                        widget.onConnectors,
                      ),
                      _row(
                        'API keys',
                        l.agentsCwApiKeys,
                        Icons.key_outlined,
                        widget.onSecrets,
                      ),
                      _row(
                        'Schedules & automations',
                        l.agentsCwSchedules,
                        Icons.schedule_outlined,
                        widget.onAutomations,
                        subtitle: l.agentsCwSchedulesSubtitle,
                      ),
                    ],
                  ),
                  // Its channels: mail. There is no messenger channel.
                  ExpressiveSectionHeader(l.agentsChannels),
                  ExpressiveGroup(
                    children: [
                      _row(
                        'Mail',
                        l.agentMail,
                        Icons.mail_outline,
                        _openMail,
                        subtitle: l.agentMailSubtitle,
                      ),
                    ],
                  ),
                  // Its computer: the host, what ran there, the screen, files.
                  ExpressiveSectionHeader(l.agentsCwSectionMachine),
                  ExpressiveGroup(
                    children: [
                      _HostRow(
                        agent: agent,
                        link: widget.link ?? AgentsRelayLink.instance,
                      ),
                      _row(
                        'Host & activity',
                        l.agentsCwHost,
                        Icons.computer_outlined,
                        widget.onControls,
                        subtitle: l.agentsCwHostSubtitle,
                      ),
                      if (widget.onBrowser != null)
                        _row(
                          'Open screen',
                          l.agentsCwOpenScreen,
                          Icons.desktop_windows_outlined,
                          widget.onBrowser!,
                          subtitle: l.agentsCwScreenSubtitle,
                        ),
                    ],
                  ),
                  ExpressiveSectionHeader(l.agentsCwConversation),
                  ExpressiveGroup(
                    children: [
                      _switch(
                        l.agentsCwShowThinking,
                        l.agentsCwShowThinkingSubtitle,
                        Icons.more_horiz,
                        _preferences.showThinking,
                        _preferences.setThinking,
                        'mobile_show_thinking',
                      ),
                      _switch(
                        l.agentsCwShowWork,
                        l.agentsCwShowWorkSubtitle,
                        Icons.code_rounded,
                        _preferences.showActivity,
                        _preferences.setActivity,
                        'mobile_show_activity',
                      ),
                      if (widget.onCopyChat != null)
                        _row(
                          'Export conversation',
                          l.agentsCwExport,
                          Icons.ios_share_rounded,
                          widget.onCopyChat!,
                        ),
                    ],
                  ),
                  ExpressiveSectionHeader(l.agentsCwApp),
                  ExpressiveGroup(
                    children: [
                      _row(
                        'Control rooms',
                        l.agentsCwControlRooms,
                        Icons.group_outlined,
                        widget.onRooms,
                      ),
                      _row(
                        'Account & app settings',
                        l.agentsCwAccountSettings,
                        Icons.settings_outlined,
                        widget.onSettings,
                        subtitle: l.agentsCwAccountSettingsSubtitle,
                      ),
                    ],
                  ),
                  // The destructive actions, last.
                  ExpressiveSectionHeader(
                    l.agentsCwSectionDanger,
                    color: scheme.error,
                  ),
                  ExpressiveGroup(
                    children: [
                      _row(
                        'Hide',
                        l.agentsCwHide,
                        Icons.visibility_off_outlined,
                        () => _hide(agent),
                        subtitle: l.agentsCwHideSubtitle,
                      ),
                      if (widget.onDelete != null)
                        ExpressiveRow(
                          key: const ValueKey('settings_Remove'),
                          icon: Icons.delete_outline,
                          tone: scheme.errorContainer,
                          title: l.agentsCwRemoveAgent,
                          onTap: () => _remove(agent),
                        ),
                    ],
                  ),
                ],
              ),
            ],
          );
        if (!widget.framed) return list;
        return Scaffold(
          // The page runs underneath the floating header.
          extendBodyBehindAppBar: true,
          appBar: FloatingAppBar(
            title: Text(l.agentsCwTitle),
            actions: <Widget>[
              FloatingHeaderButton(
                icon: Icons.edit_rounded,
                tooltip: l.agentsCwEdit,
                onPressed: widget.onEdit,
              ),
            ],
          ),
          body: list,
        );
      },
    );
  }

  /// The agent's mailbox. The address belongs to the account, so every
  /// agent opens the same mailbox.
  void _openMail() => unawaited(
    Navigator.of(context).push<void>(
      MaterialPageRoute<void>(builder: (_) => const AgentMailboxPage()),
    ),
  );

  /// Hides the agent from the list. It keeps its session; the page closes.
  void _hide(AgentsAgent agent) {
    widget.source.hideAgent(agent.id);
    pillToast(
      context,
      _l.agentsCwHidden(agent.name),
      icon: Icons.visibility_off_rounded,
    );
    _close();
  }

  /// The agent the page is about: face, name and role, centred over the
  /// list the way a contact page opens.
  Widget _contact(AgentsAgent agent, AgentProfileStore profiles) {
    final theme = Theme.of(context);
    return Column(
      children: [
        AgentFace(agent: agent, size: 96, store: profiles),
        const SizedBox(height: 16),
        // Two lines: an agent's name is never cut at a large text size
        // (UI audit 2026-10-05, profile item 4).
        Text(
          agent.name,
          textAlign: TextAlign.center,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          profiles.profileOf(agent.id).roleOver(agent.role) ??
              _l.agentsCwRoleFallback,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          textAlign: TextAlign.center,
          style: theme.textTheme.bodyMedium?.copyWith(
            color: theme.m3.onSurfaceVariant,
          ),
        ),
      ],
    );
  }

  /// [id] is the row's fixed English name: it keys the row, so a test or a
  /// tour finds it in every language.
  Widget _row(
    String id,
    String title,
    IconData icon,
    VoidCallback action, {
    String? subtitle,
  }) => ExpressiveRow(
    key: ValueKey('settings_$id'),
    icon: icon,
    title: title,
    subtitle: subtitle,
    onTap: action,
  );

  Widget _switch(
    String title,
    String subtitle,
    IconData icon,
    bool value,
    Future<void> Function(bool) changed,
    String id,
  ) => ExpressiveSwitchRow(
    key: ValueKey(id),
    icon: icon,
    title: title,
    subtitle: subtitle,
    value: value,
    onChanged: (value) => unawaited(changed(value)),
  );
}

/// Where the agent runs, told from what the app knows (bead
/// chuk_chat-89vl): on the host when the host keeps it (its own agent, one
/// it listed, or one it ran a turn of); and whether that host is reachable now.
/// "This app only" is said only while the host is reachable and does not know
/// the agent. With the host offline and no proof either way, it says that.
class _HostRow extends StatelessWidget {
  const _HostRow({required this.agent, required this.link});

  final AgentsAgent agent;
  final AgentsRelayLink link;

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AgentsRelayController?>(
      valueListenable: link.controller,
      builder: (BuildContext context, AgentsRelayController? controller, _) {
        if (controller == null) return _card(paired: false);
        return ValueListenableBuilder<AgentsRelayState>(
          valueListenable: controller.state,
          builder: (BuildContext context, AgentsRelayState state, _) =>
              _card(paired: state.isPaired),
        );
      },
    );
  }

  Widget _card({required bool paired}) {
    final bool onHost = agent.runsOnHost;
    final (IconData icon, String value, String? note) = switch ((
      onHost,
      paired,
    )) {
      (true, true) => (
        Icons.verified_rounded,
        'Yes — this agent runs on the paired host',
        null,
      ),
      (true, false) => (
        Icons.cloud_off_rounded,
        'Yes — on your host, which is offline right now',
        'Messages wait and go out when it is back.',
      ),
      (false, true) => (
        Icons.phonelink_off_rounded,
        'Not yet — it lives in this app only',
        null,
      ),
      (false, false) => (
        Icons.cloud_off_rounded,
        'Not confirmed — your host is offline',
        'The host says which agents it keeps when it is back.',
      ),
    };
    return _InfoCard(
      key: const ValueKey<String>('agent_profile_host'),
      icon: icon,
      label: 'Runs on the host',
      value: value,
      note: note,
    );
  }
}

/// One fact as a row of its group: the icon tile, the label, the value and
/// an optional note. A fact has no target, so the tile takes no tap.
class _InfoCard extends StatelessWidget {
  const _InfoCard({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    this.note,
  });

  final IconData icon;
  final String label;
  final String value;

  /// A second line that qualifies the value — used where the app must say that
  /// something is local only.
  final String? note;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextTheme text = Theme.of(context).textTheme;
    return ExpressiveTile(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          ExpressiveIconTile(icon: icon),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(
                  label,
                  style: text.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  value,
                  style: text.bodySmall?.copyWith(
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (note != null) ...<Widget>[
                  const SizedBox(height: 2),
                  Text(
                    note!,
                    style: text.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
