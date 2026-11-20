/// A group's details, the way an agent has its details (§16.1): the members
/// (remove, add), who answers (with the lead or the fallback member), whether
/// the agents may answer each other, the group instructions and the shared
/// folder.
///
/// The desktop shows it in the right pane while a group is open; the phone
/// opens it as a page from the group's header. It follows [source], so a
/// change from the host (`room_list`) shows at once. Settings change the local
/// copy first ([RoomSource.updateRoomSettings]) and then go to the host
/// through [onSettingsChanged] (`room_settings`); members and the policy
/// switch go through the shell's own callbacks, which already keep the host
/// in step (`room_add_member`, `room_remove_member`,
/// `room_set_agent_to_agent`).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/room_source.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/room_faces.dart';
import 'package:chuk_chat/widgets/room_settings_controls.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

class RoomDetailsPanel extends StatefulWidget {
  const RoomDetailsPanel({
    super.key,
    required this.source,
    required this.roomId,
    required this.onSettingsChanged,
    this.agents = const <AgentsAgent>[],
    this.onAddMember,
    this.onRemoveMember,
    this.onAgentToAgentChanged,
  });

  final RoomSource source;
  final String roomId;

  /// The roster: display names, and the agents that can still join.
  final List<AgentsAgent> agents;

  /// Sends the changed settings to the host (`room_settings`); the keys are
  /// the wire's (`responder`, `lead_agent_id`, `fallback_agent_id`,
  /// `bulletin`, `workdir`). The local copy is already updated.
  final void Function(String roomId, Map<String, Object?> settings)
  onSettingsChanged;

  final void Function(String roomId, AgentsRoomMember member)? onAddMember;
  final void Function(String roomId, String agentId)? onRemoveMember;
  final void Function(String roomId, bool enabled)? onAgentToAgentChanged;

  @override
  State<RoomDetailsPanel> createState() => _RoomDetailsPanelState();
}

class _RoomDetailsPanelState extends State<RoomDetailsPanel> {
  final TextEditingController _bulletin = TextEditingController();
  final TextEditingController _workdir = TextEditingController();

  // The stored values the fields were last filled from. A field still showing
  // its stored value follows a change from the host; an edited one is kept.
  String? _bulletinBase;
  String? _workdirBase;

  @override
  void initState() {
    super.initState();
    _syncFromSource();
    widget.source.addListener(_syncFromSource);
    _bulletin.addListener(_onFieldChanged);
    _workdir.addListener(_onFieldChanged);
  }

