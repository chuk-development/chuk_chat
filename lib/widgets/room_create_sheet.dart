/// Create a group (§16.1): name it, pick the agents, choose who answers
/// (everyone, only the @named, auto, or a lead), whether they may answer each
/// other, and optional group instructions.
///
/// There is no member ceiling. A group takes as many agents as the roster
/// holds, so the picker is built for a long list: the title and the actions
/// stay put while the form scrolls, and a search field appears once the
/// roster is longer than the eye can scan.
///
/// A room of one is not a room, so Create still needs a name and at least two
/// members.
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/room_settings_controls.dart';

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

  /// The agents that can join. Usually the roster's visible agents.
  final List<AgentsAgent> agents;

  final void Function(AgentsRoomDraft draft) onSubmit;
  final VoidCallback? onCancel;

  @override
  State<RoomCreateSheet> createState() => _RoomCreateSheetState();
}

class _RoomCreateSheetState extends State<RoomCreateSheet> {
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _bulletinController = TextEditingController();
  final Set<String> _selected = <String>{};
  String? _nameError;
  bool _agentToAgent = true;
  AgentsRoomResponder _responder = AgentsRoomResponder.everyone;
  String? _leadId;

  @override
  void dispose() {
    _nameController.dispose();
    _searchController.dispose();
    _bulletinController.dispose();
    super.dispose();
  }

  bool get _canCreate =>
      _nameController.text.trim().isNotEmpty && _selected.length >= 2;

  /// Whether the roster is long enough to earn a search field.
  bool get _searchable => widget.agents.length > kRoomSearchThreshold;

  /// The candidates the search field leaves visible. The selection is kept on
  /// ids, not on this list, so filtering never drops a chosen agent.
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

  /// The chosen members, in roster order — built from the full roster, not
  /// from the filtered view, so a search left up cannot drop a chosen member.
  List<AgentsRoomMember> get _members => <AgentsRoomMember>[
    for (final agent in widget.agents)
      if (_selected.contains(agent.id))
        AgentsRoomMember(agentId: agent.id, handle: agent.name),
  ];

  /// The lead for lead mode: the one picked, else the first chosen member.
  String? get _effectiveLead {
    final members = _members;
    if (members.isEmpty) return null;
    if (members.any((m) => m.agentId == _leadId)) return _leadId;
    return members.first.agentId;
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
    final l = roomL10n(context);
    final name = _nameController.text.trim();
    setState(() => _nameError = name.isEmpty ? l.agentsGroupNameMissing : null);
    if (name.isEmpty || _selected.length < 2) return;
    final bulletin = _bulletinController.text.trim();
    widget.onSubmit(
      AgentsRoomDraft(
        name: name,
        members: _members,
        agentToAgent: _agentToAgent,
        responder: _responder,
        leadAgentId: _responder == AgentsRoomResponder.lead
            ? _effectiveLead
            : null,
        bulletin: bulletin.length > kRoomBulletinMaxChars
            ? bulletin.substring(0, kRoomBulletinMaxChars)
            : bulletin,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l = roomL10n(context);
    final visible = _visible;
    final members = _members;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(l.agentsGroupNew, style: theme.textTheme.titleMedium),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey<String>('room-create-name'),
              controller: _nameController,
              decoration: InputDecoration(
                labelText: l.agentsGroupName,
                hintText: l.agentsGroupNameHint,
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
                  child: Text(
                    l.agentsGroupMembers,
                    style: theme.textTheme.labelLarge,
                  ),
                ),
                Text(
                  l.agentsGroupSelected('${_selected.length}'),
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: _selected.isEmpty
                        ? theme.hintColor
                        : theme.colorScheme.primary,
                  ),
                ),
              ],
            ),
            // The rest of the form scrolls; the title, the name, the count
            // and the actions stay where the finger left them however long
            // the roster is.
            Flexible(
              child: ListView(
                shrinkWrap: true,
                children: [
                  if (_searchable) ...[
                    const SizedBox(height: 8),
                    TextField(
                      controller: _searchController,
                      decoration: InputDecoration(
                        hintText: l.agentsGroupSearchAgents,
                        border: const OutlineInputBorder(),
                        isDense: true,
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ],
                  if (widget.agents.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        l.agentsGroupNoAgents,
                        style: TextStyle(color: theme.hintColor),
                      ),
                    )
                  else if (visible.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      child: Text(
                        l.agentsGroupNoMatch,
                        style: TextStyle(color: theme.hintColor),
                      ),
                    )
                  else
                    for (final agent in visible) _memberTile(context, agent),
                  const SizedBox(height: 16),
                  Text(
                    l.agentsGroupWhoAnswers,
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 8),
                  RoomResponderChoice(
                    value: _responder,
                    onChanged: (r) => setState(() => _responder = r),
                  ),
                  if (_responder == AgentsRoomResponder.lead &&
                      members.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    ExpressiveGroup(
                      children: [
                        RoomMemberPickerRow(
                          key: const ValueKey<String>('room-create-lead'),
                          title: l.agentsGroupLeadMember,
                          members: members,
                          agents: widget.agents,
                          value: _effectiveLead,
                          allowNone: false,
                          onChanged: (id) => setState(() => _leadId = id),
                        ),
                      ],
                    ),
                  ],
                  const SizedBox(height: 12),
                  ExpressiveGroup(
                    children: [
                      ExpressiveSwitchRow(
                        key: const ValueKey<String>('room-agent-to-agent'),
                        title: l.agentsGroupAgentToAgent,
                        subtitle: l.agentsGroupAgentToAgentHint,
                        value: _agentToAgent,
                        onChanged: (on) => setState(() => _agentToAgent = on),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    key: const ValueKey<String>('room-create-instructions'),
                    controller: _bulletinController,
                    minLines: 2,
                    maxLines: 6,
                    maxLength: kRoomBulletinMaxChars,
                    buildCounter: (
                      BuildContext context, {
                      required int currentLength,
                      required bool isFocused,
                      required int? maxLength,
                    }) => null,
                    decoration: InputDecoration(
                      labelText: l.agentsGroupInstructions,
                      hintText: l.agentsGroupInstructionsHint,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (widget.onCancel != null)
                  TextButton(onPressed: widget.onCancel, child: Text(l.cancel)),
                const SizedBox(width: 8),
                FilledButton(
                  onPressed: _canCreate ? _submit : null,
                  child: Text(l.agentsGroupCreate),
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
    final role = agent.role;
    return CheckboxListTile(
      value: selected,
      onChanged: (on) => _toggle(agent.id, on),
      controlAffinity: ListTileControlAffinity.leading,
      secondary: ExpressiveFace(id: agent.id, label: agent.name, size: 32),
      title: Text(agent.name, overflow: TextOverflow.ellipsis),
      subtitle: role == null
          ? null
          : Text(role, overflow: TextOverflow.ellipsis),
      dense: true,
    );
  }
}
