// The desktop composer's layout on an empty chat, at desktop width.
//
// One row: +, the field, the microphone, send, from left to right on one
// centre line, in a 48 px box. Regression guard: an empty `/`-menu or queue
// dock in the box's column must not add height or push the row down.
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/composer_send_button.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';

import '../../support/fake_relay_controller.dart';
import '../../support/icon_finder.dart';

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

  testWidgets('desktop composer: one 48 px row, field between + and mic', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        AgentsThreadView(
          controllerBuilder: () async => FakeRelayController(),
          sessionSource: const _FakeSessionSource(),
          threadKey: 'desktop-composer-layout',
          fileSaver: _NoopSaver(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChukChatUIDesktop), findsOneWidget);

    final Finder composer = find.byKey(
      const ValueKey<String>('desktop-composer-box'),
    );
    expect(tester.getSize(composer).height, inInclusiveRange(46, 50));
    final Rect send = tester.getRect(find.byType(ComposerSendButton));
    final Rect field = tester.getRect(
      find.descendant(of: composer, matching: find.byType(TextField)).first,
    );
    final Rect add = tester.getRect(
      find.descendant(of: composer, matching: findIcon(Icons.add_rounded)),
    );
    final Rect mic = tester.getRect(
      find.descendant(of: composer, matching: findIcon(Icons.mic)),
    );
    // An Agents thread has no model picker (CHAT-54).
    expect(
      find.descendant(of: composer, matching: find.byType(ChatModeSelector)),
      findsNothing,
    );

    // One row, one centre line.
    expect(field.left, greaterThanOrEqualTo(add.right));
    expect(mic.left, greaterThanOrEqualTo(field.right));
    expect(send.left, greaterThanOrEqualTo(mic.right));
    for (final Rect r in <Rect>[add, field, send]) {
      expect(r.center.dy, closeTo(mic.center.dy, 2));
    }
  });
}
