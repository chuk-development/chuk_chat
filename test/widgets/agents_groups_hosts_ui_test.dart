// CHAT-177 phase 2 UI: the group editor with agents of two computers (one
// blocked), a group turn with a shared file, and Settings > Computers with
// the link status.
//
// CHAT177_PNG=1 writes PNGs into _scratch/chat177/ (real fonts), for a look
// at the screens without a window.
import 'dart:io';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/pages/agents_computers_page.dart';
import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_host_peering.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/widgets/agents_host_tag.dart';
import 'package:chuk_chat/widgets/room_create_sheet.dart';
import 'package:chuk_chat/widgets/room_thread_view.dart';

import '../platform_specific/mobile/mobile_support.dart';
import '../support/fake_relay_controller.dart';
import '../support/test_app.dart';

final bool _write = Platform.environment['CHAT177_PNG'] == '1';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _NoMirror extends SupabasePairingSync {
  @override
  Future<void> saveEncryptedPairing(AgentsStoredPairing pairing) async {}

  @override
  Future<void> clearEncryptedPairing({String? hostId}) async {}
}

ThemeData _theme(Brightness b) => b == Brightness.dark
    ? buildAppTheme(
        accent: kDefaultAccentColor,
        iconFg: kDefaultIconFgColor,
        bg: kDefaultBgColor,
        brightness: Brightness.dark,
        palette: kPlaneDarkPalette,
      )
    : buildAppTheme(
        accent: const Color(0xFF45484A),
        iconFg: const Color(0xFF0F0F10),
        bg: const Color(0xFFFFFFFF),
        brightness: Brightness.light,
      );

Future<void> _png(WidgetTester tester, String name) async {
  if (!_write) return;
  final RenderRepaintBoundary rb = tester.renderObject<RenderRepaintBoundary>(
    find.byKey(const ValueKey<String>('shot')),
  );
  await tester.runAsync(() async {
    final ui.Image image = await rb.toImage(pixelRatio: 1);
    final data = await image.toByteData(format: ui.ImageByteFormat.png);
    final File out = File('_scratch/chat177/$name.png');
    out.parent.createSync(recursive: true);
    out.writeAsBytesSync(data!.buffer.asUint8List());
  });
}

class _Host implements AgentsHostPeersControl {
  _Host(this.peers);

  final List<String> peers;

  @override
  ValueListenable<Set<String>> get capabilities =>
      ValueNotifier<Set<String>>(const <String>{'host_peers'});

  @override
  Future<Map<String, dynamic>> hostPeerRequest(
    Map<String, dynamic> frame, {
    Duration timeout = const Duration(seconds: 20),
  }) async => <String, dynamic>{
    'type': 'host_peer_list',
    'request': frame['type'],
    'ok': true,
    'peers': <Map<String, Object?>>[
      for (final String p in peers) <String, Object?>{'peer_host_id': p},
    ],
  };
}

