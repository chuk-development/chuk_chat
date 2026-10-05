import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/services/agents/agent_control_source.dart';
import 'package:chuk_chat/services/agents/agents_channels_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/widgets/agent_control_panel.dart';
import 'package:chuk_chat/widgets/agents_channels/agent_telegram_section.dart';

import '../support/test_app.dart';

/// Bead chuk_chat-02s5: the app side of a coworker's Telegram channel. The
/// host runs the bot; the app shows the host's state, sends what the user
/// does, and says every refusal in plain words.
void main() {
  const String agentId = 'local:wahlradar:2:116636868';

  late List<Map<String, dynamic>> sent;
  late ValueNotifier<Object?> connection;
  late ValueNotifier<Set<String>> capabilities;
  late AgentsChannelsService service;

  setUp(() {
    sent = <Map<String, dynamic>>[];
    connection = ValueNotifier<Object?>(Object());
    capabilities = ValueNotifier<Set<String>>(<String>{
      kAgentChannelsCapability,
    });
    service = AgentsChannelsService(
      send: (Map<String, dynamic> payload) async => sent.add(payload),
      connection: connection,
      capabilities: capabilities,
    );
  });

  tearDown(() {
    AgentsRelayClient.agentChannelSink = null;
    service.dispose();
    connection.dispose();
    capabilities.dispose();
  });

  /// One `agent_channel` frame from the host, through the relay's sink.
  void host(Map<String, dynamic> fields) {
    AgentsRelayClient.agentChannelSink!(<String, dynamic>{
      'type': 'agent_channel',
      'agent_id': agentId,
      'channel': 'telegram',
      'e2e': false,
      ...fields,
    });
  }

  const Map<String, dynamic> off = <String, dynamic>{
    'enabled': false,
    'allowed': true,
    'has_token': false,
    'state': 'off',
    'bot_username': '',
    'linked': false,
    'linked_name': '',
    'pending_link': false,
  };

  Future<void> pumpSection(WidgetTester tester, {Locale? locale}) async {
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        locale: locale,
        localizationsDelegates: kTestLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: AgentTelegramSection(agentId: agentId, service: service),
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Finder key(String value) => find.byKey(ValueKey<String>(value));

  testWidgets('hidden in the controls without the host capability', (
    tester,
  ) async {
    capabilities.value = <String>{};
    final source = FakeAgentControlSource();
    const agent = AgentsAgent(
      id: agentId,
      name: 'Wahlradar',
      threads: <AgentsThreadInfo>[
        AgentsThreadInfo(key: agentId, title: 'General'),
      ],
    );
    tester.view.physicalSize = const Size(420, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: AgentControlPanel(
            agent: agent,
            source: source,
            channels: service,
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(key('agent-telegram-section'), findsNothing);
    expect(find.text('CHANNELS'), findsNothing);
    expect(sent, isEmpty);

    // The host names the capability: the section shows and asks.
    capabilities.value = <String>{kAgentChannelsCapability};
    await tester.pumpAndSettle();
    expect(key('agent-telegram-section'), findsOneWidget);
    expect(find.text('CHANNELS'), findsOneWidget);
    expect(sent.single, <String, dynamic>{
      'type': 'agent_channel_get',
      'agent_id': agentId,
      'channel': 'telegram',
    });
    // Let the answer timer run out inside the test.
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('enable with a token: the field, the frame, then the link '
      'steps', (tester) async {
    await pumpSection(tester);
    expect(sent.single['type'], 'agent_channel_get');
    host(off);
    await tester.pump();

    expect(find.text('Telegram is not end-to-end encrypted.'), findsOneWidget);
    expect(key('agent-telegram-token'), findsNothing);

    // No token on the host yet: the switch opens the token field and sends
    // nothing.
    await tester.tap(key('agent-telegram-switch'));
    await tester.pump();
    expect(sent, hasLength(1));
    expect(key('agent-telegram-token'), findsOneWidget);
    expect(
      find.text('Create a bot with @BotFather and paste its token.'),
      findsOneWidget,
    );
    final TextField field = tester.widget<TextField>(
      key('agent-telegram-token'),
    );
    expect(field.obscureText, isTrue);

    await tester.enterText(
      key('agent-telegram-token'),
      '123456:ABC-def_ghijklmnopqrstuvwxyz0123456',
    );
    await tester.tap(key('agent-telegram-enable'));
    await tester.pump();
    expect(sent.last, <String, dynamic>{
      'type': 'agent_channel_set',
      'agent_id': agentId,
      'channel': 'telegram',
      'action': 'enable',
      'token': '123456:ABC-def_ghijklmnopqrstuvwxyz0123456',
    });

    host(<String, dynamic>{
      ...off,
      'enabled': true,
      'has_token': true,
      'state': 'polling',
      'bot_username': 'wahl_bot',
    });
    await tester.pump();
    expect(key('agent-telegram-token'), findsNothing);
    expect(find.text('On · @wahl_bot'), findsOneWidget);
    expect(
      find.text(
        'Send any message to @wahl_bot, then enter the 6-digit code it '
        'replies with.',
      ),
      findsOneWidget,
    );
    expect(key('agent-telegram-code'), findsOneWidget);
  });

  testWidgets('a stored token turns on without asking for it again', (
    tester,
  ) async {
    await pumpSection(tester);
    host(<String, dynamic>{...off, 'has_token': true});
    await tester.pump();
    expect(key('agent-telegram-forget'), findsOneWidget);

    await tester.tap(key('agent-telegram-switch'));
    await tester.pump();
    expect(sent.last, <String, dynamic>{
      'type': 'agent_channel_set',
      'agent_id': agentId,
      'channel': 'telegram',
      'action': 'enable',
    });
    expect(key('agent-telegram-token'), findsNothing);
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('code linking, then the linked state with Unlink', (
    tester,
  ) async {
    await pumpSection(tester);
    host(<String, dynamic>{
      ...off,
      'enabled': true,
      'has_token': true,
      'state': 'polling',
      'bot_username': 'wahl_bot',
      'pending_link': true,
    });
    await tester.pump();

    // Only digits, only six.
    await tester.enterText(key('agent-telegram-code'), '12a34567');
    await tester.pump();
    expect(
      tester.widget<TextField>(key('agent-telegram-code')).controller!.text,
      '123456',
    );
    await tester.tap(key('agent-telegram-link'));
    await tester.pump();
    expect(sent.last, <String, dynamic>{
      'type': 'agent_channel_set',
      'agent_id': agentId,
      'channel': 'telegram',
      'action': 'link',
      'code': '123456',
    });

    host(<String, dynamic>{
      ...off,
      'enabled': true,
      'has_token': true,
      'state': 'polling',
      'bot_username': 'wahl_bot',
      'linked': true,
      'linked_name': 'Chuk',
    });
    await tester.pump();
    expect(find.text('Linked to Chuk'), findsOneWidget);
    expect(key('agent-telegram-code'), findsNothing);

    await tester.tap(key('agent-telegram-unlink'));
    await tester.pump();
    expect(sent.last['action'], 'unlink');

    // Turning it off sends disable.
    host(<String, dynamic>{
      ...off,
      'enabled': true,
      'has_token': true,
      'state': 'polling',
    });
    await tester.pump();
    await tester.tap(key('agent-telegram-switch'));
    await tester.pump();
    expect(sent.last['action'], 'disable');
    await tester.pump(const Duration(seconds: 11));
  });

  testWidgets('errors and states are said plainly', (tester) async {
    await pumpSection(tester);
    host(<String, dynamic>{
      ...off,
      'enabled': true,
      'has_token': true,
      'state': 'polling',
      'bot_username': 'wahl_bot',
      'error': 'wrong_code',
    });
    await tester.pump();
    expect(key('agent-telegram-error'), findsOneWidget);
    expect(
      find.text('Wrong code. Check the message from the bot.'),
      findsOneWidget,
    );

    // A push without an error clears it, and says the new state.
    host(<String, dynamic>{
      ...off,
      'enabled': true,
      'has_token': true,
      'state': 'backoff',
    });
    await tester.pump();
    expect(key('agent-telegram-error'), findsNothing);
    expect(find.text('Cannot reach Telegram. Trying again.'), findsOneWidget);

    // A refused token reopens the token field.
    host(<String, dynamic>{
      ...off,
      'enabled': true,
      'has_token': true,
      'state': 'unauthorized',
    });
    await tester.pump();
    expect(
      find.text('Telegram refused the token. Paste a new one.'),
      findsOneWidget,
    );
    expect(key('agent-telegram-token'), findsOneWidget);

    host(<String, dynamic>{...off, 'error': 'token_in_use'});
    await tester.pump();
    expect(
      find.text('Another coworker already uses this bot.'),
      findsOneWidget,
    );

    // An unknown code is still shown, not swallowed.
    host(<String, dynamic>{...off, 'error': 'internal'});
    await tester.pump();
    expect(find.text('The host said: internal'), findsOneWidget);
  });

  testWidgets('the host that does not answer is said', (tester) async {
    await pumpSection(tester);
    expect(find.text('Asking the host…'), findsOneWidget);
    await tester.pump(const Duration(seconds: 11));
    expect(find.text('The host did not answer.'), findsOneWidget);
  });

  test('no frame goes to a host without the capability', () async {
    capabilities.value = <String>{};
    expect(await service.refresh(agentId), isFalse);
    expect(
      await service.act(agentId, AgentChannelAction.enable, token: 't'),
      isFalse,
    );
    expect(sent, isEmpty);
  });

  test('other channels and malformed frames are ignored', () {
    service.handleFrame(<String, dynamic>{'type': 'agent_permissions'});
    service.handleFrame(<String, dynamic>{
      'type': 'agent_channel',
      'agent_id': agentId,
      'channel': 'signal',
      'state': 'polling',
    });
    service.handleFrame(<String, dynamic>{
      'type': 'agent_channel',
      'agent_id': agentId,
    });
    expect(service.stateOf(agentId), isNull);
    expect(service.errorOf(agentId), isNull);

    service.handleFrame(<String, dynamic>{
      'type': 'agent_channel',
      'agent_id': agentId,
      'channel': 'telegram',
      'state': 'polling',
      'enabled': true,
      'bot_username': '@wahl_bot',
      'pending_link': true,
      'pending_link_expires_at': 1790000000,
    });
    final AgentChannelState state = service.stateOf(agentId)!;
    expect(state.enabled, isTrue);
    expect(state.botUsername, 'wahl_bot');
    expect(
      state.pendingLinkExpiresAt,
      DateTime.fromMillisecondsSinceEpoch(1790000000000, isUtc: true),
    );
  });

  testWidgets('switching coworkers while a send is out keeps the answer '
      'clock of the new one', (tester) async {
    const String otherId = 'local:other:1:2';
    final Completer<void> setGate = Completer<void>();
    final AgentsChannelsService gated = AgentsChannelsService(
      send: (Map<String, dynamic> payload) async {
        sent.add(payload);
        if (payload['type'] == 'agent_channel_set') await setGate.future;
      },
      connection: connection,
      capabilities: capabilities,
    );
    addTearDown(gated.dispose);
    tester.view.physicalSize = const Size(420, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    Widget section(String id) => MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AgentTelegramSection(agentId: id, service: gated),
        ),
      ),
    );
    await tester.pumpWidget(section(agentId));
    await tester.pump();
    host(<String, dynamic>{...off, 'has_token': true});
    await tester.pump();

    // The enable for the first coworker goes out and hangs.
    await tester.tap(key('agent-telegram-switch'));
    await tester.pump();
    expect(sent.last['action'], 'enable');
    expect(gated.isBusy(agentId), isTrue);

    // The section switches to another coworker; its host never answers.
    await tester.pumpWidget(section(otherId));
    await tester.pump();
    expect(sent.last, <String, dynamic>{
      'type': 'agent_channel_get',
      'agent_id': otherId,
      'channel': 'telegram',
    });
    expect(gated.isBusy(otherId), isFalse);

    // The first coworker's send completes half-way through the wait. It
    // must not restart the new coworker's answer clock.
    await tester.pump(const Duration(seconds: 5));
    setGate.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('The host did not answer.'), findsOneWidget);
  });

  test('dispose stops the relay sink only when it is its own', () {
    AgentsChannelsService make() => AgentsChannelsService(
      send: (Map<String, dynamic> payload) async => sent.add(payload),
      connection: connection,
      capabilities: capabilities,
    );
    final AgentsChannelsService first = make();
    final AgentsChannelsService second = make();
    first.attach();
    second.dispose();
    expect(AgentsRelayClient.agentChannelSink, isNotNull);
    AgentsRelayClient.agentChannelSink!(<String, dynamic>{
      'type': 'agent_channel',
      'agent_id': agentId,
      'channel': 'telegram',
      ...off,
    });
    expect(first.stateOf(agentId), isNotNull);
    first.dispose();
    expect(AgentsRelayClient.agentChannelSink, isNull);
  });

  testWidgets('German', (tester) async {
    await pumpSection(tester, locale: const Locale('de'));
    host(off);
    await tester.pump();
    expect(
      find.text('Telegram ist nicht Ende-zu-Ende-verschlüsselt.'),
      findsOneWidget,
    );
    await tester.tap(key('agent-telegram-switch'));
    await tester.pump();
    expect(
      find.text('Erstelle mit @BotFather einen Bot und füge sein Token ein.'),
      findsOneWidget,
    );
  });
}
