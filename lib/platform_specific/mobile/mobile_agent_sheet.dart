/// The "more" sheet of a phone chat.
///
/// On a wide window the shell shows six icons in its app bar: controls,
/// rooms, browser, copy full chat, settings, sign out. A phone has room for
/// the three that matter in a chat (the parked call, the browser, more); the
/// rest live here, in a bottom sheet the "…" target opens. Every row is a
/// full-width `ListTile` (56 dp), so each is an easy touch target.
///
/// The header is the coworker's blob face, its name and its role — the same
/// identity the inbox row and the chat pill show.
///
/// Every callback is optional: a null one hides its row, so the sheet only
/// lists what the shell can actually do for the selected coworker.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/services/cowork/agent_profile_store.dart';
import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/ui/expressive/feedback.dart';

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

  final CoworkAgent agent;

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
    required CoworkAgent agent,
    VoidCallback? onProfile,
    VoidCallback? onControls,
    VoidCallback? onRename,
    VoidCallback? onRooms,
    VoidCallback? onCopyChat,
    VoidCallback? onSettings,
    VoidCallback? onSignOut,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
      // The expressive sheet shape: big top corners, like every other sheet in
      // the redesigned UI.
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(36)),
      ),
      builder: (BuildContext sheetContext) {
        VoidCallback? closeThen(VoidCallback? action) {
          if (action == null) return null;
          return () {
            Navigator.of(sheetContext).pop();
            action();
          };
        }

        return MobileAgentSheet(
          agent: agent,
          onProfile: closeThen(onProfile),
          onControls: closeThen(onControls),
          onRename: closeThen(onRename),
          onRooms: closeThen(onRooms),
          onCopyChat: closeThen(onCopyChat),
          onSettings: closeThen(onSettings),
          onSignOut: closeThen(onSignOut),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final AgentProfile profile = AgentProfileStore.instance.profileOf(agent.id);
    final String? role = (profile.role?.trim().isNotEmpty ?? false)
        ? profile.role!.trim()
        : agent.role?.trim();
    return SafeArea(
      top: false,
      // The sheet scrolls: with the profile row and the parked call the list is
      // taller than a small phone leaves for a bottom sheet.
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: AgentFace(agent: agent, size: 44),
              title: Text(
                agent.name,
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              subtitle: role == null || role.isEmpty ? null : Text(role),
              trailing: onProfile == null
                  ? null
                  : const Icon(Icons.chevron_right_rounded),
              onTap: onProfile,
            ),
            const Divider(height: 1),
            if (onProfile != null)
              ListTile(
                leading: const Icon(Icons.person_outline_rounded),
                title: const Text('Profile'),
                onTap: onProfile,
              ),
            if (onRename != null)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Rename agent'),
                onTap: onRename,
              ),
            if (onControls != null)
              ListTile(
                leading: const Icon(Icons.tune),
                title: const Text('Agent controls'),
                onTap: onControls,
              ),
            if (onRooms != null)
              ListTile(
                leading: const Icon(Icons.groups_outlined),
                title: const Text('Rooms'),
                onTap: onRooms,
              ),
            if (onCopyChat != null)
              ListTile(
                leading: const Icon(Icons.copy_all_rounded),
                title: const Text('Copy Debug Chat'),
                onTap: onCopyChat,
              ),
            // Parked, like the header target: there is no voice channel to a
            // coworker, and the row says so instead of hiding the idea.
            ListTile(
              leading: Icon(
                Icons.call_rounded,
                color: theme.colorScheme.onSurface.withValues(alpha: 0.38),
              ),
              title: Text(
                'Voice call',
                style: TextStyle(
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
              subtitle: const Text('Not available yet'),
              onTap: () => pillToast(
                context,
                'Voice calls with a coworker are not available yet',
                icon: Icons.call_end_rounded,
              ),
            ),
            if (onSettings != null)
              ListTile(
                leading: const Icon(Icons.settings_outlined),
                title: const Text('Settings'),
                onTap: onSettings,
              ),
            if (onSignOut != null)
              ListTile(
                leading: Icon(Icons.logout, color: theme.colorScheme.error),
                title: Text(
                  'Sign out',
                  style: TextStyle(color: theme.colorScheme.error),
                ),
                onTap: onSignOut,
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }
}