void main() {
  late SimplePublicKey hostKey;
  final AgentsRelayLinks links = AgentsRelayLinks.instance;

  setUpAll(() async {
    if (_write) await loadRealFonts();
    hostKey = await (await AgentsDeviceKeys.generate()).extractPublicKey();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    links.reset();
    AgentsHostLabels.instance.reset();
  });
  tearDown(() {
    links.reset();
    AgentsHostLabels.instance.reset();
  });

  AgentsStoredPairing pairing(
    String device, {
    AgentsHostKind? kind,
    String? name,
  }) => AgentsStoredPairing(
    hostUrl: Uri.parse('wss://api.chuk.chat/v2/relay/ws?cw_device=$device'),
    channelId: 'chan-$device',
    channelKey: Uint8List(32),
    peerDeviceId: 'cowork-host',
    peerPublicKey: hostKey,
    kind: kind,
    displayName: name,
  );

  Future<void> pumpAt(
    WidgetTester tester,
    Widget child, {
    Size size = const Size(412, 915),
    double textScale = 1,
    Brightness brightness = Brightness.light,
  }) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
          padding: const EdgeInsets.only(top: 24, bottom: 16),
        ),
        // Around the app, so a dialog's route is in the picture too.
        child: RepaintBoundary(
          key: const ValueKey<String>('shot'),
          child: MaterialApp(
            debugShowCheckedModeBanner: false,
            theme: _theme(brightness),
            localizationsDelegates: kTestLocalizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: child,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  void twoLabels() => AgentsHostLabels.instance.update(<AgentsStoredPairing>[
    pairing('pc', name: 'Desk PC'),
    pairing('box', kind: AgentsHostKind.cloud, name: 'Cloud-Computer'),
  ], 'pc');

  for (final Brightness b in Brightness.values) {
    testWidgets('group editor: agents of both computers, one blocked '
        '(${b.name})', (tester) async {
      twoLabels();
      final List<AgentsAgent> agents = <AgentsAgent>[
        AgentsAgent(
          id: 'host:cowork-host',
          name: 'Desk',
          hostId: 'pc',
          threads: const <AgentsThreadInfo>[],
        ),
        AgentsAgent(
          id: 'host:cowork-host@box',
          name: 'Cloud',
          hostId: 'box',
          threads: const <AgentsThreadInfo>[],
        ),
        AgentsAgent(
          id: 'local:crawler',
          name: 'Crawler',
          role: 'Long crawls',
          hostId: 'box',
          threads: const <AgentsThreadInfo>[],
        ),
      ];
      await pumpAt(
        tester,
        Scaffold(
          body: RoomCreateSheet(
            agents: agents,
            onSubmit: (_) {},
            onCancel: () {},
            blockedReason: (candidate, chosen) =>
                candidate.id.startsWith('host:') &&
                    chosen.any((a) => a.id.startsWith('host:'))
                ? "Only one computer's own agent fits in a group"
                : null,
          ),
        ),
        brightness: b,
      );
      await tester.tap(
        find.byKey(
          const ValueKey<String>('room-create-agent-host:cowork-host'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.byKey(const ValueKey<String>('agents-host-tag')),
        findsNWidgets(3),
      );
      expect(
        find.text("Only one computer's own agent fits in a group"),
        findsOneWidget,
      );
      await _png(tester, 'group_editor_${b.name}');
    });

    testWidgets('group turn with a shared file (${b.name})', (tester) async {
      twoLabels();
      await pumpAt(
        tester,
        Scaffold(
          body: RoomThreadView(
            roomName: 'Crew',
            members: const <AgentsRoomMember>[
              AgentsRoomMember(agentId: 'local:crawler', handle: 'crawler'),
              AgentsRoomMember(agentId: 'host:cowork-host', handle: 'desk'),
            ],
            turns: const <AgentsRoomTurn>[
              AgentsRoomTurn.user('@crawler get the price list'),
              AgentsRoomTurn(
                round: 1,
                agentId: 'local:crawler',
                handle: 'crawler',
                text:
                    'Shared file prices.csv (183244 bytes). ref: {"sha256": '
                    '"9f2c", "name": "prices.csv", "size": 183244, '
                    '"host_id": "box"}',
              ),
              AgentsRoomTurn(
                round: 1,
                agentId: 'host:cowork-host',
                handle: 'desk',
                text: '(Cloud-Computer is offline, no reply)',
              ),
            ],
          ),
        ),
        brightness: b,
      );
      expect(
        find.byKey(const ValueKey<String>('room-shared-file')),
        findsOneWidget,
      );
      expect(find.text('prices.csv'), findsOneWidget);
      expect(find.text('179 KB · Cloud-Computer'), findsOneWidget);
      await _png(tester, 'group_file_${b.name}');
    });
  }

  testWidgets('Settings > Computers shows the link status', (tester) async {
    final AgentsPairingStore store = AgentsPairingStore(
      backend: _MemoryStore(),
      cloudSync: _NoMirror(),
    );
    late AgentsHostPeering peering;
    await tester.runAsync(() async {
      await store.savePairing(pairing('pc', name: 'Desk PC'));
      await store.savePairing(pairing('box', kind: AgentsHostKind.cloud));
      final Map<String, _Host> hosts = <String, _Host>{
        'pc': _Host(<String>['box']),
        'box': _Host(<String>['pc']),
      };
      peering = AgentsHostPeering(
        store: store,
        controlFor: (String id) => hosts[id],
      );
      await peering.sync();
    });
    addTearDown(peering.dispose);
    links.setPrimaryHost('pc');
    final FakeRelayController pc = FakeRelayController()
      ..set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
    links.primary.bind(pc);
    addTearDown(pc.dispose);
    await pumpAt(
      tester,
      AgentsComputersPage(store: store, peering: peering, onAddComputer: () {}),
    );
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
    expect(find.text('Online · linked'), findsOneWidget);
    expect(find.text('Offline · linked'), findsOneWidget);
    await _png(tester, 'computers_linked');
  });
}
