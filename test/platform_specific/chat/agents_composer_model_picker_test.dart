// CHAT-54: an Agents thread has no model picker. The agent's model is set
// only in its settings ("Model" -> AgentModelPage); an agent with no model
// of its own runs on DeepSeek V4.1 Flash. chuk_chat's own composer keeps its
// Fast / Thinking picker unchanged.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agent_model.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/chat_model_selection_service.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/chat_mode_selector.dart';

import '../../support/fake_relay_controller.dart';

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

/// The chat screen builds an AudioRecorder on mount; no plugin in a test.
void _silenceRecorder(WidgetTester tester) {
  const MethodChannel record = MethodChannel('com.llfbandit.record/messages');
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    record,
    (MethodCall call) async => null,
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      record,
      null,
    ),
  );
}

void main() {
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);
  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatModelSelectionService.instance.clearMemoryForTesting();
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

  Future<void> pumpThread(WidgetTester tester, {required bool phone}) async {
    _silenceRecorder(tester);
    tester.view.physicalSize = phone
        ? const Size(412, 915)
        : const Size(1440, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(
        AgentsThreadView(
          phoneLayout: phone,
          controllerBuilder: () async => FakeRelayController(),
          sessionSource: const _FakeSessionSource(),
          threadKey: 'no-picker',
          fileSaver: _NoopSaver(),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  group('the Agents composer has no model picker', () {
    testWidgets('on the phone', (tester) async {
      await pumpThread(tester, phone: true);
      expect(find.byType(ChukChatUIMobile), findsOneWidget);
      expect(find.byType(ChatModeSelector), findsNothing);
      expect(find.text('More models'), findsNothing);
    });

    testWidgets('on the desktop', (tester) async {
      await pumpThread(tester, phone: false);
      expect(find.byType(ChukChatUIDesktop), findsOneWidget);
      expect(find.byType(ChatModeSelector), findsNothing);
      expect(find.text('More models'), findsNothing);
    });
  });

  group("chuk_chat's composer keeps its model picker", () {
    testWidgets('on the phone', (tester) async {
      _silenceRecorder(tester);
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          ChukChatUIMobile(
            onToggleSidebar: () {},
            selectedChatId: null,
            onChatIdChanged: (_) {},
            isSidebarExpanded: false,
            showReasoningTokens: false,
            showModelInfo: false,
            showTps: false,
            autoSendVoiceTranscription: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatModeSelector), findsOneWidget);
    });

    testWidgets('on the desktop', (tester) async {
      _silenceRecorder(tester);
      tester.view.physicalSize = const Size(1440, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        _app(
          ChukChatUIDesktop(
            onToggleSidebar: () {},
            selectedChatId: null,
            onChatIdChanged: (_) {},
            isSidebarExpanded: false,
            isCompactMode: false,
            showReasoningTokens: false,
            showModelInfo: false,
            showTps: false,
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ChatModeSelector), findsOneWidget);
    });
  });

  group('the agent default model', () {
    test('is DeepSeek V4.1 Flash', () async {
      expect(AgentModel.defaultModelId, 'deepseek/deepseek-v4.1-flash-1017');
      expect(AgentModel.fallbackState().modelId, AgentModel.defaultModelId);
      expect(AgentModel.defaultSelection.modelId, AgentModel.defaultModelId);
    });

    test('an agent with no own model resolves to it', () async {
      final AgentModelState state = await AgentModel.resolveOrFallback(
        'host:no-own-model',
      );
      expect(state.followsDefault, isTrue);
      expect(state.modelId, 'deepseek/deepseek-v4.1-flash-1017');
    });
  });
}
