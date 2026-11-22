// lib/services/agents/agents_room_hosts.dart
//
// Groups with members on several computers (CHAT-177 phase 2,
// docs/WIRE_CONTRACT.md "Groups with members on several hosts").
//
// A group lives on one computer, its home host. A member of another computer
// is sent with its `host_id`; the home host runs that member's turn with a
// peer `task` on the member's computer. The rules the app keeps:
//
//  * Agent ids on the wire are the ids the agent's OWN host knows. The app
//    calls a computer's own agent `host:cowork-host@<hostId>` (only the
//    computer from before CHAT-177 keeps `host:cowork-host`), but every host
//    calls its own agent `host:cowork-host`. So that alias is cut back on the
//    wire, and a turn that comes back with `host:cowork-host` is the group's
//    one host-own member.
//  * The host room store keys members by agent id, so two computers' own
//    agents can never be in one group: both are `host:cowork-host` there.
//  * Members on two or more computers need every one of those computers to
//    name `host_peers` (the home host sends the peer tasks, the member's host
//    answers them).
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';

abstract final class AgentsRoomHosts {
  static const String _hostAgentPrefix = 'host:';

  /// Whether [agentId] is a computer's own agent (not one the app made).
  static bool isHostOwnAgent(String agentId) =>
      agentId.startsWith(_hostAgentPrefix);

  /// The id [appAgentId] has on its own host: a computer's own agent loses
  /// the app's `@<hostId>` suffix, every other id stays.
  static String wireAgentId(String appAgentId) {
    if (!isHostOwnAgent(appAgentId)) return appAgentId;
    final int at = appAgentId.indexOf('@');
    return at < 0 ? appAgentId : appAgentId.substring(0, at);
  }

  /// The computer of [member] in a group that lives on [homeHostId].
  static String? memberHost(AgentsRoomMember member, String? homeHostId) =>
      member.hostId ?? homeHostId;

  /// One `room_create.members[]` entry / the `room_add_member` keys: the wire
  /// id, the handle, and `host_id` only for a member of another computer.
  static Map<String, String> wireMember(
    AgentsRoomMember member,
    String? homeHostId,
  ) {
    final String? host = member.hostId;
    return <String, String>{
      'agent_id': wireAgentId(member.agentId),
      'handle': member.handle,
      if (host != null && host.isNotEmpty && host != homeHostId)
        'host_id': host,
    };
  }

  /// [wireMember] for every member, in group order.
  static List<Map<String, String>> wireMembers(
    List<AgentsRoomMember> members,
    String? homeHostId,
  ) => <Map<String, String>>[
    for (final AgentsRoomMember m in members) wireMember(m, homeHostId),
  ];

  /// The app's id for an agent id the home host sent in a turn of a group
  /// with [members]. A member id is itself; a host-own id
  /// (`host:cowork-host`) is the group's one host-own member.
  static String appAgentIdIn(List<AgentsRoomMember> members, String wireId) {
    if (wireId.isEmpty || !isHostOwnAgent(wireId)) return wireId;
    for (final AgentsRoomMember m in members) {
      if (m.agentId == wireId) return wireId;
    }
    for (final AgentsRoomMember m in members) {
      if (isHostOwnAgent(m.agentId) && wireAgentId(m.agentId) == wireId) {
        return m.agentId;
      }
    }
    return wireId;
  }

  /// A group the home host [listingHostId] listed, in the app's terms: the
  /// home set, every member's computer set, and a host-own member under the
  /// app's id for its computer ([hostAgentIdOf]).
  static AgentsRoom fromHostList(
    AgentsRoom listed,
    String? listingHostId,
    String Function(String hostId, String wireId) hostAgentIdOf,
  ) {
    final List<AgentsRoomMember> members = <AgentsRoomMember>[
      for (final AgentsRoomMember m in listed.members)
        () {
          final String? host = m.hostId ?? listingHostId;
          final String id = host != null && isHostOwnAgent(m.agentId)
              ? hostAgentIdOf(host, m.agentId)
              : m.agentId;
          return AgentsRoomMember(agentId: id, handle: m.handle, hostId: host);
        }(),
    ];
    String? mapped(String? wireId) =>
        wireId == null ? null : appAgentIdIn(members, wireId);
    return AgentsRoom(
      id: listed.id,
      name: listed.name,
      members: List<AgentsRoomMember>.unmodifiable(members),
      agentToAgent: listed.agentToAgent,
      responder: listed.responder,
      leadAgentId: mapped(listed.leadAgentId),
      fallbackAgentId: mapped(listed.fallbackAgentId),
      bulletin: listed.bulletin,
      workdir: listed.workdir,
      homeHostId: listingHostId ?? listed.homeHostId,
    );
  }

