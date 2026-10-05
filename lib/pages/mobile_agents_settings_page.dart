import 'dart:async';
import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/pages/coworker_model_page.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
import 'package:chuk_chat/widgets/coworker_model_tile.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/floating_app_bar.dart';
import 'package:chuk_chat/widgets/settings_list_view.dart';

/// The mobile contact page: everyday choices first, technical details second.
/// Every destination is supplied by the shell, so this page never owns or
/// reconnects a transport and always acts on the coworker whose name was tapped.
///
/// It wears the settings frame and rows every other settings page wears
/// (FloatingAppBar, SettingsListView, the Expressive rows). The coworker's
/// face, name and role head the list, where a contact page puts them.
class MobileAgentsSettingsPage extends StatefulWidget {
  const MobileAgentsSettingsPage({
    super.key,
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
  });

  final String agentId;
  final String? chatId;
  final AgentRosterSource source;
  final AgentProfileStore? profiles;
  final MobileChatPreferences? preferences;
  /// [onModel] runs only for a coworker with no thread yet; with one, the
  /// page opens the coworker's model page itself.
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

  @override
  State<MobileAgentsSettingsPage> createState() =>
      _MobileAgentsSettingsPageState();
}

class _MobileAgentsSettingsPageState extends State<MobileAgentsSettingsPage> {
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

  /// The coworker's model page — the one place its model, provider and
  /// reasoning level are set. Without a thread there is nothing to store the
  /// choice under, and the shell's own action runs instead.
  void _openModel(AgentsAgent agent) {
    final String? chatId = widget.chatId;
    if (chatId == null) {
      widget.onModel();
      return;
    }
    unawaited(
      CoworkerModelPage.open(context, chatId: chatId, coworkerName: agent.name),
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
    Navigator.of(context).pop();
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
          return Scaffold(
            // The page runs underneath the floating header.
            extendBodyBehindAppBar: true,
            appBar: FloatingAppBar(title: Text(l.agentsCwTitle)),
            body: Center(child: Text(l.agentsCwGone)),
          );
        }
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
          body: SettingsListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _contact(agent, profiles),
              const SizedBox(height: 20),
              _actionRow(agent),
              // What it runs on: its own model or the app default. One row,
              // one page — the composer of its chat writes the same choice.
              ExpressiveSectionHeader(l.agentsCwModel),
              ExpressiveGroup(
                children: [
                  if (widget.chatId != null)
                    CoworkerModelTile(
                      key: const ValueKey('settings_Model'),
                      chatId: widget.chatId!,
                      coworkerName: agent.name,
                    )
                  else
                    _row(
                      'Model',
                      l.agentsCwModel,
                      Icons.auto_awesome_outlined,
                      () => _openModel(agent),
                      subtitle: l.agentsCwModelSubtitle,
                    ),
                ],
              ),
              ExpressiveSectionHeader(l.agentsCwTitle),
              ExpressiveGroup(
                children: [
                  _row(
                    'Profile & preferences',
                    l.agentsCwProfile,
                    Icons.person_outline,
                    widget.onEdit,
                    subtitle: l.agentsCwProfileSubtitle,
                  ),
                  _row(
                    'Host & activity',
                    l.agentsCwHost,
                    Icons.computer_outlined,
                    widget.onControls,
                    subtitle: l.agentsCwHostSubtitle,
                  ),
                ],
              ),
              if (widget.onDocuments != null) ...[
                ExpressiveSectionHeader(l.agentsCwSharedFiles),
                ExpressiveGroup(
                  children: [
                    _row(
                      'Documents & artifacts',
                      l.agentsCwDocuments,
                      Icons.folder_open_rounded,
                      widget.onDocuments!,
                      subtitle: l.agentsCwDocumentsSubtitle,
                    ),
                  ],
                ),
              ],
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
              ExpressiveSectionHeader(l.agentsCwAgentTools),
              ExpressiveGroup(
                children: [
                  _row(
                    'Schedules & automations',
                    l.agentsCwSchedules,
                    Icons.schedule_outlined,
                    widget.onAutomations,
                    subtitle: l.agentsCwSchedulesSubtitle,
                  ),
                  _row(
                    'Skills',
                    l.skills,
                    Icons.extension_outlined,
                    widget.onSkills,
                  ),
                ],
              ),
              ExpressiveSectionHeader(l.agentsCwConnections),
              ExpressiveGroup(
                children: [
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
                    'Control rooms',
                    l.agentsCwControlRooms,
                    Icons.group_outlined,
                    widget.onRooms,
                  ),
                  if (widget.onBrowser != null)
                    _row(
                      'Open screen',
                      l.agentsCwOpenScreen,
                      Icons.desktop_windows_outlined,
                      widget.onBrowser!,
                    ),
                ],
              ),
              ExpressiveSectionHeader(l.agentsCwApp),
              ExpressiveGroup(
                children: [
                  _row(
                    'Account & app settings',
                    l.agentsCwAccountSettings,
                    Icons.settings_outlined,
                    widget.onSettings,
                    subtitle: l.agentsCwAccountSettingsSubtitle,
                  ),
                ],
              ),
              if (widget.onDelete != null) ...[
                const SizedBox(height: 24),
                _removeButton(agent),
              ],
            ],
          ),
        );
      },
    );
  }

  /// The coworker the page is about: face, name and role, centred over the
  /// list the way a contact page opens.
  Widget _contact(AgentsAgent agent, AgentProfileStore profiles) {
    final theme = Theme.of(context);
    return Column(
      children: [
        AgentFace(agent: agent, size: 96, store: profiles),
        const SizedBox(height: 16),
        // Two lines: a coworker's name is never cut at a large text size
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
          profiles.profileOf(agent.id).role ??
              agent.role ??
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

  Widget _actionRow(AgentsAgent agent) {
    final AppLocalizations l = _l;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _action(l.agentsCwActionChat, Icons.chat_rounded, () {
          Navigator.of(context).pop();
          widget.onChat?.call();
        }),
        _action(
          l.agentsCwModel,
          Icons.auto_awesome_rounded,
          () => _openModel(agent),
        ),
        if (widget.onDocuments != null)
          _action(
            l.agentsCwActionFiles,
            Icons.folder_rounded,
            widget.onDocuments!,
          ),
        _action(
          l.agentsCwActionSchedules,
          Icons.schedule_rounded,
          widget.onAutomations,
        ),
        _action(
          l.agentsCwActionSkills,
          Icons.extension_rounded,
          widget.onSkills,
        ),
      ],
    );
  }

  /// One quick action: the settings icon tile over its label, the whole
  /// column the target.
  Widget _action(String label, IconData icon, VoidCallback onTap) {
    final theme = Theme.of(context);
    return Expanded(
      child: Tooltip(
        message: label,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(18),
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                ExpressiveIconTile(icon: icon, size: 48),
                const SizedBox(height: 8),
                Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.m3.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
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

  /// Removing a coworker is the page's one destructive action, drawn the way
  /// the settings page draws sign-out.
  Widget _removeButton(AgentsAgent agent) {
    final theme = Theme.of(context);
    return SizedBox(
      width: double.infinity,
      child: OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: theme.colorScheme.error,
          side: BorderSide(color: theme.m3.outline),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(999),
          ),
        ),
        onPressed: () => _remove(agent),
        child: Text(
          _l.agentsCwRemoveCoworker,
          style: const TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
        ),
      ),
    );
  }
}
