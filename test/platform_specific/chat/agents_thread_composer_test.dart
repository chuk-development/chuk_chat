// The Agents phone thread's composer, as in the original Agents app:
// opening a thread does not take the focus (no keyboard), the AI notice sits
// under the composer, and the plus and mode menus are filled tiles at the
// menu radius with no frame, the plus menu offering Workspace.
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
import 'package:chuk_chat/widgets/chat_mode_selector.dart';
import 'package:chuk_chat/widgets/menu_tile_group.dart';
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

  Future<void> pumpPhoneThread(WidgetTester tester) async {
    tester.view.physicalSize = const Size(412, 915);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.pumpWidget(
      _app(
        AgentsThreadView(
          phoneLayout: true,
          controllerBuilder: () async => FakeRelayController(),
          sessionSource: const _FakeSessionSource(),
          threadKey: 'composer-look',
          fileSaver: _NoopSaver(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ChukChatUIMobile), findsOneWidget);
  }

  bool composerHasFocus(WidgetTester tester) {
    final TextField field = tester.widget<TextField>(
      find.byType(TextField).first,
    );
    return field.focusNode!.hasFocus;
  }

  testWidgets('opening a thread on the phone leaves the keyboard down', (
    tester,
  ) async {
    await pumpPhoneThread(tester);

    expect(
      composerHasFocus(tester),
      isFalse,
      reason: 'the keyboard belongs to a tap on the composer',
    );
    // The AI notice is only there while the composer is not focused.
    expect(
      find.text(
        "You're chatting with an AI \u2014 it can be wrong. Check key info.",
      ),
      findsOneWidget,
    );
  });

  testWidgets('the AI notice folds away while the composer has focus', (
    tester,
  ) async {
    await pumpPhoneThread(tester);

    await tester.tap(find.byType(TextField).first);
    await tester.pumpAndSettle();

    expect(composerHasFocus(tester), isTrue);
    expect(find.textContaining("You're chatting with an AI"), findsNothing);
  });

  testWidgets('the plus menu is filled tiles at the menu radius, with '
      'Workspace', (tester) async {
    await pumpPhoneThread(tester);

    await tester.tap(findIcon(Icons.add_rounded).first);
    await tester.pumpAndSettle();

    expect(find.text('Workspace'), findsOneWidget);
    final MenuTileGroup group = tester.widget<MenuTileGroup>(
      find.byType(MenuTileGroup),
    );
    expect(group.outerRadius, kMenuOuterRadius);
    expect(
      find.ancestor(
        of: find.byType(MenuTileGroup),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).border != null,
        ),
      ),
      findsNothing,
      reason: 'no frame around the menu',
    );
    expect(composerHasFocus(tester), isFalse);
  });

  testWidgets('the mode menu is filled tiles at the menu radius', (
    tester,
  ) async {
    await pumpPhoneThread(tester);

    await tester.tap(find.byType(ChatModeSelector));
    await tester.pumpAndSettle();

    final MenuTileGroup group = tester.widget<MenuTileGroup>(
      find.byType(MenuTileGroup),
    );
    expect(group.outerRadius, kMenuOuterRadius);
    expect(
      find.ancestor(
        of: find.byType(MenuTileGroup),
        matching: find.byWidgetPredicate(
          (Widget w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration! as BoxDecoration).border != null,
        ),
      ),
      findsNothing,
    );
  });
}