  /// The settings keys with the lead and fallback member as their wire ids.
  static Map<String, Object?> wireSettings(Map<String, Object?> settings) =>
      <String, Object?>{
        for (final MapEntry<String, Object?> e in settings.entries)
          e.key: switch (e.value) {
            final String id
                when e.key == 'lead_agent_id' || e.key == 'fallback_agent_id' =>
              wireAgentId(id),
            final Object? other => other,
          },
      };

  /// The home host of a new group with members on [memberHosts]: the
  /// computer on screen when a member lives there, else the first member's.
  static String? pickHome(List<String?> memberHosts, String? primaryHostId) {
    if (memberHosts.contains(primaryHostId)) return primaryHostId;
    for (final String? h in memberHosts) {
      if (h != null) return h;
    }
    return primaryHostId;
  }

  /// Why [candidateId] (on [candidateHost]) cannot join a group with
  /// [chosen] (agent id, computer), or null when it can.
  ///
  /// [capabilitiesOf] returns what a computer named last, or null when it
  /// never said (offline since the app started). [labelOf] names a computer.
  static String? blockedReason({
    required String candidateId,
    required String? candidateHost,
    required Iterable<(String, String?)> chosen,
    required Set<String>? Function(String hostId) capabilitiesOf,
    required String Function(String? hostId) labelOf,
  }) {
    final List<(String, String?)> others = <(String, String?)>[
      for (final (String, String?) c in chosen)
        if (c.$1 != candidateId) c,
    ];
    if (isHostOwnAgent(candidateId) &&
        others.any(((String, String?) c) => isHostOwnAgent(c.$1))) {
      return 'Only one computer\'s own agent fits in a group';
    }
    final Set<String?> hosts = <String?>{
      candidateHost,
      for (final (String, String?) c in others) c.$2,
    };
    if (hosts.length < 2) return null;
    // Across computers: every computer involved must link to the others.
    final List<String?> order = <String?>[
      candidateHost,
      for (final String? h in hosts)
        if (h != candidateHost) h,
    ];
    for (final String? host in order) {
      final Set<String>? caps = host == null ? null : capabilitiesOf(host);
      if (caps == null) return '${labelOf(host)} is offline';
      if (!caps.contains(AgentsRelayClient.hostPeersCapability)) {
        return '${labelOf(host)} needs an update for shared groups';
      }
    }
    return null;
  }
}

/// Sends a group's frames to its home host only (CHAT-177 phase 2), with
/// the wire ids and `host_id`s of [AgentsRoomHosts]. The shell owns one; the
/// controller lookup is its seam.
class AgentsRoomFrames {
  AgentsRoomFrames({
    required AgentsRelayController? Function(String? hostId) controllerFor,
    required String? Function() primaryHostId,
  }) : _controllerFor = controllerFor,
       _primaryHostId = primaryHostId;

  final AgentsRelayController? Function(String? hostId) _controllerFor;
  final String? Function() _primaryHostId;

  /// The computer [room] lives on: its home, else the computer on screen (a
  /// group from before CHAT-177).
  String? homeOf(AgentsRoom room) => room.homeHostId ?? _primaryHostId();

  /// The live controller of [room]'s home host, or null while it is down.
  AgentsRelayController? controllerOf(AgentsRoom room) =>
      _controllerFor(homeOf(room));

  /// `room_create` with every member and, when given, [settings]. Null when
  /// the home host is down (nothing was sent).
  Future<void>? create(AgentsRoom room, {Map<String, Object?>? settings}) {
    final AgentsRelayController? c = controllerOf(room);
    if (c == null) return null;
    final String? home = homeOf(room);
    return c.createRoom(
      room.id,
      room.name,
      AgentsRoomHosts.wireMembers(room.members, home),
      agentToAgent: room.agentToAgent,
      settings: AgentsRoomHosts.wireSettings(settings ?? room.settingsWire()),
    );
  }

  Future<void>? addMember(AgentsRoom room, AgentsRoomMember member) {
    final AgentsRelayController? c = controllerOf(room);
    if (c == null) return null;
    final Map<String, String> wire = AgentsRoomHosts.wireMember(
      member,
      homeOf(room),
    );
    return c.addRoomMember(
      room.id,
      AgentsRoomHosts.wireAgentId(member.agentId),
      member.handle,
      hostId: wire['host_id'],
    );
  }

  Future<void>? removeMember(AgentsRoom room, String agentId) =>
      controllerOf(room)
          ?.removeRoomMember(room.id, AgentsRoomHosts.wireAgentId(agentId));

  Future<void>? setSettings(AgentsRoom room, Map<String, Object?> settings) =>
      controllerOf(room)
          ?.setRoomSettings(room.id, AgentsRoomHosts.wireSettings(settings));
}
