/// The "more" sheet of a phone chat.
///
/// On a wide window the shell shows six icons in its app bar: controls,
/// rooms, browser, copy full chat, settings, sign out. A phone has room for
/// the two that matter in a chat (browser, more); the rest live here, in a
/// bottom sheet that Grok Bot would open from its "…" chip. Every row is a
/// full-width `ListTile` (56 dp), so each is an easy touch target.
///
/// Every callback is optional: a null one hides its row, so the sheet only
/// lists what the shell can actually do for the selected coworker.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/platform_specific/mobile/mobile_presence_avatar.dart';

class MobileAgentSheet extends StatelessWidget {
  const MobileAgentSheet({
    super.key,
    required this.agent,
    this.onControls,
    this.onRooms,
    this.onCopyChat,
    this.onSettings,
    this.onSignOut,
  });

  final CoworkAgent agent;
  final VoidCallback? onControls;
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
    VoidCallback? onControls,
    VoidCallback? onRooms,
    VoidCallback? onCopyChat,
    VoidCallback? onSettings,
    VoidCallback? onSignOut,
  }) {
    return showModalBottomSheet<void>(
      context: context,
      useSafeArea: true,
      showDragHandle: true,
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
          onControls: closeThen(onControls),
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
    final String? role = agent.role?.trim();
    return SafeArea(
      top: false,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: MobilePresenceAvatar(agent: agent, radius: 20),
            title: Text(
              agent.name,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
            subtitle: role == null || role.isEmpty ? null : Text(role),
          ),
          const Divider(height: 1),
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
              title: const Text('Copy full chat'),
              onTap: onCopyChat,
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
    );
  }
}
