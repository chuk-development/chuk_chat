import 'dart:async';
import 'package:flutter/material.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_roster_source.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/settings/mobile_chat_preferences.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/utils/theme_extensions.dart';
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

  @override
  void initState() {
    super.initState();
    unawaited(_preferences.load());
    if (widget.chatId != null) {
      unawaited(ChatModelSelectionService.instance.load(widget.chatId!));
    }
  }

  Future<void> _remove(AgentsAgent agent) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove ${agent.name}?'),
        content: const Text(
          'This removes the coworker from your list and control rooms. The host workspace is kept.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
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
      animation: Listenable.merge([
        widget.source,
        profiles,
        _preferences,
        ChatModelSelectionService.instance,
      ]),
      builder: (context, _) {
        final agent = widget.source.byId(widget.agentId);
        final selection = widget.chatId == null
            ? null
            : ChatModelSelectionService.instance.peek(widget.chatId!);
        if (agent == null) {
          return const Scaffold(
            // The page runs underneath the floating header.
            extendBodyBehindAppBar: true,
            appBar: FloatingAppBar(title: Text('Coworker')),
            body: Center(
              child: Text('This coworker is no longer in your list.'),
            ),
          );
        }
        return Scaffold(
          // The page runs underneath the floating header.
          extendBodyBehindAppBar: true,
          appBar: FloatingAppBar(
            title: const Text('Coworker'),
            actions: <Widget>[
              FloatingHeaderButton(
                icon: Icons.edit_rounded,
                tooltip: 'Edit coworker',
                onPressed: widget.onEdit,
              ),
            ],
          ),
          body: SettingsListView(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
            children: [
              _contact(agent, profiles),
              const SizedBox(height: 20),
              _actionRow(),
              const ExpressiveSectionHeader('Coworker'),
              ExpressiveGroup(
                children: [
                  _row(
                    'Profile & preferences',
                    Icons.person_outline,
                    widget.onEdit,
                    subtitle: 'Name, picture, colour and shape',
                  ),
                  _row(
                    'Host & activity',
                    Icons.computer_outlined,
                    widget.onControls,
                    subtitle: 'Connection details, usage and workspace',
                  ),
                ],
              ),
              if (widget.onDocuments != null) ...[
                const ExpressiveSectionHeader('Shared files'),
                ExpressiveGroup(
                  children: [
                    _row(
                      'Documents & artifacts',
                      Icons.folder_open_rounded,
                      widget.onDocuments!,
                      subtitle: 'Files and results from this conversation',
                    ),
                  ],
                ),
              ],
              const ExpressiveSectionHeader('Conversation'),
              ExpressiveGroup(
                children: [
                  _switch(
                    'Show thinking',
                    'Live reasoning, when the selected model provides it.',
                    Icons.more_horiz,
                    _preferences.showThinking,
                    _preferences.setThinking,
                    'mobile_show_thinking',
                  ),
                  _switch(
                    'Show work details',
                    'Tool calls and technical activity. Hidden by default.',
                    Icons.code_rounded,
                    _preferences.showActivity,
                    _preferences.setActivity,
                    'mobile_show_activity',
                  ),
                  if (widget.onCopyChat != null)
                    _row(
                      'Export conversation',
                      Icons.ios_share_rounded,
                      widget.onCopyChat!,
                    ),
                ],
              ),
              const ExpressiveSectionHeader('Agent tools'),
              ExpressiveGroup(
                children: [
                  _row(
                    'Model',
                    Icons.auto_awesome_outlined,
                    widget.onModel,
                    subtitle: selection == null
                        ? 'Choose a model and provider for this chat'
                        : '${selection.modelId}\n${selection.providerSlug.isEmpty ? 'Automatic provider' : selection.providerSlug}',
                  ),
                  _row(
                    'Schedules & automations',
                    Icons.schedule_outlined,
                    widget.onAutomations,
                    subtitle: 'Only schedules and watchers for this chat',
                  ),
                  _row('Skills', Icons.extension_outlined, widget.onSkills),
                ],
              ),
              const ExpressiveSectionHeader('Connections & access'),
              ExpressiveGroup(
                children: [
                  _row(
                    'Connected apps',
                    Icons.link_rounded,
                    widget.onConnectors,
                  ),
                  _row('API keys', Icons.key_outlined, widget.onSecrets),
                  _row('Control rooms', Icons.group_outlined, widget.onRooms),
                  if (widget.onBrowser != null)
                    _row(
                      'Open screen',
                      Icons.desktop_windows_outlined,
                      widget.onBrowser!,
                    ),
                ],
              ),
              const ExpressiveSectionHeader('App'),
              ExpressiveGroup(
                children: [
                  _row(
                    'Account & app settings',
                    Icons.settings_outlined,
                    widget.onSettings,
                    subtitle: 'Account, appearance, privacy and more',
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
        Text(
          agent.name,
          textAlign: TextAlign.center,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: theme.textTheme.headlineSmall?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          profiles.profileOf(agent.id).role ?? agent.role ?? 'Your coworker',
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

  Widget _actionRow() => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _action('Chat', Icons.chat_rounded, () {
        Navigator.of(context).pop();
        widget.onChat?.call();
      }),
      _action('Model', Icons.auto_awesome_rounded, widget.onModel),
      if (widget.onDocuments != null)
        _action('Files', Icons.folder_rounded, widget.onDocuments!),
      _action('Schedules', Icons.schedule_rounded, widget.onAutomations),
      _action('Skills', Icons.extension_rounded, widget.onSkills),
    ],
  );

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

  Widget _row(
    String title,
    IconData icon,
    VoidCallback action, {
    String? subtitle,
  }) => ExpressiveRow(
    key: ValueKey('settings_$title'),
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
        child: const Text(
          'Remove coworker',
          style: TextStyle(fontWeight: FontWeight.w500, fontSize: 14),
        ),
      ),
    );
  }
}
