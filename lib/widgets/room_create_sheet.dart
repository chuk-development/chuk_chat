/// Create a group room (§16.1): name it, pick the coworkers, choose whether
/// they may answer each other.
///
/// There is no member ceiling. A room takes as many coworkers as the roster
/// holds, so the picker is built for a long list: the name field, the policy
/// switch and the actions stay put while only the member list scrolls, and a
/// search field appears once the roster is longer than the eye can scan.
///
/// A room of one is not a room, so Create still needs a name and at least two
/// members.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// Above this many candidates the list stops being scannable, so the sheet
/// offers a search field. Below it the field would be one more empty box.
const int kRoomSearchThreshold = 8;

class RoomCreateSheet extends StatefulWidget {
  const RoomCreateSheet({
    super.key,
    required this.agents,
    required this.onSubmit,
    this.onCancel,
  });

  /// The coworkers that can join. Usually the roster's visible agents.
  final List<AgentsAgent> agents;

  final void Function(AgentsRoomDraft draft) onSubmit;
  final VoidCallback? onCancel;

  @override
  State<RoomCreateSheet> createState() => _RoomCreateSheetState();
}

class _RoomCreateSheetState extends State<RoomCreateSheet> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final Set<String> _selected = <String>{};
  String? _nameError;
  bool _agentToAgent = true;

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    super.dispose();
  }

  bool get _canCreate =>
      _nameController.text.trim().isNotEmpty && _selected.length >= 2;

  /// Whether the roster is long enough to earn a search field.
  bool get _searchable => widget.agents.length > kRoomSearchThreshold;

  /// The candidates the search field leaves visible. The selection is kept on
  /// ids, not on this list, so filtering never drops a chosen coworker.
  List<AgentsAgent> get _visible {
    final query = _searchController.text.trim().toLowerCase();
    if (!_searchable || query.isEmpty) return widget.agents;
    return <AgentsAgent>[
      for (final agent in widget.agents)
        if (agent.name.toLowerCase().contains(query) ||
            (agent.role?.toLowerCase().contains(query) ?? false))
          agent,
    ];
  }

  void _toggle(String agentId, bool? on) {
    setState(() {
      if (on == true) {
        _selected.add(agentId);
      } else {
        _selected.remove(agentId);
      }
    });
  }

  void _submit() {
    final name = _nameController.text.trim();
    setState(() => _nameError = name.isEmpty ? 'Name the room.' : null);
    if (name.isEmpty || _selected.length < 2) return;
    // Built from the full roster in roster order, not from the filtered view,
    // so a search left up at Create cannot drop a chosen member.
    final members = <AgentsRoomMember>[
      for (final agent in widget.agents)
        if (_selected.contains(agent.id))
          AgentsRoomMember(agentId: agent.id, handle: agent.name),
    ];
    widget.onSubmit(
      AgentsRoomDraft(
        name: name,
        members: members,
        agentToAgent: _agentToAgent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final visible = _visible;
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
                  '${_selected.length} selected',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _selected.isEmpty
                        ? theme.hintColor
                        : theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            if (_searchable) ...[
              const SizedBox(height: 8),
              TextField(
                controller: _searchController,
                decoration: const InputDecoration(
                  hintText: 'Search coworkers',
                  border: OutlineInputBorder(),
                  isDense: true,
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
            if (widget.agents.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No coworkers to add yet.',
                  style: TextStyle(color: theme.hintColor),
                ),
              )
            else if (visible.isEmpty)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  'No coworker matches that.',
                  style: TextStyle(color: theme.hintColor),
                ),
              )
            else
              // Only the member list scrolls: the name field, the policy switch
              // and the actions stay where the finger left them however long
              // the roster is.
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: [
                    for (final agent in visible) _memberTile(context, agent),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            ExpressiveGroup(
              children: [
                ExpressiveSwitchRow(
                  key: const ValueKey<String>('room-agent-to-agent'),
                  title: 'Coworkers can reply to each other',
                  subtitle: 'With this off, they only answer you.',
                  value: _agentToAgent,
                  onChanged: (on) => setState(() => _agentToAgent = on),
                ),
              ],
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

  Widget _memberTile(BuildContext context, AgentsAgent agent) {
    final selected = _selected.contains(agent.id);
    return CheckboxListTile(
      value: selected,
      onChanged: (on) => _toggle(agent.id, on),
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
