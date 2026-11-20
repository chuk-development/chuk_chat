/// The controls a group's settings share between the create sheet and the
/// details panel: "Who answers" ([RoomResponderChoice]) and a member picker
/// for the lead or the fallback member ([RoomMemberPickerRow]).
library;

import 'package:flutter/material.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';
import 'package:chuk_chat/ui/expressive/icon_map.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

/// The localizations of [context], English when the app provides none (a bare
/// widget test).
AppLocalizations roomL10n(BuildContext context) =>
    AppLocalizations.of(context) ?? AppLocalizations(const Locale('en'));

/// The name of a responder mode.
String roomResponderLabel(AgentsRoomResponder r, AppLocalizations l) =>
    switch (r) {
      AgentsRoomResponder.everyone => l.agentsGroupResponderEveryone,
      AgentsRoomResponder.mentions => l.agentsGroupResponderMentions,
      AgentsRoomResponder.auto => l.agentsGroupResponderAuto,
      AgentsRoomResponder.lead => l.agentsGroupResponderLead,
    };

/// The one line that says what a responder mode does.
String roomResponderHint(AgentsRoomResponder r, AppLocalizations l) =>
    switch (r) {
      AgentsRoomResponder.everyone => l.agentsGroupResponderEveryoneHint,
      AgentsRoomResponder.mentions => l.agentsGroupResponderMentionsHint,
      AgentsRoomResponder.auto => l.agentsGroupResponderAutoHint,
      AgentsRoomResponder.lead => l.agentsGroupResponderLeadHint,
    };

IconData _responderIcon(AgentsRoomResponder r) => switch (r) {
  AgentsRoomResponder.everyone => Icons.groups_outlined,
  AgentsRoomResponder.mentions => Icons.alternate_email_rounded,
  AgentsRoomResponder.auto => Icons.auto_awesome_outlined,
  AgentsRoomResponder.lead => Icons.star_outline_rounded,
};

/// "Who answers": the four modes as one group of rows, each with its one-line
/// explanation; the chosen one carries a check.
class RoomResponderChoice extends StatelessWidget {
  const RoomResponderChoice({
    super.key,
    required this.value,
    required this.onChanged,
  });

  final AgentsRoomResponder value;
  final ValueChanged<AgentsRoomResponder> onChanged;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = roomL10n(context);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ExpressiveGroup(
      children: <Widget>[
        for (final AgentsRoomResponder r in AgentsRoomResponder.values)
          ExpressiveRow(
            key: ValueKey<String>('room-responder-${r.wire}'),
            icon: _responderIcon(r),
            title: roomResponderLabel(r, l),
            subtitle: roomResponderHint(r, l),
            onTap: () => onChanged(r),
            trailing: r == value
                ? AppIcon(Icons.check_rounded, size: 20, color: scheme.primary)
                : const SizedBox(width: 20),
          ),
      ],
    );
  }
}

/// A row that picks one member of a group (the lead, the fallback), with
/// "None" first when [allowNone].
class RoomMemberPickerRow extends StatelessWidget {
  const RoomMemberPickerRow({
    super.key,
    required this.title,
    required this.members,
    required this.value,
    required this.onChanged,
    this.agents = const <AgentsAgent>[],
    this.subtitle,
    this.allowNone = true,
  });

  final String title;
  final String? subtitle;
  final List<AgentsRoomMember> members;

  /// For the display names; see [roomMemberName].
  final List<AgentsAgent> agents;

  /// The chosen member's agent id, or null for none.
  final String? value;

  /// Called with the chosen agent id, or with an empty string for "None".
  final ValueChanged<String> onChanged;
  final bool allowNone;

  @override
  Widget build(BuildContext context) {
    final AppLocalizations l = roomL10n(context);
    final String? current = members.any((m) => m.agentId == value)
        ? value
        : null;
    return ExpressiveRow(
      icon: Icons.person_outline,
      title: title,
      subtitle: subtitle,
      titleMaxLines: 2,
      trailing: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          key: ValueKey<String>('room-member-picker-$title'),
          value: current ?? (allowNone ? '' : null),
          isDense: true,
          borderRadius: BorderRadius.circular(16),
          onChanged: (String? id) {
            if (id != null) onChanged(id);
          },
          items: <DropdownMenuItem<String>>[
            if (allowNone)
              DropdownMenuItem<String>(
                value: '',
                child: Text(l.agentsGroupNoMember),
              ),
            for (final AgentsRoomMember m in members)
              DropdownMenuItem<String>(
                value: m.agentId,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    ExpressiveFace(id: m.agentId, label: m.handle, size: 20),
                    const SizedBox(width: 8),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 140),
                      child: Text(
                        roomMemberName(agents, m.agentId, m.handle),
                        overflow: TextOverflow.ellipsis,
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
