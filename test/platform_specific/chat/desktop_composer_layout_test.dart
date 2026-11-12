// The desktop composer's layout on an empty chat, at desktop width.
//
// The send/voice target floats in the top right corner of the box, beside the
// text field's first line. The action row (+, mode pill, microphone) sits
// under the field. Regression: the empty `/`-menu and queue dock in the box's
// column took a share of the free height, so the field slid down below the
// target and the target stood alone on its own row.
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

  testWidgets('desktop composer: target beside the field, one action row', (
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

    final Finder composer = find
        .ancestor(
          of: find.byType(ComposerSendButton),
          matching: find.byType(Stack),
        )
        .first;
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

    // The target shares the field's first line: it does not stand on a row
    // of its own above the text.
    expect(send.left, greaterThanOrEqualTo(field.right));
    expect(
      field.top,
      lessThanOrEqualTo(send.top + 1),
      reason: 'the field starts at the top of the box, level with the target',
    );
    expect(field.top, lessThan(send.center.dy));

    // Every action-row target shares one vertical centre, under the field.
    for (final Rect r in <Rect>[add, mic]) {
      expect(r.center.dy, closeTo(mic.center.dy, 1));
      expect(r.top, greaterThanOrEqualTo(field.bottom));
    }
    expect(send.bottom, lessThanOrEqualTo(mic.top));
  });
}
