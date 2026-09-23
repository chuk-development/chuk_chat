/// Manage a room's members (§16.1): remove one, or add a coworker from the
/// roster. Enforces the same bounds the rest of the app does — at most
/// [kRoomMaxMembers], never fewer than two (a room of one is not a room), so
/// Remove is disabled at two and Add is disabled at six.
///
/// The sheet is a pure view over what it is given: the room and the candidates
/// (roster agents not already in it). Add/remove go out through callbacks; the
/// caller updates the room source and tells the host.
///
/// Everything below the title scrolls. The sheet carries two lists — the
/// members and the candidates to add — and a bare `Column` of rows ran off the
/// bottom of a short phone as soon as a room had about six members. One
/// `Flexible` `ListView` holds both sections, and its bottom padding carries
/// the keyboard inset so the last row stays reachable while a keyboard is up.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/icon_map.dart';

import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

class RoomMembersSheet extends StatelessWidget {
  const RoomMembersSheet({
    super.key,
    required this.room,
    required this.candidates,
    required this.onAdd,
    required this.onRemove,
  });

  final AgentsRoom room;

  /// Roster agents not already in the room, offered to add.
  final List<AgentsAgent> candidates;

  final void Function(AgentsRoomMember member) onAdd;
  final void Function(String agentId) onRemove;

  bool get _full => room.members.length >= kRoomMaxMembers;
  bool get _atMinimum => room.members.length <= 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final cs = theme.colorScheme;
    final double keyboard = MediaQuery.viewInsetsOf(context).bottom;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(room.name, style: theme.textTheme.titleMedium),
                ),
                Text(
                  '${room.members.length}/$kRoomMaxMembers',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _full ? cs.primary : cs.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView(
                // The keyboard inset rides at the bottom of the scroll view:
                // the candidate list can sit under an open keyboard.
                padding: EdgeInsets.only(bottom: keyboard),
                children: [
                  Text('Members', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  ExpressiveGroup(
                    children: [
                      for (final m in room.members)
                        ExpressiveRow(
                          key: ValueKey<String>('room-member-${m.agentId}'),
                          title: '@${m.handle}',
                          leading: ExpressiveFace(
                            id: m.agentId,
                            label: m.handle,
                            size: 28,
                          ),
                          trailing: IconButton(
                            tooltip: _atMinimum
                                ? 'A room needs at least two members'
                                : 'Remove',
                            icon: const AppIcon(
                              Icons.remove_circle_outline,
                              size: 20,
                            ),
                            onPressed: _atMinimum
                                ? null
                                : () => onRemove(m.agentId),
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text('Add a coworker', style: theme.textTheme.labelLarge),
                  const SizedBox(height: 6),
                  if (candidates.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        'No other coworkers to add.',
                        style: theme.textTheme.bodyMedium?.copyWith(
                          color: cs.onSurfaceVariant,
                        ),
                      ),
                    )
                  else
                    ExpressiveGroup(
                      children: [
                        for (final agent in candidates)
                          ExpressiveRow(
                            key: ValueKey<String>('room-candidate-${agent.id}'),
                            title: agent.name,
                            leading: ExpressiveFace(
                              id: agent.id,
                              label: agent.name,
                              size: 28,
                            ),
                            trailing: IconButton(
                              tooltip: _full ? 'The room is full' : 'Add',
                              icon: const AppIcon(
                                Icons.add_circle_outline,
                                size: 20,
                              ),
                              onPressed: _full
                                  ? null
                                  : () => onAdd(
                                      AgentsRoomMember(
                                        agentId: agent.id,
                                        handle: agent.name,
                                      ),
                                    ),
                            ),
                          ),
                      ],
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
