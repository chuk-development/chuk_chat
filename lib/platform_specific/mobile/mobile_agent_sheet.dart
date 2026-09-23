/// The "more" sheet of a phone chat.
///
/// On a wide window the shell shows six icons in its app bar: controls,
/// rooms, browser, copy full chat, settings, sign out. A phone has room for
/// the three that matter in a chat (the parked call, the browser, more); the
/// rest live here, in a bottom sheet the "…" target opens. The rows are the
/// app's one menu surface — `MenuActionRow` on `MenuTileGroup` — so this sheet
/// reads like every dropdown and every long-press menu.
///
/// The first run is the coworker's blob face, its name and its role — the same
/// identity the inbox row and the chat pill show.
///
/// Every callback is optional: a null one hides its row, so the sheet only
/// lists what the shell can actually do for the selected coworker.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/feedback.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';

class MobileAgentSheet extends StatelessWidget {
  const MobileAgentSheet({
    super.key,
    required this.agent,
    this.onProfile,
    this.onControls,
    this.onRename,
    this.onRooms,
    this.onCopyChat,
    this.onSettings,
    this.onSignOut,
  });

  final AgentsAgent agent;

  /// Opens the coworker's profile page.
  final VoidCallback? onProfile;
  final VoidCallback? onControls;
  final VoidCallback? onRename;
  final VoidCallback? onRooms;
  final VoidCallback? onCopyChat;
  final VoidCallback? onSettings;
  final VoidCallback? onSignOut;

  /// Opens the sheet. Each row closes the sheet first, then runs its action,
  /// so an action that opens another page or drawer does not stack on top of
  /// the sheet.
  static Future<void> show(
    BuildContext context, {
    required AgentsAgent agent,
    VoidCallback? onProfile,
    VoidCallback? onControls,
    VoidCallback? onRename,
    VoidCallback? onRooms,
    VoidCallback? onCopyChat,
    VoidCallback? onSettings,
    VoidCallback? onSignOut,
  }) {
    VoidCallback? closeThen(VoidCallback? action) {
      if (action == null) return null;
      return () {
        Navigator.of(context).pop();
        action();
      };
    }

    final MobileAgentSheet sheet = MobileAgentSheet(
      agent: agent,
      onProfile: closeThen(onProfile),
      onControls: closeThen(onControls),
      onRename: closeThen(onRename),
      onRooms: closeThen(onRooms),
      onCopyChat: closeThen(onCopyChat),
      onSettings: closeThen(onSettings),
      onSignOut: closeThen(onSignOut),
    );
    return showMenuSheet<void>(context, groups: sheet.menuGroups(context));
  }

  /// The runs of the menu: identity, the coworker's own actions, the parked
  /// call, the app's settings, and sign out on its own.
  List<List<Widget>> menuGroups(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final AgentProfile profile = AgentProfileStore.instance.profileOf(agent.id);
    final String? stored = profile.role?.trim();
    final String? role = (stored?.isNotEmpty ?? false)
        ? stored
        : agent.role?.trim();
    return <List<Widget>>[
      <Widget>[
        MenuActionRow(
          leading: AgentFace(agent: agent, size: 44),
          label: agent.name,
          subtitle: (role?.isNotEmpty ?? false) ? role : null,
          trailing: onProfile == null
              ? null
              : const AppIcon(Icons.chevron_right_rounded),
          onTap: onProfile,
        ),
      ],
      <Widget>[
        if (onProfile != null)
          MenuActionRow(
            icon: Icons.person_outline_rounded,
            label: 'Profile',
            onTap: onProfile,
          ),
        if (onRename != null)
          MenuActionRow(
            icon: Icons.edit_outlined,
            label: 'Rename agent',
            onTap: onRename,
          ),
        if (onControls != null)
          MenuActionRow(
            icon: Icons.tune,
            label: 'Agent controls',
            onTap: onControls,
          ),
        if (onRooms != null)
          MenuActionRow(
            icon: Icons.groups_outlined,
            label: 'Rooms',
            onTap: onRooms,
          ),
        if (onCopyChat != null)
          MenuActionRow(
            icon: Icons.copy_all_rounded,
            label: 'Copy Debug Chat',
            onTap: onCopyChat,
          ),
      ],
      // Parked, like the header target: there is no voice channel to a
      // coworker. The row stays live so a tap can say so; only its colour is
      // dimmed.
      <Widget>[
        MenuActionRow(
          icon: Icons.call_rounded,
          label: 'Voice call',
          subtitle: 'Not available yet',
          tone: scheme.onSurface.withValues(alpha: 0.5),
          onTap: () => pillToast(
            context,
            'Voice calls with a coworker are not available yet',
            icon: Icons.call_end_rounded,
          ),
        ),
      ],
      <Widget>[
        if (onSettings != null)
          MenuActionRow(
            icon: Icons.settings_outlined,
            label: 'Settings',
            onTap: onSettings,
          ),
      ],
      <Widget>[
        if (onSignOut != null)
          MenuActionRow(
            icon: Icons.logout,
            label: 'Sign out',
            tone: scheme.error,
            onTap: onSignOut,
          ),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    // Mounted on its own (not through [show]) the rows still need the sheet's
    // padding and its scroll; inside [showMenuSheet] both come from there.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
      child: MenuTileGroup(
        groups: menuGroups(context),
        color: scheme.surfaceContainerHigh,
      ),
    );
  }
}
