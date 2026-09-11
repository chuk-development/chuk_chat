import 'dart:async';
import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/expressive_screen.dart';
import 'package:cowork/ui/expressive/icon_map.dart';
import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_roster_source.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/services/settings/mobile_chat_preferences.dart';
import 'package:cowork/services/chat_model_selection_service.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/motion.dart';

/// The mobile contact page: everyday choices first, technical details second.
/// Every destination is supplied by the shell, so this page never owns or
/// reconnects a transport and always acts on the coworker whose name was tapped.
class MobileCoworkSettingsPage extends StatefulWidget {
  const MobileCoworkSettingsPage({
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
  State<MobileCoworkSettingsPage> createState() =>
      _MobileCoworkSettingsPageState();
}

class _MobileCoworkSettingsPageState extends State<MobileCoworkSettingsPage> {
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

  Future<void> _remove(CoworkAgent agent) async {
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
    final scheme = Theme.of(context).colorScheme;
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
          return ExpressiveScreen(
            backgroundColor: scheme.surface,
            title: 'Coworker',
            builder: (BuildContext context) => const Center(
              child: Text('This coworker is no longer in your list.'),
            ),
          );
        }
        return Scaffold(
          backgroundColor: scheme.surface,
          body: CustomScrollView(
            slivers: [
              SliverAppBar(
                pinned: true,
                expandedHeight:
                    300 +
                    (MediaQuery.textScalerOf(context).scale(24) - 24).clamp(
                      0,
                      80,
                    ),
                backgroundColor: scheme.surface,
                surfaceTintColor: Colors.transparent,
                leadingWidth: 64,
                leading: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: ExpressiveIconButton(
                      icon: Icons.arrow_back_rounded,
                      tooltip: 'Back',
                      onTap: () => Navigator.of(context).maybePop(),
                    ),
                  ),
                ),
                actions: [
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: ExpressiveIconButton(
                      icon: Icons.edit_rounded,
                      tooltip: 'Edit coworker',
                      color: scheme.surfaceContainerHigh,
                      onTap: widget.onEdit,
                    ),
                  ),
                ],
                flexibleSpace: FlexibleSpaceBar(
                  background: SafeArea(
                    child: Center(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(24, 56, 24, 16),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            AgentFace(agent: agent, size: 96, store: profiles),
                            const SizedBox(height: 16),
                            Text(
                              agent.name,
                              textAlign: TextAlign.center,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              profiles.profileOf(agent.id).role ??
                                  agent.role ??
                                  'Your coworker',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              textAlign: TextAlign.center,
                              style: Theme.of(context).textTheme.bodyMedium
                                  ?.copyWith(color: scheme.onSurfaceVariant),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SliverPadding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 40),
                sliver: SliverList.list(
                  children: [
                    _actionRow(),
                    _section('Coworker', [
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
                    ]),
                    if (widget.onDocuments != null)
                      _section('Shared files', [
                        _row(
                          'Documents & artifacts',
                          Icons.folder_open_rounded,
                          widget.onDocuments!,
                          subtitle: 'Files and results from this conversation',
                        ),
                      ]),
                    _section('Conversation', [
                      _switch(
                        'Messenger typography',
                        'Compact, readable chat text. Turn off to use your custom chat font.',
                        Icons.text_fields_rounded,
                        _preferences.messengerTypography,
                        _preferences.setMessengerTypography,
                        'mobile_messenger_typography',
                      ),
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
                    ]),
                    _section('Agent tools', [
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
                    ]),
                    _section('Connections & access', [
                      _row(
                        'Connected apps',
                        Icons.link_rounded,
                        widget.onConnectors,
                      ),
                      _row('API keys', Icons.key_outlined, widget.onSecrets),
                      _row(
                        'Control rooms',
                        Icons.group_outlined,
                        widget.onRooms,
                      ),
                      if (widget.onBrowser != null)
                        _row(
                          'Open screen',
                          Icons.desktop_windows_outlined,
                          widget.onBrowser!,
                        ),
                    ]),
                    _section('App', [
                      _row(
                        'Account & app settings',
                        Icons.settings_outlined,
                        widget.onSettings,
                        subtitle: 'Account, appearance, privacy and more',
                      ),
                    ]),
                    if (widget.onDelete != null) ...[
                      const SizedBox(height: 24),
                      TextButton.icon(
                        onPressed: () => _remove(agent),
                        style: TextButton.styleFrom(
                          foregroundColor: scheme.error,
                          minimumSize: const Size.fromHeight(48),
                        ),
                        icon: const AppIcon(Icons.person_remove_outlined),
                        label: const Text('Remove coworker'),
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _actionRow() => Row(
    mainAxisAlignment: MainAxisAlignment.spaceBetween,
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

  Widget _action(String label, IconData icon, VoidCallback onTap) {
    final scheme = Theme.of(context).colorScheme;
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ExpressiveIconButton(
            icon: icon,
            tooltip: label,
            color: scheme.secondaryContainer,
            onColor: scheme.onSecondaryContainer,
            onTap: onTap,
          ),
          const SizedBox(height: 8),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: Theme.of(
              context,
            ).textTheme.labelMedium?.copyWith(color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  Widget _section(String title, List<Widget> children) => Padding(
    padding: const EdgeInsets.only(top: 28),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            title.toUpperCase(),
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
        ),
        Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          borderRadius: BorderRadius.circular(28),
          clipBehavior: Clip.antiAlias,
          child: Padding(
            padding: const EdgeInsets.all(6),
            child: Column(children: children),
          ),
        ),
      ],
    ),
  );

  Widget _row(
    String title,
    IconData icon,
    VoidCallback action, {
    String? subtitle,
  }) => MorphTap(
    key: ValueKey('settings_$title'),
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    pressedShape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    ),
    color: Colors.transparent,
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
    onTap: action,
    child: Row(
      children: [
        _icon(icon, Theme.of(context).colorScheme.tertiary),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              if (subtitle != null) ...[
                const SizedBox(height: 2),
                Text(
                  subtitle,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(width: 8),
        AppIcon(
          Icons.chevron_right_rounded,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      ],
    ),
  );

  Widget _switch(
    String title,
    String subtitle,
    IconData icon,
    bool value,
    Future<void> Function(bool) changed,
    String id,
  ) => MorphTap(
    color: Colors.transparent,
    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
    pressedShape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    ),
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    onTap: () => unawaited(changed(!value)),
    child: Row(
      children: [
        _icon(icon, Theme.of(context).colorScheme.primary),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                title,
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 2),
              Text(
                subtitle,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
        Switch(
          key: ValueKey(id),
          value: value,
          onChanged: (value) => unawaited(changed(value)),
        ),
      ],
    ),
  );

  Widget _icon(IconData icon, Color color) => Container(
    width: 40,
    height: 40,
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.16),
      borderRadius: BorderRadius.circular(13),
    ),
    child: AppIcon(icon, size: 21, color: color),
  );
}
