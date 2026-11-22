// CHAT-177 phase 2: groups with members on several computers. The wire ids,
// `host_id` only for a member of another computer, every frame to the
// group's home host, and the two computers' own agents that never share a
// group.
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_room_hosts.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

import '../../support/fake_relay_controller.dart';

/// Records the group frames one computer got.
class _RoomRelay extends FakeRelayController {
  final List<(String, List<Map<String, String>>, Map<String, Object?>)>
  creates = <(String, List<Map<String, String>>, Map<String, Object?>)>[];
  final List<(String, String, String, String?)> adds =
      <(String, String, String, String?)>[];
  final List<(String, String)> removes = <(String, String)>[];
  final List<Map<String, Object?>> settings = <Map<String, Object?>>[];

  @override
  Future<void> createRoom(
    String roomId,
    String name,
    List<Map<String, String>> members, {
    bool agentToAgent = true,
    Map<String, Object?> settings = const <String, Object?>{},
  }) async {
    creates.add((roomId, members, settings));
  }

  @override
  Future<void> addRoomMember(
    String roomId,
    String agentId,
    String handle, {
    String? hostId,
  }) async {
    adds.add((roomId, agentId, handle, hostId));
  }

  @override
  Future<void> removeRoomMember(String roomId, String agentId) async {
    removes.add((roomId, agentId));
  }

  @override
  Future<void> setRoomSettings(
    String roomId,
    Map<String, Object?> settings,
  ) async {
    this.settings.add(settings);
  }
}

