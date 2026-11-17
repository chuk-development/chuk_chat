import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/services/agents/agent_avatar_sync.dart';
import 'package:chuk_chat/services/agents/agent_profile_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/notifications/notification_avatar.dart';

class _Control implements AgentsAvatarControl {
  final List<(String, String)> sent = <(String, String)>[];
  bool fail = false;

  @override
  Future<void> setAgentAvatar(String agentId, String pngBase64) async {
    if (fail) throw StateError('link down');
    sent.add((agentId, pngBase64));
  }
}

void main() {
  late Directory tmp;
  late AgentProfileStore store;
  late AgentAvatarSync sync;
  late _Control control;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    tmp = Directory.systemTemp.createTempSync('avatar_sync_test');
    store = AgentProfileStore();
    control = _Control();
    sync = AgentAvatarSync(
      avatars: AgentNotificationAvatar(
        supportDir: () async => tmp,
        profiles: store,
        paintPng: (String id, String name, double size) async =>
            Uint8List.fromList(utf8.encode('png:$id:$name')),
      ),
    );
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  const List<AvatarAgent> agents = <AvatarAgent>[
    (id: 'a1', name: 'Research'),
    (id: 'a2', name: 'Mail'),
  ];

  test('sends each face once per host', () async {
    await sync.sync(agents: agents, control: control, hostId: 'host-1');
    expect(control.sent.map(((String, String) e) => e.$1), <String>[
      'a1',
      'a2',
    ]);
    expect(
      utf8.decode(base64.decode(control.sent.first.$2)),
      'png:a1:Research',
    );
    await sync.sync(agents: agents, control: control, hostId: 'host-1');
    expect(control.sent, hasLength(2), reason: 'nothing new, nothing sent');
  });

  test('a new host gets every face again', () async {
    await sync.sync(agents: agents, control: control, hostId: 'host-1');
    await sync.sync(agents: agents, control: control, hostId: 'host-2');
    expect(control.sent, hasLength(4));
  });

  test('a rename or a new photo sends that agent again', () async {
    await sync.sync(agents: agents, control: control, hostId: 'host-1');
    await sync.sync(
      agents: const <AvatarAgent>[
        (id: 'a1', name: 'Recherche'),
        (id: 'a2', name: 'Mail'),
      ],
      control: control,
      hostId: 'host-1',
    );
    expect(control.sent.last.$1, 'a1');
    expect(control.sent, hasLength(3));
    await store.update('a2', photoPath: '/x/p.png');
    await sync.sync(
      agents: const <AvatarAgent>[
        (id: 'a1', name: 'Recherche'),
        (id: 'a2', name: 'Mail'),
      ],
      control: control,
      hostId: 'host-1',
    );
    expect(control.sent.last.$1, 'a2');
    expect(control.sent, hasLength(4));
  });

  test('a failed send is tried again next time', () async {
    control.fail = true;
    await sync.sync(agents: agents, control: control, hostId: 'host-1');
    control.fail = false;
    await sync.sync(agents: agents, control: control, hostId: 'host-1');
    expect(control.sent, hasLength(2));
  });

  test('no host: paints only, sends nothing', () async {
    await sync.sync(agents: agents);
    expect(
      File('${tmp.path}/notification_avatars/a1.png').existsSync(),
      isTrue,
    );
    expect(control.sent, isEmpty);
  });

  test('the sent record survives a restart (SharedPreferences)', () async {
    await sync.sync(agents: agents, control: control, hostId: 'host-1');
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final Map<String, dynamic> saved = jsonDecode(
      prefs.getString(AgentAvatarSync.prefsKey)!,
    ) as Map<String, dynamic>;
    expect((saved['host-1'] as Map).keys, containsAll(<String>['a1', 'a2']));
  });
}