  @override
  void didUpdateWidget(RoomDetailsPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.source != widget.source) {
      oldWidget.source.removeListener(_syncFromSource);
      widget.source.addListener(_syncFromSource);
    }
    if (oldWidget.roomId != widget.roomId) {
      _bulletinBase = null;
      _workdirBase = null;
    }
    _syncFromSource();
  }

  @override
  void dispose() {
    widget.source.removeListener(_syncFromSource);
    _bulletin.dispose();
    _workdir.dispose();
    super.dispose();
  }

  void _onFieldChanged() {
    if (mounted) setState(() {});
  }

  void _syncFromSource() {
    final AgentsRoom? room = widget.source.byId(widget.roomId);
    if (room != null) _syncFields(room);
  }

  void _syncFields(AgentsRoom room) {
    if (_bulletinBase == null || _bulletin.text == _bulletinBase) {
      if (_bulletin.text != room.bulletin) _bulletin.text = room.bulletin;
      _bulletinBase = room.bulletin;
    }
    if (_workdirBase == null || _workdir.text == _workdirBase) {
      if (_workdir.text != room.workdir) _workdir.text = room.workdir;
      _workdirBase = room.workdir;
    }
  }

  void _change(
    AgentsRoom room, {
    AgentsRoomResponder? responder,
    String? leadAgentId,
    String? fallbackAgentId,
    String? bulletin,
    String? workdir,
  }) {
    widget.source.updateRoomSettings(
      room.id,
      responder: responder,
      leadAgentId: leadAgentId,
      fallbackAgentId: fallbackAgentId,
      bulletin: bulletin,
      workdir: workdir,
    );
    widget.onSettingsChanged(room.id, <String, Object?>{
      if (responder != null) 'responder': responder.wire,
      if (leadAgentId != null)
        'lead_agent_id': leadAgentId.isEmpty ? null : leadAgentId,
      if (fallbackAgentId != null)
        'fallback_agent_id': fallbackAgentId.isEmpty ? null : fallbackAgentId,
      'bulletin': ?bulletin,
      'workdir': ?workdir,
    });
  }

  void _pickResponder(AgentsRoom room, AgentsRoomResponder r) {
    if (r == room.responder) return;
    // Lead mode needs a lead: take the first member when none is set yet, so
    // the host never runs lead mode without one.
    final bool needsLead =
        r == AgentsRoomResponder.lead &&
        room.memberById(room.leadAgentId) == null &&
        room.members.isNotEmpty;
    _change(
      room,
      responder: r,
      leadAgentId: needsLead ? room.members.first.agentId : null,
    );
  }

  void _saveTexts(AgentsRoom room) {
    final String bulletin = _bulletin.text.trim();
    final String workdir = _workdir.text.trim();
    final bool bulletinChanged = bulletin != room.bulletin;
    final bool workdirChanged = workdir != room.workdir;
    if (!bulletinChanged && !workdirChanged) return;
    _bulletinBase = bulletin;
    _workdirBase = workdir;
    _change(
      room,
      bulletin: bulletinChanged
          ? (bulletin.length > kRoomBulletinMaxChars
                ? bulletin.substring(0, kRoomBulletinMaxChars)
                : bulletin)
          : null,
      workdir: workdirChanged ? workdir : null,
    );
    FocusScope.of(context).unfocus();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.source,
      builder: (BuildContext context, _) {
        final AgentsRoom? room = widget.source.byId(widget.roomId);
        if (room == null) return const SizedBox.shrink();
        return _body(context, room);
      },
    );
  }

  Widget _body(BuildContext context, AgentsRoom room) {
    final ThemeData theme = Theme.of(context);
    final AppLocalizations l = roomL10n(context);
    final Set<String> inRoom = <String>{
      for (final AgentsRoomMember m in room.members) m.agentId,
    };
    final List<AgentsAgent> candidates = <AgentsAgent>[
      for (final AgentsAgent a in widget.agents)
        if (!inRoom.contains(a.id)) a,
    ];
    final bool canRemove = room.members.length > 2;
    final void Function(String, String)? onRemove = widget.onRemoveMember;
    final void Function(String, AgentsRoomMember)? onAdd = widget.onAddMember;
    final void Function(String, bool)? onPolicy = widget.onAgentToAgentChanged;
    final bool textsDirty =
        _bulletin.text.trim() != room.bulletin ||
        _workdir.text.trim() != room.workdir;

    return ListView(
      padding: EdgeInsets.fromLTRB(
        16,
        16 + MediaQuery.paddingOf(context).top,
        16,
        24,
      ),
      children: <Widget>[
        Center(child: RoomFaces(members: room.members, size: 56)),
        const SizedBox(height: 8),
        Text(
          room.name,
          textAlign: TextAlign.center,
          style: theme.textTheme.titleMedium?.copyWith(
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 16),
        ExpressiveSectionHeader(l.agentsGroupMembers),
        ExpressiveGroup(
          children: <Widget>[
            for (final AgentsRoomMember m in room.members)
              ExpressiveRow(
                key: ValueKey<String>('room-details-member-${m.agentId}'),
                leading: ExpressiveFace(
                  id: m.agentId,
                  label: m.handle,
                  size: 36,
                ),
                title: roomMemberName(widget.agents, m.agentId, m.handle),
                subtitle: '@${m.handle}',
                trailing: onRemove == null
                    ? null
                    : IconButton(
                        tooltip: canRemove
                            ? l.agentsGroupRemoveMember
                            : l.agentsGroupMinMembers,
                        icon: const AppIcon(Icons.remove_circle_outline),
                        onPressed: canRemove
                            ? () => onRemove(room.id, m.agentId)
                            : null,
                      ),
              ),
          ],
        ),
        if (onAdd != null && candidates.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          ExpressiveSectionHeader(l.agentsGroupAddMember),
          ExpressiveGroup(
            children: <Widget>[
              for (final AgentsAgent a in candidates)
                ExpressiveRow(
                  key: ValueKey<String>('room-details-add-${a.id}'),
                  leading: ExpressiveFace(id: a.id, label: a.name, size: 36),
                  title: a.name,
                  subtitle: a.role,
                  onTap: () => onAdd(
                    room.id,
                    AgentsRoomMember(agentId: a.id, handle: a.name),
                  ),
                  trailing: AppIcon(
                    Icons.add_circle_outline,
                    color: theme.colorScheme.primary,
                  ),
                ),
            ],
          ),
        ],
        const SizedBox(height: 16),
        ExpressiveSectionHeader(l.agentsGroupWhoAnswers),
        RoomResponderChoice(
          value: room.responder,
          onChanged: (AgentsRoomResponder r) => _pickResponder(room, r),
        ),
        if (room.responder == AgentsRoomResponder.lead) ...<Widget>[
          const SizedBox(height: 8),
          ExpressiveGroup(
            children: <Widget>[
              RoomMemberPickerRow(
                key: const ValueKey<String>('room-details-lead'),
                title: l.agentsGroupLeadMember,
                members: room.members,
                agents: widget.agents,
                value: room.leadAgentId ?? room.members.first.agentId,
                allowNone: false,
                onChanged: (String id) => _change(room, leadAgentId: id),
              ),
            ],
          ),
        ],
        if (room.responder == AgentsRoomResponder.auto) ...<Widget>[
          const SizedBox(height: 8),
          ExpressiveGroup(
            children: <Widget>[
              RoomMemberPickerRow(
                key: const ValueKey<String>('room-details-fallback'),
                title: l.agentsGroupFallbackMember,
                subtitle: l.agentsGroupFallbackHint,
                members: room.members,
                agents: widget.agents,
                value: room.fallbackAgentId,
                onChanged: (String id) => _change(room, fallbackAgentId: id),
              ),
            ],
          ),
        ],
        const SizedBox(height: 12),
        ExpressiveGroup(
          children: <Widget>[
            ExpressiveSwitchRow(
              key: const ValueKey<String>('room-details-a2a'),
              icon: Icons.forum_outlined,
              title: l.agentsGroupAgentToAgent,
              subtitle: l.agentsGroupAgentToAgentHint,
              value: room.agentToAgent,
              onChanged: onPolicy == null
                  ? null
                  : (bool on) => onPolicy(room.id, on),
            ),
          ],
        ),
        const SizedBox(height: 16),
        ExpressiveSectionHeader(l.agentsGroupInstructions),
        TextField(
          key: const ValueKey<String>('room-details-instructions'),
          controller: _bulletin,
          minLines: 3,
          maxLines: 10,
          maxLength: kRoomBulletinMaxChars,
          buildCounter: (
            BuildContext context, {
            required int currentLength,
            required bool isFocused,
            required int? maxLength,
          }) => null,
          decoration: InputDecoration(
            hintText: l.agentsGroupInstructionsHint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
        const SizedBox(height: 16),
        ExpressiveSectionHeader(l.agentsGroupSharedFolder),
        TextField(
          key: const ValueKey<String>('room-details-workdir'),
          controller: _workdir,
          decoration: InputDecoration(
            hintText: l.agentsGroupSharedFolderHint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _saveTexts(room),
        ),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerRight,
          child: FilledButton.tonal(
            key: const ValueKey<String>('room-details-save'),
            onPressed: textsDirty ? () => _saveTexts(room) : null,
            child: Text(l.agentsGroupSave),
          ),
        ),
      ],
    );
  }
}