void main() {
  const Set<String> peers = <String>{AgentsRelayClient.hostPeersCapability};

  group('wire ids', () {
    test('a computer\'s own agent loses the app suffix on the wire', () {
      expect(
        AgentsRoomHosts.wireAgentId('host:cowork-host@box'),
        'host:cowork-host',
      );
      expect(
        AgentsRoomHosts.wireAgentId('host:cowork-host'),
        'host:cowork-host',
      );
      expect(AgentsRoomHosts.wireAgentId('local:abc'), 'local:abc');
    });

    test('host_id rides only for a member of another computer', () {
      final List<Map<String, String>> wire = AgentsRoomHosts.wireMembers(
        const <AgentsRoomMember>[
          AgentsRoomMember(agentId: 'local:a', handle: 'a', hostId: 'pc'),
          AgentsRoomMember(
            agentId: 'host:cowork-host@box',
            handle: 'cloud',
            hostId: 'box',
          ),
          AgentsRoomMember(agentId: 'local:b', handle: 'b'),
        ],
        'pc',
      );
      expect(wire, <Map<String, String>>[
        <String, String>{'agent_id': 'local:a', 'handle': 'a'},
        <String, String>{
          'agent_id': 'host:cowork-host',
          'handle': 'cloud',
          'host_id': 'box',
        },
        <String, String>{'agent_id': 'local:b', 'handle': 'b'},
      ]);
    });

    test('a turn from host:cowork-host is the group\'s host-own member', () {
      const List<AgentsRoomMember> members = <AgentsRoomMember>[
        AgentsRoomMember(agentId: 'local:a', handle: 'a'),
        AgentsRoomMember(agentId: 'host:cowork-host@box', handle: 'cloud'),
      ];
      expect(
        AgentsRoomHosts.appAgentIdIn(members, 'host:cowork-host'),
        'host:cowork-host@box',
      );
      expect(AgentsRoomHosts.appAgentIdIn(members, 'local:a'), 'local:a');
    });

    test('a listed group takes its home and maps the host-own member', () {
      final AgentsRoom listed = AgentsRoom.fromJson(<String, Object?>{
        'room_id': 'room:1',
        'name': 'Crew',
        'members': <Object?>[
          <String, Object?>{'agent_id': 'host:cowork-host', 'handle': 'pc'},
          <String, Object?>{
            'agent_id': 'local:c',
            'handle': 'c',
            'host_id': 'box',
          },
        ],
        'lead_agent_id': 'host:cowork-host',
      })!;
      final AgentsRoom room = AgentsRoomHosts.fromHostList(
        listed,
        'pc',
        (String host, String wireId) => '$wireId@$host',
      );
      expect(room.homeHostId, 'pc');
      expect(room.members.first.agentId, 'host:cowork-host@pc');
      expect(room.members.first.hostId, 'pc');
      expect(room.members.last.hostId, 'box');
      expect(room.leadAgentId, 'host:cowork-host@pc');
      // The local copy keeps the home and the computers.
      final AgentsRoom back = AgentsRoom.fromJson(room.toJson())!;
      expect(back.homeHostId, 'pc');
      expect(back.members.last.hostId, 'box');
    });

    test('the home is the computer on screen when a member lives there', () {
      expect(AgentsRoomHosts.pickHome(<String?>['box', 'pc'], 'pc'), 'pc');
      expect(AgentsRoomHosts.pickHome(<String?>['box', 'lap'], 'pc'), 'box');
    });
  });

  group('blocked members', () {
    String? reason(
      String id,
      String host,
      List<(String, String?)> chosen, {
      Map<String, Set<String>> caps = const <String, Set<String>>{
        'pc': peers,
        'box': peers,
      },
    }) => AgentsRoomHosts.blockedReason(
      candidateId: id,
      candidateHost: host,
      chosen: chosen,
      capabilitiesOf: (String h) => caps[h],
      labelOf: (String? h) => h == 'box' ? 'Cloud' : 'PC',
    );

    test('two computers\' own agents never share a group', () {
      expect(
        reason('host:cowork-host@box', 'box', <(String, String?)>[
          ('host:cowork-host', 'pc'),
        ]),
        isNotNull,
      );
      // An agent the app made on the cloud computer is fine.
      expect(
        reason('local:c', 'box', <(String, String?)>[
          ('host:cowork-host', 'pc'),
        ]),
        isNull,
      );
    });

    test('across computers every computer must name host_peers', () {
      expect(
        reason(
          'local:c',
          'box',
          <(String, String?)>[('local:a', 'pc')],
          caps: <String, Set<String>>{'pc': peers, 'box': <String>{}},
        ),
        'Cloud needs an update for shared groups',
      );
      expect(
        reason(
          'local:c',
          'box',
          <(String, String?)>[('local:a', 'pc')],
          caps: <String, Set<String>>{'pc': peers},
        ),
        'Cloud is offline',
      );
      // One computer: no rule beyond the host-own one.
      expect(
        reason('local:b', 'pc', <(String, String?)>[
          ('local:a', 'pc'),
        ], caps: const <String, Set<String>>{}),
        isNull,
      );
    });
  });

  group('home-host routing', () {
    late _RoomRelay pc;
    late _RoomRelay box;
    late AgentsRoomFrames frames;

    setUp(() {
      pc = _RoomRelay();
      box = _RoomRelay();
      frames = AgentsRoomFrames(
        controllerFor: (String? host) => switch (host) {
          'pc' || null => pc,
          'box' => box,
          _ => null,
        },
        primaryHostId: () => 'pc',
      );
    });

    const AgentsRoom room = AgentsRoom(
      id: 'room:1',
      name: 'Crew',
      homeHostId: 'box',
      members: <AgentsRoomMember>[
        AgentsRoomMember(
          agentId: 'host:cowork-host@box',
          handle: 'cloud',
          hostId: 'box',
        ),
        AgentsRoomMember(agentId: 'local:a', handle: 'a', hostId: 'pc'),
      ],
      leadAgentId: 'host:cowork-host@box',
    );

    test('create goes to the home host only, with host_id and wire ids', () {
      frames.create(room);
      expect(pc.creates, isEmpty);
      final (
        String id,
        List<Map<String, String>> members,
        Map<String, Object?> s,
      ) = box.creates.single;
      expect(id, 'room:1');
      expect(members, <Map<String, String>>[
        <String, String>{'agent_id': 'host:cowork-host', 'handle': 'cloud'},
        <String, String>{'agent_id': 'local:a', 'handle': 'a', 'host_id': 'pc'},
      ]);
      expect(s['lead_agent_id'], 'host:cowork-host');
    });

    test('add, remove and settings go to the home host', () {
      frames.addMember(
        room,
        const AgentsRoomMember(agentId: 'local:b', handle: 'b', hostId: 'pc'),
      );
      frames.addMember(
        room,
        const AgentsRoomMember(agentId: 'local:c', handle: 'c', hostId: 'box'),
      );
      frames.removeMember(room, 'host:cowork-host@box');
      frames.setSettings(room, <String, Object?>{
        'fallback_agent_id': 'host:cowork-host@box',
      });
      expect(pc.adds, isEmpty);
      expect(box.adds, <(String, String, String, String?)>[
        ('room:1', 'local:b', 'b', 'pc'),
        ('room:1', 'local:c', 'c', null),
      ]);
      expect(box.removes.single, ('room:1', 'host:cowork-host'));
      expect(box.settings.single['fallback_agent_id'], 'host:cowork-host');
    });

    test('a group from before CHAT-177 stays on the computer on screen', () {
      frames.create(
        const AgentsRoom(
          id: 'room:old',
          name: 'Old',
          members: <AgentsRoomMember>[
            AgentsRoomMember(agentId: 'local:a', handle: 'a'),
            AgentsRoomMember(agentId: 'local:b', handle: 'b'),
          ],
        ),
      );
      expect(pc.creates.single.$1, 'room:old');
      expect(box.creates, isEmpty);
    });

    test('a home host that is down gets nothing', () {
      final AgentsRoomFrames offline = AgentsRoomFrames(
        controllerFor: (String? host) => host == 'box' ? null : pc,
        primaryHostId: () => 'pc',
      );
      expect(offline.create(room), isNull);
      expect(pc.creates, isEmpty);
    });
  });

  group('shared file turn', () {
    test('the ref at the end of a turn is parsed', () {
      final RoomSharedFile? file = RoomSharedFile.tryParse(
        'Shared file report.pdf (2048 bytes). ref: {"sha256": "ab12", '
        '"name": "report.pdf", "size": 2048, "host_id": "box"}',
      );
      expect(file, isNotNull);
      expect(file!.name, 'report.pdf');
      expect(file.size, 2048);
      expect(file.hostId, 'box');
      expect(file.sizeLabel, '2.0 KB');
    });

    test('an offline line or plain text has no file', () {
      expect(
        RoomSharedFile.tryParse('(Cloud-Computer is offline, no reply)'),
        isNull,
      );
      expect(RoomSharedFile.tryParse('see ref: {broken'), isNull);
    });
  });
}
