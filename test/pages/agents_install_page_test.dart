// The install page: one command, copy, a live wait, a new command, the
// expired state, and the way back to the code page.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/agents_install_page.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agents_cloud_relay.dart';
import 'package:chuk_chat/services/agents/agents_install_ticket.dart';
import 'package:chuk_chat/services/agents/agents_pairing_store.dart';
import 'package:chuk_chat/services/agents/agents_pairing_uri.dart';

import '../support/test_app.dart';

class _MemoryStore implements AgentsSecureKeyValueStore {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> read(String key) async => map[key];

  @override
  Future<void> write(String key, String value) async => map[key] = value;

  @override
  Future<void> delete(String key) async => map.remove(key);
}

class _Session implements AccountSessionSource {
  const _Session();

  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'jwt',
    refreshToken: 'r',
    userId: 'user-1',
  );

  @override
  Future<AccountSession?> refresh() async => current();
}

void main() {
  late _MemoryStore backend;
  late List<Completer<String?>> waits;
  late List<AgentsClaimCancel> cancels;
  late List<AgentsPairingInvite> paired;
  late List<String> clipboard;
  final DateTime now = DateTime.utc(2026, 9, 29, 12);

  setUp(() {
    backend = _MemoryStore();
    waits = <Completer<String?>>[];
    cancels = <AgentsClaimCancel>[];
    paired = <AgentsPairingInvite>[];
    clipboard = <String>[];
  });

  /// Pumps a host screen whose button opens the page, so a test can see what
  /// the page pops with. Returns the pop result, once there is one.
  Future<Completer<bool?>> pumpPage(
    WidgetTester tester, {
    AgentsCodePageOpener? openCodePage,
  }) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (MethodCall call) async {
        if (call.method == 'Clipboard.setData') {
          clipboard.add((call.arguments as Map)['text'] as String);
        }
        return null;
      },
    );
    addTearDown(
      () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      ),
    );

    final Completer<bool?> popped = Completer<bool?>();
    await tester.pumpWidget(
      testApp(
        Builder(
          builder: (BuildContext context) => Center(
            child: TextButton(
              onPressed: () async {
                final bool? result = await Navigator.of(context).push<bool>(
                  MaterialPageRoute<bool>(
                    builder: (_) => AgentsInstallPage(
                      ticketStore: AgentsInstallTicketStore(backend: backend),
                      sessionSource: const _Session(),
                      now: () => now,
                      openCodePage: openCodePage,
                      claimWaiter:
                          (
                            AgentsPairingInvite invite, {
                            required DateTime deadline,
                            required AgentsClaimCancel cancel,
                          }) {
                            final Completer<String?> wait =
                                Completer<String?>();
                            waits.add(wait);
                            cancels.add(cancel);
                            return wait.future;
                          },
                      pair: (AgentsPairingInvite invite) async {
                        paired.add(invite);
                      },
                    ),
                  ),
                );
                popped.complete(result);
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return popped;
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  }

  String shownCommand(WidgetTester tester) => tester
      .widget<SelectableText>(find.byKey(AgentsInstallPage.commandKey))
      .data!;

  testWidgets('shows ONE command with a fresh token, and waits', (
    tester,
  ) async {
    await pumpPage(tester);

    expect(find.text('Add your computer'), findsOneWidget);
    final String command = shownCommand(tester);
    expect(
      command,
      matches(
        RegExp(
          r'^curl -fsSL https://api\.chuk\.chat/agents/install\.sh \| '
          r'bash -s -- --token=[0-9a-f]{64}-[0-9]{8}$',
        ),
      ),
    );
    expect(find.text('Waiting for your computer…'), findsOneWidget);
    expect(
      find.text('You can use this command for 30 more minutes.'),
      findsOneWidget,
    );
    expect(find.textContaining('Linux'), findsOneWidget);
    // No jargon on screen beyond the command itself.
    for (final String word in <String>['relay', 'channel', 'WebSocket']) {
      expect(find.textContaining(word), findsNothing, reason: word);
    }
    expect(find.textContaining('token'), findsOneWidget, reason: 'the command');
    expect(waits, hasLength(1));
    await close(tester);
  });

  testWidgets('Copy puts the command on the clipboard', (tester) async {
    await pumpPage(tester);
    await tester.tap(find.byKey(AgentsInstallPage.copyKey));
    await tester.pump();
    expect(clipboard, <String>[shownCommand(tester)]);
    expect(find.text('Command copied.'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
    await close(tester);
  });

  testWidgets('New command: another token, the old wait cancelled', (
    tester,
  ) async {
    await pumpPage(tester);
    final String first = shownCommand(tester);

    await tester.tap(find.byKey(AgentsInstallPage.newCommandKey));
    await tester.pumpAndSettle();

    expect(shownCommand(tester), isNot(first));
    expect(cancels.first.isCancelled, isTrue);
    expect(waits, hasLength(2));
    await close(tester);
  });

  testWidgets('expired: no command, one plain sentence, New command', (
    tester,
  ) async {
    await pumpPage(tester);
    waits.single.completeError(
      const AgentsCloudRelayException('expired', code: 'claim_expired'),
    );
    await tester.pumpAndSettle();

    expect(find.text('This command has expired.'), findsOneWidget);
    expect(find.byKey(AgentsInstallPage.commandKey), findsNothing);
    expect(find.byKey(AgentsInstallPage.newCommandKey), findsOneWidget);

    await tester.tap(find.byKey(AgentsInstallPage.newCommandKey));
    await tester.pumpAndSettle();
    expect(find.byKey(AgentsInstallPage.commandKey), findsOneWidget);
    expect(find.text('Waiting for your computer…'), findsOneWidget);
    await close(tester);
  });

  testWidgets('the computer reports in: paired with the ticket, the page '
      'closes with true', (tester) async {
    final Completer<bool?> popped = await pumpPage(tester);
    final String command = shownCommand(tester);

    waits.single.complete('host-1');
    await tester.pumpAndSettle();

    expect(paired, hasLength(1));
    expect(command, endsWith('--token=${paired.single.pairingCode}'));
    expect(await popped.future, isTrue);
    expect(find.byType(AgentsInstallPage), findsNothing);
    expect(backend.map, isEmpty, reason: 'the ticket is deleted');
    await close(tester);
  });

  testWidgets('"Pair with a code instead" opens the code page and pairs '
      'through the same sequence', (tester) async {
    final AgentsPairingInvite code = AgentsPairingInvite.tryParse(
      'k7m2p9q4w8r3t6y1u5i0o2a7s4d9f3g6h1j8k5l2z7x4c9v6b3-428913',
    )!;
    int opened = 0;
    final Completer<bool?> popped = await pumpPage(
      tester,
      openCodePage: (BuildContext context) async {
        opened++;
        return code;
      },
    );

    await tester.tap(find.byKey(AgentsInstallPage.useCodeKey));
    await tester.pumpAndSettle();

    expect(opened, 1);
    expect(cancels.single.isCancelled, isTrue);
    expect(paired.single, code);
    expect(await popped.future, isTrue);
    await close(tester);
  });

  testWidgets('leaving and coming back shows the same command', (tester) async {
    await pumpPage(tester);
    final String first = shownCommand(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(cancels.single.isCancelled, isTrue);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(shownCommand(tester), first);
    await close(tester);
  });

  testWidgets('fits a 360 px phone at 1.3 text scale', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 1.3;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await pumpPage(tester);
    tester.view.physicalSize = const Size(360, 740);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await close(tester);
  });
}
