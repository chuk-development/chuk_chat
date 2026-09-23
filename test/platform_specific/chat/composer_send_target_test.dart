// The composer's primary target on the phone (bead cowork-bj88).
//
// The send button stays the send button. There is no red stop in the composer,
// so nothing the user taps there can interrupt the coworker.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

import '../../support/fake_relay_controller.dart';
import '../../support/icon_finder.dart';

/// The composer's targets carry a semantics identifier, not a label.
Finder findId(String id) => find.byWidgetPredicate(
  (Widget w) => w is Semantics && w.properties.identifier == id,
  description: 'Semantics identifier "$id"',
);

class _NoopSaver implements AgentFileSaver {
  @override
  Future<String> save(AgentsRelayFile file) async => '/dev/null/${file.name}';
}

class _FakeSessionSource implements AccountSessionSource {
  const _FakeSessionSource();

  @override
  AccountSession? current() => const AccountSession(
    accessToken: 'access-1',
    refreshToken: 'refresh-1',
    userId: 'user-1',
  );

  @override
  Future<AccountSession?> refresh() async => current();
}

Widget _app(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

void main() {
  // The Agents chat core (host-run tools, relay transport), selected for this
  // flag-off test process.
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await VerboseService.instance.setEnabled(false);
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
  });

  tearDown(() async {
    AgentsRelayLink.instance.reset();
    AgentsRunLedger.instance.reset();
    AgentsReplayLoader.instance.reset();
    await ChatStorageService.reset();
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  Future<void> pumpPhoneChat(WidgetTester tester) async {
    tester.view.physicalSize = const Size(390, 844);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        AgentsThreadView(
          phoneLayout: true,
          controllerBuilder: () async => FakeRelayController(),
          sessionSource: const _FakeSessionSource(),
          threadKey: 'composer-target',
          fileSaver: _NoopSaver(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChukChatUIMobile), findsOneWidget);
  }

  testWidgets('the composer has a send target and no stop', (tester) async {
    await pumpPhoneChat(tester);

    expect(findId('send_button'), findsOneWidget);
    expect(findIcon(Icons.north_rounded), findsOneWidget);
    expect(
      findIcon(Icons.stop_rounded),
      findsNothing,
      reason: 'the composer never offers a stop',
    );
  });

  testWidgets('typing does not turn the send target into a stop', (
    tester,
  ) async {
    await pumpPhoneChat(tester);

    await tester.enterText(find.byType(TextField).first, 'ballern');
    await tester.pumpAndSettle();

    expect(findId('send_button'), findsOneWidget);
    expect(findIcon(Icons.north_rounded), findsOneWidget);
    expect(findIcon(Icons.stop_rounded), findsNothing);
  });
}
