// CHAT-177 UI: Settings > Computers, the "Which computer?" step of a new
// agent, and the small computer label on the roster rows.
//
// CHAT177_PNG=1 writes PNGs into _scratch/chat177/ (real fonts), for a look
// at the screens without a window.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:cryptography/cryptography.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/pages/agents_computers_page.dart';
import 'package:chuk_chat/services/agents/agents_device_keys.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/supabase_pairing_sync.dart';
import 'package:chuk_chat/theme/theme_presets.dart';
import 'package:chuk_chat/widgets/agents_host_picker.dart';
import 'package:chuk_chat/widgets/agents_host_tag.dart';

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

void main() {
  late SimplePublicKey hostKey;
  final AgentsRelayLinks links = AgentsRelayLinks.instance;

  setUpAll(() async {
    if (_write) await loadRealFonts();
    hostKey = await (await AgentsDeviceKeys.generate()).extractPublicKey();
  });

  setUp(() {
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

  group('Settings > Computers', () {
    late AgentsPairingStore store;

    setUp(() async {
      store = AgentsPairingStore(
        backend: _MemoryStore(),
        cloudSync: _NoMirror(),
      );
    });

    Future<void> twoComputers(WidgetTester tester) async {
      await tester.runAsync(() async {
        await store.savePairing(pairing('pc', name: 'Desk PC'));
        await store.savePairing(pairing('box', kind: AgentsHostKind.cloud));
      });
      links.setPrimaryHost('pc');
      final FakeRelayController pc = FakeRelayController()
        ..set(const AgentsRelayState(phase: AgentsRelayPhase.paired));
      links.primary.bind(pc);
      addTearDown(pc.dispose);
    }

    for (final Brightness b in Brightness.values) {
      testWidgets(
        'lists both computers with name, kind and status (${b.name})',
        (tester) async {
          await twoComputers(tester);
          await pumpAt(
            tester,
            AgentsComputersPage(store: store, onAddComputer: () {}),
            brightness: b,
          );
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pumpAndSettle();

          expect(find.byKey(AgentsComputersPage.rowKey('pc')), findsOneWidget);
          expect(find.byKey(AgentsComputersPage.rowKey('box')), findsOneWidget);
          expect(find.text('Desk PC'), findsOneWidget);
          expect(find.text('Your computer'), findsOneWidget);
          expect(find.text('Cloud computer'), findsOneWidget);
          expect(find.text('Online'), findsOneWidget);
          expect(find.text('Offline'), findsOneWidget);
          expect(
            find.byKey(const ValueKey<String>('computer-online')),
            findsOneWidget,
          );
          expect(find.byKey(AgentsComputersPage.addKey), findsOneWidget);
          await _png(tester, 'computers_${b.name}');
        },
      );
    }

    testWidgets('rename stores the name', (tester) async {
      await twoComputers(tester);
      await pumpAt(tester, AgentsComputersPage(store: store));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(AgentsComputersPage.renameKey('box')));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Big box');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      final AgentsStoredPairing? box = await tester
          .runAsync<AgentsStoredPairing?>(
            () => store.loadPairing(hostId: 'box'),
          );
      expect(box!.displayName, 'Big box');
      expect(find.text('Big box'), findsOneWidget);
    });

    testWidgets('remove asks, then unlinks one computer', (tester) async {
      await twoComputers(tester);
      await pumpAt(tester, AgentsComputersPage(store: store));
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      await tester.ensureVisible(
        find.byKey(AgentsComputersPage.removeKey('box')),
      );
      await tester.tap(find.byKey(AgentsComputersPage.removeKey('box')));
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('settings_computer_remove_confirm')),
      );
      await tester.pumpAndSettle();
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();

      final List<AgentsStoredPairing>? left = await tester.runAsync(
        store.listPairings,
      );
      expect(left!.map((AgentsStoredPairing p) => p.hostId), <String>['pc']);
      expect(find.byKey(AgentsComputersPage.rowKey('box')), findsNothing);
    });

    testWidgets('fits 360 px at 1.3 text scale', (tester) async {
      await twoComputers(tester);
      await pumpAt(
        tester,
        AgentsComputersPage(store: store, onAddComputer: () {}),
        size: const Size(360, 780),
        textScale: 1.3,
      );
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await _png(tester, 'computers_360_scale13');
    });
  });

  group('Which computer?', () {
    testWidgets('one computer: no question', (tester) async {
      await pumpAt(tester, const SizedBox());
      final BuildContext context = tester.element(find.byType(SizedBox));
      String? picked;
      await tester.runAsync(() async {
        picked = await showAgentHostPicker(
          context,
          hosts: <AgentsStoredPairing>[pairing('pc')],
        );
      });
      expect(picked, 'pc');
      expect(find.byType(AgentHostPickerDialog), findsNothing);
    });

    for (final Brightness b in Brightness.values) {
      testWidgets('two computers: the one used last is chosen (${b.name})', (
        tester,
      ) async {
        await pumpAt(tester, const SizedBox(), brightness: b);
        final BuildContext context = tester.element(find.byType(SizedBox));
        String? picked = 'unset';
        final Future<void> done = showAgentHostPicker(
          context,
          hosts: <AgentsStoredPairing>[
            pairing('pc'),
            pairing('box', kind: AgentsHostKind.cloud),
          ],
          initialHostId: 'box',
          isOnline: (String id) => id == 'pc',
        ).then((String? v) => picked = v);
        await tester.pumpAndSettle();

        expect(find.text('Which computer?'), findsOneWidget);
        expect(find.text('Cloud computer · Offline'), findsOneWidget);
        await _png(tester, 'picker_${b.name}');

        await tester.tap(
          find.byKey(const ValueKey<String>('agents-host-pick-next')),
        );
        await tester.pumpAndSettle();
        await done;
        expect(picked, 'box');
      });
    }

    testWidgets('a tap picks another computer; Cancel gives null', (
      tester,
    ) async {
      await pumpAt(tester, const SizedBox());
      final BuildContext context = tester.element(find.byType(SizedBox));
      final List<AgentsStoredPairing> hosts = <AgentsStoredPairing>[
        pairing('pc'),
        pairing('box', kind: AgentsHostKind.cloud),
      ];
      String? picked = 'unset';
      Future<void> done = showAgentHostPicker(
        context,
        hosts: hosts,
        initialHostId: 'box',
      ).then((String? v) => picked = v);
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-host-pick-pc')),
      );
      await tester.pumpAndSettle();
      await tester.tap(
        find.byKey(const ValueKey<String>('agents-host-pick-next')),
      );
      await tester.pumpAndSettle();
      await done;
      expect(picked, 'pc');

      done = showAgentHostPicker(
        context,
        hosts: hosts,
      ).then((String? v) => picked = v);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      await done;
      expect(picked, isNull);
    });
  });

  group('the computer label', () {
    testWidgets('shows only with two or more computers', (tester) async {
      await pumpAt(
        tester,
        const Scaffold(
          body: Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                AgentsHostTag(hostId: 'box'),
                AgentsHostTag(hostId: null),
              ],
            ),
          ),
        ),
      );
      expect(
        find.byKey(const ValueKey<String>('agents-host-tag')),
        findsNothing,
      );

      AgentsHostLabels.instance.update(<AgentsStoredPairing>[
        pairing('pc'),
      ], 'pc');
      await tester.pump();
      expect(
        find.byKey(const ValueKey<String>('agents-host-tag')),
        findsNothing,
      );

      AgentsHostLabels.instance.update(<AgentsStoredPairing>[
        pairing('pc'),
        pairing('box', kind: AgentsHostKind.cloud),
      ], 'pc');
      await tester.pump();
      expect(find.text('Cloud'), findsOneWidget);
      // An agent with no computer lives on the one on screen.
      expect(find.text('PC'), findsOneWidget);
      await _png(tester, 'tags');
    });
  });
}
