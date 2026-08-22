/// Manage a room's members (§16.1): remove one, or add a coworker from the
/// roster. Enforces the same bounds the rest of the app does — at most
/// [kRoomMaxMembers], never fewer than two (a room of one is not a room), so
/// Remove is disabled at two and Add is disabled at six.
///
/// The sheet is a pure view over what it is given: the room and the candidates
/// (roster agents not already in it). Add/remove go out through callbacks; the
/// caller updates the room source and tells the host.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/widgets/agent_avatar.dart';

class RoomMembersSheet extends StatelessWidget {
  const RoomMembersSheet({
    super.key,
    required this.room,
    required this.candidates,
    required this.onAdd,
    required this.onRemove,
  });

  final CoworkRoom room;

  /// Roster agents not already in the room, offered to add.
  final List<CoworkAgent> candidates;

  final void Function(CoworkRoomMember member) onAdd;
  final void Function(String agentId) onRemove;

  bool get _full => room.members.length >= kRoomMaxMembers;
  bool get _atMinimum => room.members.length <= 2;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
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
                    color: _full ? theme.colorScheme.primary : theme.hintColor,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text('Members', style: theme.textTheme.labelLarge),
            for (final m in room.members)
              ListTile(
                dense: true,
                leading: AgentAvatar(seed: m.agentId, label: m.handle, radius: 14),
                title: Text('@${m.handle}', overflow: TextOverflow.ellipsis),
                trailing: IconButton(
                  tooltip: _atMinimum
                      ? 'A room needs at least two members'
                      : 'Remove',
                  icon: const Icon(Icons.remove_circle_outline, size: 20),
                  onPressed: _atMinimum ? null : () => onRemove(m.agentId),
                ),
              ),
            const SizedBox(height: 12),
            Text('Add a coworker', style: theme.textTheme.labelLarge),
            if (candidates.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Text(
                  'No other coworkers to add.',
                  style: TextStyle(color: theme.hintColor),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final agent in candidates)
                      ListTile(
                        dense: true,
                        leading: AgentAvatar(
                          seed: agent.id,
                          label: agent.name,
                          radius: 14,
                        ),
                        title: Text(agent.name, overflow: TextOverflow.ellipsis),
                        trailing: IconButton(
                          tooltip: _full ? 'The room is full' : 'Add',
                          icon: const Icon(Icons.add_circle_outline, size: 20),
                          onPressed: _full
                              ? null
                              : () => onAdd(
                                    CoworkRoomMember(
                                      agentId: agent.id,
                                      handle: agent.name,
                                    ),
                                  ),
                        ),
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
