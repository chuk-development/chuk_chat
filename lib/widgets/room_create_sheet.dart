/// Create a group room (§16.1): name it, pick two-to-six coworkers.
///
/// The member cap is enforced here in the form — once six are chosen the rest
/// are disabled — so the user never builds a room the host would reject. A room
/// of one is not a room, so Create needs at least two members and a name.
library;

import 'package:flutter/material.dart';

import 'package:cowork/ui/expressive/agent_face.dart';
import 'package:cowork/models/cowork_agent.dart';
import 'package:cowork/models/cowork_room.dart';

class RoomCreateSheet extends StatefulWidget {
  const RoomCreateSheet({
    super.key,
    required this.agents,
    required this.onSubmit,
    this.onCancel,
  });

  /// The coworkers that can join. Usually the roster's visible agents.
  final List<CoworkAgent> agents;

  final void Function(CoworkRoomDraft draft) onSubmit;
  final VoidCallback? onCancel;

  @override
  State<RoomCreateSheet> createState() => _RoomCreateSheetState();
}

class _RoomCreateSheetState extends State<RoomCreateSheet> {
  final TextEditingController _nameController = TextEditingController();
  final Set<String> _selected = <String>{};
  String? _nameError;

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  bool get _full => _selected.length >= kRoomMaxMembers;
  bool get _canCreate =>
      _nameController.text.trim().isNotEmpty && _selected.length >= 2;

  void _toggle(String agentId, bool? on) {
    setState(() {
      if (on == true) {
        // Guard the cap even if a disabled tile is somehow tapped.
        if (_selected.length < kRoomMaxMembers) _selected.add(agentId);
      } else {
        _selected.remove(agentId);
      }
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    setState(() => _nameError = name.isEmpty ? 'Name the room.' : null);
    if (name.isEmpty || _selected.length < 2) return;
    final members = <CoworkRoomMember>[
      for (final agent in widget.agents)
        if (_selected.contains(agent.id))
          CoworkRoomMember(agentId: agent.id, handle: agent.name),
    ];
    widget.onSubmit(CoworkRoomDraft(name: name, members: members));
  }

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
            Text('New room', style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              controller: _nameController,
              decoration: InputDecoration(
                labelText: 'Room name',
                hintText: 'launch planning',
                border: const OutlineInputBorder(),
                isDense: true,
                errorText: _nameError,
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text('Members', style: theme.textTheme.labelLarge),
                ),
                Text(
                  '${_selected.length}/$kRoomMaxMembers',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _full ? theme.colorScheme.primary : theme.hintColor,
                  ),
                ),
              ],
            ),
            if (widget.agents.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No coworkers to add yet.',
                  style: TextStyle(color: theme.hintColor),
                ),
              )
            else
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final agent in widget.agents)
                      _memberTile(context, agent),
                  ],
                ),
              ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onCancel != null)
                  TextButton(
                    onPressed: widget.onCancel,
                    child: const Text('Cancel'),
                  ),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _canCreate ? _submit : null,
                  child: const Text('Create'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _memberTile(BuildContext context, CoworkAgent agent) {
    final selected = _selected.contains(agent.id);
    // A full room disables the unchosen rows, so the cap is a wall, not a warning.
    final enabled = selected || !_full;
    return CheckboxListTile(
      value: selected,
      onChanged: enabled ? (on) => _toggle(agent.id, on) : null,
      controlAffinity: ListTileControlAffinity.leading,
      secondary: ExpressiveFace(id: agent.id, label: agent.name, size: 32),
      title: Text(agent.name, overflow: TextOverflow.ellipsis),
      subtitle: agent.role == null
          ? null
          : Text(agent.role!, overflow: TextOverflow.ellipsis),
      dense: true,
    );
  }
}
