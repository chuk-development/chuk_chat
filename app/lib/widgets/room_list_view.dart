/// The rooms list (§16.1/4c): your group rooms down the side of the messenger,
/// beside the coworker roster.
///
/// One row per room: its name, a stack of its members' avatars, and a member
/// count. Picking a room opens it; the ＋ button starts a new one. Like
/// [AgentRosterView] this is a thin view over a [RoomSource] — it lists what the
/// source holds and never invents a room.
library;

import 'package:flutter/material.dart';

import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/room_source.dart';
import 'package:cowork/widgets/agent_avatar.dart';

class RoomListView extends StatelessWidget {
  const RoomListView({
    super.key,
    required this.source,
    required this.onSelect,
    this.onCreate,
    this.selectedRoomId,
  });

  final RoomSource source;

  /// Called with the room the user picked.
  final void Function(String roomId) onSelect;

  /// Opens the create-room flow. Hidden when null.
  final VoidCallback? onCreate;

  final String? selectedRoomId;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: source,
      builder: (context, _) {
        final rooms = source.rooms;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(context),
            const Divider(height: 1),
            Expanded(
              child: rooms.isEmpty
                  ? _emptyState(context)
                  : ListView.builder(
                      itemCount: rooms.length,
                      itemBuilder: (context, i) => _roomTile(context, rooms[i]),
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _header(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 8, top: 12, bottom: 12),
      child: Row(
        children: [
          Expanded(child: Text('Rooms', style: theme.textTheme.titleSmall)),
          if (onCreate != null)
            IconButton(
              tooltip: 'New room',
              icon: const Icon(Icons.group_add_outlined),
              onPressed: onCreate,
            ),
        ],
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'No rooms yet.',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.hintColor),
            ),
            if (onCreate != null) ...[
              const SizedBox(height: 12),
              FilledButton(
                onPressed: onCreate,
                child: const Text('New room'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _roomTile(BuildContext context, CoworkRoom room) {
    final theme = Theme.of(context);
    final count = room.members.length;
    return ListTile(
      selected: room.id == selectedRoomId,
      leading: _memberStack(room),
      title: Text(room.name, overflow: TextOverflow.ellipsis),
      subtitle: Text(
        count == 1 ? '1 member' : '$count members',
        style: theme.textTheme.bodySmall,
      ),
      onTap: () => onSelect(room.id),
    );
  }

  /// Up to three member avatars, overlapped, with a "+N" chip when the room has
  /// more. A compact identity for the room without listing every handle.
  Widget _memberStack(CoworkRoom room) {
    const shown = 3;
    final members = room.members;
    final visible = members.take(shown).toList();
    final overflow = members.length - visible.length;
    const step = 16.0;
    final width = 32.0 + (visible.length - 1).clamp(0, shown) * step;
    return SizedBox(
      width: width,
      height: 32,
      child: Stack(
        children: [
          for (var i = 0; i < visible.length; i++)
            Positioned(
              left: i * step,
              child: AgentAvatar(
                seed: visible[i].agentId,
                label: visible[i].handle,
                radius: 14,
              ),
            ),
          if (overflow > 0)
            Positioned(
              right: 0,
              bottom: 0,
              child: CircleAvatar(
                radius: 8,
                child: Text('+$overflow', style: const TextStyle(fontSize: 8)),
              ),
            ),
        ],
      ),
    );
  }
}
