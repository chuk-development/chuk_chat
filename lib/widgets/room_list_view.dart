/// The rooms list (§16.1/4c): your group rooms down the side of the messenger,
/// beside the coworker roster.
///
/// One row per room: its name, a stack of its members' avatars, and a member
/// count. Picking a room opens it; the ＋ button starts a new one. Like
/// [AgentRosterView] this is a thin view over a [RoomSource] — it lists what the
/// source holds and never invents a room.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/icon_map.dart';

import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/models/cowork_room.dart';
import 'package:cowork/services/cowork/room_source.dart';
import 'package:cowork/widgets/expressive_settings.dart';

class RoomListView extends StatelessWidget {
  const RoomListView({
    super.key,
    required this.source,
    required this.onSelect,
    this.onCreate,
    this.onDelete,
    this.onRename,
    this.onManageMembers,
    this.selectedRoomId,
  });

  final RoomSource source;

  /// Called with the room the user picked.
  final void Function(String roomId) onSelect;

  /// Opens the create-room flow. Hidden when null.
  final VoidCallback? onCreate;

  /// Deletes a room. When null, no delete affordance is shown.
  final void Function(String roomId)? onDelete;

  /// Renames a room (called with its id and the chosen name). When null, no
  /// rename affordance is shown.
  final void Function(String roomId, String name)? onRename;

  /// Opens member management for a room. When null, no such affordance is shown.
  final void Function(String roomId)? onManageMembers;

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
              icon: const AppIcon(Icons.group_add_outlined),
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
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            if (onCreate != null) ...[
              const SizedBox(height: 12),
              FilledButton(onPressed: onCreate, child: const Text('New room')),
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
      trailing:
          (onDelete == null && onRename == null && onManageMembers == null)
          ? null
          : PopupMenuButton<String>(
              tooltip: 'More',
              icon: const AppIcon(Icons.more_vert, size: 18),
              onSelected: (value) {
                if (value == 'delete') onDelete?.call(room.id);
                if (value == 'rename') _promptRename(context, room);
                if (value == 'members') onManageMembers?.call(room.id);
              },
              itemBuilder: (context) => [
                if (onManageMembers != null)
                  const PopupMenuItem<String>(
                    value: 'members',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: AppIcon(Icons.group_outlined, size: 18),
                      title: Text('Manage members'),
                    ),
                  ),
                if (onRename != null)
                  const PopupMenuItem<String>(
                    value: 'rename',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: AppIcon(Icons.edit_outlined, size: 18),
                      title: Text('Rename room'),
                    ),
                  ),
                if (onDelete != null)
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: AppIcon(Icons.delete_outline, size: 18),
                      title: Text('Delete room'),
                    ),
                  ),
              ],
            ),
      onTap: () => onSelect(room.id),
    );
  }

  Future<void> _promptRename(BuildContext context, CoworkRoom room) async {
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => _RenameDialog(initial: room.name),
    );
    if (name != null && name.trim().isNotEmpty) {
      onRename?.call(room.id, name.trim());
    }
  }

  /// Up to three member avatars, overlapped, followed by a "+N" badge when the
  /// room has more. A compact identity for the room without listing every
  /// handle.
  ///
  /// The count sits BESIDE the stack, never on it. It used to be an 8 px-radius
  /// plaque pinned to the box's bottom-right corner with 8 px text: it landed
  /// on top of the third avatar and was too small to read. A row cannot
  /// overlap, and [ExpressiveBadge] carries the app's own label size, so the
  /// number stays legible when the user scales text up.
  Widget _memberStack(CoworkRoom room) {
    const int shown = 3;
    // The face, the box it sits in, and how far each face is pushed right.
    // 32 px faces in a 36 px box leave a 2 px ring of air top and bottom;
    // stepping 20 px leaves each face 12 px under the one before it.
    const double faceSize = 32;
    const double boxHeight = 36;
    const double overlap = 12;
    const double step = faceSize - overlap;

    final members = room.members;
    final visible = members.take(shown).toList();
    final int overflow = members.length - visible.length;
    final double width = faceSize + (visible.length - 1).clamp(0, shown) * step;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        SizedBox(
          width: width,
          height: boxHeight,
          child: Stack(
            children: [
              for (var i = 0; i < visible.length; i++)
                Positioned(
                  left: i * step,
                  top: (boxHeight - faceSize) / 2,
                  child: ExpressiveFace(
                    id: visible[i].agentId,
                    label: visible[i].handle,
                    size: faceSize,
                  ),
                ),
            ],
          ),
        ),
        if (overflow > 0) ...[
          const SizedBox(width: 8),
          ExpressiveBadge('+$overflow'),
        ],
      ],
    );
  }
}

/// The rename dialog. A StatefulWidget so it owns and disposes its own text
/// controller — disposing one during the dialog's exit animation, from a
/// stateless helper, throws "used after disposed".
class _RenameDialog extends StatefulWidget {
  const _RenameDialog({required this.initial});

  final String initial;

  @override
  State<_RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<_RenameDialog> {
  late final TextEditingController _controller = TextEditingController(
    text: widget.initial,
  );

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename room'),
      content: TextField(
        controller: _controller,
        autofocus: true,
        decoration: const InputDecoration(labelText: 'Room name'),
        onSubmitted: (v) => Navigator.of(context).pop(v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(_controller.text),
          child: const Text('Rename'),
        ),
      ],
    );
  }
}
