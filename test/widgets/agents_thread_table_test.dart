// An Agents answer draws chuk_chat's own markdown table (one widget, one
// style, one scrollbar), the table pans sideways on a desktop, and a file the
// coworker hands over sits right under the answer text, above the meta line
// and the action row (bead chuk_chat-ac0n).

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/platform_specific/chat/widgets/chat_message_list_item.dart';
import 'package:chuk_chat/services/account_session.dart';
import 'package:chuk_chat/services/agents/agent_file_saver.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_relay_link.dart';
import 'package:chuk_chat/services/agents/agents_replay_loader.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/settings/verbose_service.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/widgets/agents_thread_view.dart';
import 'package:chuk_chat/widgets/chuk_table_classic.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/sandbox_artifact_block.dart';

import '../support/fake_relay_controller.dart';
import '../support/test_app.dart';

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

const String _wideTable =
    'Hier sind die Bilder:\n\n'
    '| Datei | Titel | Quelle |\n'
    '|---|---|---|\n'
    '| 1-hamburg-yah-thecoffeemugshop-extra-long-name.jpg '
    '| Starbucks You Are Here - Hamburg edition with a long title '
    '| [The Coffee Mug Shop Deutschland](https://example.com/hamburg) |\n'
    '| 2-muenchen-yah-thecoffeemugshop-extra-long-name.jpg '
    '| Starbucks You Are Here - Muenchen edition with a long title '
    '| [The Coffee Mug Shop Deutschland](https://example.com/muenchen) |\n'
    '\nAlle Bilder stammen direkt von der Produktseite.';

/// A Linux desktop: a mouse, a wheel and a trackpad, and chuk's desktop
/// scrollbar.
final TargetPlatformVariant _linux = TargetPlatformVariant.only(
  TargetPlatform.linux,
);

const String _answerText = 'Alle Bilder stammen direkt von der Produktseite.';

final Finder _tableScroller = find.descendant(
  of: find.byType(ChukTableClassic),
  matching: find.byWidgetPredicate(
    (Widget w) =>
        w is SingleChildScrollView && w.scrollDirection == Axis.horizontal,
  ),
);

/// The horizontal scroller inside the one table on screen.
ScrollPosition _tablePosition(WidgetTester tester) =>
    tester.widget<SingleChildScrollView>(_tableScroller).controller!.position;

Rect _tableScrollbarRect(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(ChukTableClassic),
    matching: find.byType(Scrollbar),
  ),
);

/// Everything that decides how the table looks and pans, read off the tree.
Map<String, Object?> _tableLook(WidgetTester tester) {
  final ChukTableClassic table = tester.widget<ChukTableClassic>(
    find.byType(ChukTableClassic),
  );
  final Scrollbar bar = tester.widget<Scrollbar>(
    find.descendant(
      of: find.byType(ChukTableClassic),
      matching: find.byType(Scrollbar),
    ),
  );
  final BuildContext scroller = tester.element(_tableScroller);
  return <String, Object?>{
    'type': table.runtimeType,
    'textColor': table.textColor,
    'accentColor': table.accentColor,
    'fontFamily': table.fontFamily,
    'fontSize': table.fontSize,
    'thumbVisibility': bar.thumbVisibility,
    'interactive': bar.interactive,
    'thickness': bar.thickness,
    'scrollbarTheme': Theme.of(scroller).scrollbarTheme,
    'dragDevices': ScrollConfiguration.of(scroller).dragDevices,
    'width': tester.getSize(find.byType(ChukTableClassic)).width,
  };
}

/// Drags the thumb, then shift + wheel, a sideways wheel and a trackpad pan:
/// each one has to move the table sideways.
Future<void> _expectPansSideways(WidgetTester tester) async {
  final ScrollPosition pos = _tablePosition(tester);
  expect(pos.maxScrollExtent, greaterThan(100), reason: 'the table must pan');
  final Rect bar = _tableScrollbarRect(tester);

  // The thumb, pressed and moved the way a hand moves a mouse: in small steps.
  pos.jumpTo(0);
  await tester.pump();
  final TestGesture drag = await tester.startGesture(
    Offset(bar.left + 20, bar.bottom - 5),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  for (int i = 0; i < 60; i++) {
    await drag.moveBy(const Offset(1, 0));
    await tester.pump(const Duration(milliseconds: 8));
  }
  await drag.up();
  await tester.pumpAndSettle();
  expect(pos.pixels, greaterThan(60), reason: 'dragging the thumb pans');

  // Shift + the mouse wheel.
  pos.jumpTo(0);
  await tester.pump();
  final TestPointer mouse = TestPointer(7, PointerDeviceKind.mouse);
  await tester.sendEventToBinding(mouse.hover(bar.center));
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendEventToBinding(mouse.scroll(const Offset(0, 120)));
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pumpAndSettle();
  expect(pos.pixels, greaterThan(0), reason: 'shift + wheel pans');

  // A tilt wheel or a horizontal wheel.
  pos.jumpTo(0);
  await tester.pump();
  await tester.sendEventToBinding(mouse.scroll(const Offset(120, 0)));
  await tester.pumpAndSettle();
  expect(pos.pixels, greaterThan(0), reason: 'a sideways wheel pans');

  // Two fingers on a trackpad.
  pos.jumpTo(0);
  await tester.pump();
  final TestGesture pad = await tester.createGesture(
    kind: PointerDeviceKind.trackpad,
  );
  await pad.panZoomStart(bar.center);
  await tester.pump();
  for (int i = 1; i <= 6; i++) {
    await pad.panZoomUpdate(bar.center, pan: Offset(-20.0 * i, 0));
    await tester.pump(const Duration(milliseconds: 8));
  }
  await pad.panZoomEnd();
  await tester.pumpAndSettle();
  expect(pos.pixels, greaterThan(0), reason: 'a trackpad pans');
  pos.jumpTo(0);
  await tester.pump();
}

/// chuk_chat's plain desktop transcript around one answer: a selection area,
/// the vertical list, and the bubble as the list item builds it.
Widget _plainChat(String text, {double width = 760}) => testApp(
  Scaffold(
    body: Align(
      alignment: Alignment.topCenter,
      child: SizedBox(
        width: width,
        child: SelectionArea(
          child: ListView(
            children: <Widget>[
              MessageBubble(
                message: text,
                isUser: false,
                maxWidth: width,
                useSharedSelectionArea: true,
              ),
            ],
          ),
        ),
      ),
    ),
  ),
);

void main() {
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);
  ChatOrigin.agentsEnabled = true;
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
    await VerboseService.instance.setEnabled(false);
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  void desktopWindow(WidgetTester tester) {
    tester.view.physicalSize = const Size(900, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  /// The desktop Agents thread (the imported chuk chat screen on the relay),
  /// paired.
  Future<FakeRelayController> pumpThread(WidgetTester tester) async {
    desktopWindow(tester);
    final FakeRelayController controller = FakeRelayController();
    await tester.pumpWidget(
      testApp(
        Scaffold(
          body: AgentsThreadView(
            controllerBuilder: () async => controller,
            sessionSource: const _FakeSessionSource(),
            threadKey: 'thread-1',
            fileSaver: _NoopSaver(),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    controller.set(
      const AgentsRelayState(
        phase: AgentsRelayPhase.paired,
        peerDeviceId: 'cowork-host',
      ),
    );
    await tester.pumpAndSettle();
    return controller;
  }

  Future<void> closeThread(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await MultiplexSession.shutdown();
    await tester.pumpAndSettle();
  }

  testWidgets('the Agents thread draws the table chuk chat draws', (
    tester,
  ) async {
    final FakeRelayController controller = await pumpThread(tester);
    controller.emit(
      const AgentsRelayRunState(sessionKey: 'thread-1', state: 'idle'),
    );
    controller.emit(const AgentsRelayUser('Bilder bitte', mid: 1));
    controller.emit(const AgentsRelayDelta(_wideTable, replay: true, mid: 2));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    await tester.pumpAndSettle();

    // The answer reaches the table through chuk's own list item and bubble.
    expect(
      find.ancestor(
        of: find.byType(ChukTableClassic),
        matching: find.byType(ChatMessageListItem),
      ),
      findsOneWidget,
    );
    final Map<String, Object?> agents = _tableLook(tester);
    final double bubbleWidth = tester
        .getSize(
          find
              .ancestor(
                of: find.byType(ChukTableClassic),
                matching: find.byType(MessageBubble),
              )
              .first,
        )
        .width;
    await closeThread(tester);

    // The same answer in a plain chuk chat of the same width.
    await tester.pumpWidget(_plainChat(_wideTable, width: bubbleWidth));
    await tester.pumpAndSettle();
    final Map<String, Object?> chat = _tableLook(tester);

    expect(agents, chat);
    expect(agents['type'], ChukTableClassic);
  }, variant: _linux);

  testWidgets('a wide table pans sideways in a long Agents thread', (
    tester,
  ) async {
    final FakeRelayController controller = await pumpThread(tester);
    controller.emit(
      const AgentsRelayRunState(sessionKey: 'thread-1', state: 'idle'),
    );
    // Long enough that the thread opens anchored at its bottom: the table's
    // row is then in the transcript's history half.
    int mid = 1;
    for (int i = 0; i < 20; i++) {
      controller.emit(AgentsRelayUser('Frage $i ' * 20, mid: mid++));
      controller.emit(
        AgentsRelayDelta('Antwort $i ' * 60, replay: true, mid: mid++),
      );
    }
    controller.emit(AgentsRelayUser('Bilder bitte', mid: mid++));
    controller.emit(AgentsRelayDelta(_wideTable, replay: true, mid: mid++));
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    await tester.pumpAndSettle();

    // Bring the table up from behind the composer.
    final ScrollableState transcript = tester.state<ScrollableState>(
      find
          .ancestor(
            of: find.byType(ChukTableClassic),
            matching: find.byWidgetPredicate(
              (Widget w) =>
                  w is Scrollable && w.axisDirection == AxisDirection.down,
            ),
          )
          .first,
    );
    transcript.position.jumpTo(transcript.position.pixels + 400);
    await tester.pumpAndSettle();
    expect(_tableScrollbarRect(tester).bottom, lessThan(800));

    await _expectPansSideways(tester);
    await closeThread(tester);
  }, variant: _linux);

  testWidgets('the same table pans sideways in a plain chat', (tester) async {
    desktopWindow(tester);
    await tester.pumpWidget(_plainChat(_wideTable));
    await tester.pumpAndSettle();
    await _expectPansSideways(tester);
  }, variant: _linux);

  group('a file under an answer', () {
    const List<ContentBlock> textAndFile = <ContentBlock>[
      ContentBlock.text(_answerText),
      ContentBlock.sandboxArtifact(
        SandboxArtifactPayload(
          storagePath: 'user/tassen.enc',
          filename: 'starbucks-tassen-deutschland.zip',
          mime: 'application/zip',
          sizeBytes: 2400000,
        ),
      ),
    ];

    List<MessageBubbleAction> copyAction() => <MessageBubbleAction>[
      MessageBubbleAction(
        icon: Icons.copy_rounded,
        tooltip: 'Copy',
        onPressed: () {},
      ),
    ];

    Future<void> pumpAnswer(WidgetTester tester, MessageBubble bubble) async {
      desktopWindow(tester);
      await tester.pumpWidget(
        testApp(
          Scaffold(
            body: SelectionArea(child: ListView(children: <Widget>[bubble])),
          ),
        ),
      );
      await tester.pumpAndSettle();
    }

    final Finder meta = find.textContaining('z-ai/glm-5.3-flash');
    final Finder card = find.byType(SandboxArtifactBlock);
    final Finder copy = find.byTooltip('Copy');

    /// The action pill: the decorated box around the copy button.
    Rect pillRect(WidgetTester tester) => tester.getRect(
      find
          .ancestor(
            of: copy,
            matching: find.byWidgetPredicate(
              (Widget w) => w is Container && w.decoration is BoxDecoration,
            ),
          )
          .first,
    );

    Rect textRect(WidgetTester tester) =>
        tester.getRect(find.textContaining(_answerText).last);

    testWidgets('comes right after the text, then the meta line, then the '
        'action row', (tester) async {
      await pumpAnswer(
        tester,
        MessageBubble(
          message: _answerText,
          isUser: false,
          maxWidth: 700,
          useSharedSelectionArea: true,
          showModelInfo: true,
          modelLabel: 'z-ai/glm-5.3-flash',
          modelProvider: 'fireworks/serverless',
          workedFor: const Duration(minutes: 2, seconds: 24),
          actions: copyAction(),
          contentBlocks: textAndFile,
        ),
      );

      final Rect text = textRect(tester);
      final Rect file = tester.getRect(card);
      final Rect line = tester.getRect(meta);
      final Rect pill = pillRect(tester);
      expect(file.top, greaterThan(text.bottom));
      expect(line.top, greaterThan(file.bottom));
      expect(pill.top, greaterThan(line.bottom));
      expect(tester.widget<Text>(meta).data, contains('2m 24s'));

      // Even air: text to card, card to the meta line's row.
      final Rect lineRow = tester.getRect(
        find.ancestor(of: meta, matching: find.byType(Row)).first,
      );
      final double above = file.top - text.bottom;
      final double below = lineRow.top - file.bottom;
      expect(above, moreOrLessEquals(below, epsilon: 0.5));
      expect(above, inInclusiveRange(10.0, 14.0));
    });

    testWidgets('keeps the same air above the action row without a meta '
        'line', (tester) async {
      await pumpAnswer(
        tester,
        MessageBubble(
          message: _answerText,
          isUser: false,
          maxWidth: 700,
          useSharedSelectionArea: true,
          showModelInfo: false,
          actions: copyAction(),
          contentBlocks: textAndFile,
        ),
      );
      expect(meta, findsNothing);
      final Rect text = textRect(tester);
      final Rect file = tester.getRect(card);
      final Rect pill = pillRect(tester);
      final double above = file.top - text.bottom;
      final double below = pill.top - file.bottom;
      expect(above, moreOrLessEquals(below, epsilon: 0.5));
    });

    testWidgets('an answer without a file keeps its meta line under the '
        'text', (tester) async {
      await pumpAnswer(
        tester,
        MessageBubble(
          message: _answerText,
          isUser: false,
          maxWidth: 700,
          useSharedSelectionArea: true,
          showModelInfo: true,
          modelLabel: 'z-ai/glm-5.3-flash',
          workedFor: const Duration(seconds: 12),
          actions: copyAction(),
          contentBlocks: const <ContentBlock>[ContentBlock.text(_answerText)],
        ),
      );
      final Rect text = textRect(tester);
      final Rect line = tester.getRect(meta);
      final Rect pill = pillRect(tester);
      expect(line.top, greaterThan(text.bottom));
      expect(line.top - text.bottom, lessThan(14));
      expect(pill.top, greaterThan(line.bottom));
    });
  });

  testWidgets('a file in the Agents thread follows the answer text', (
    tester,
  ) async {
    // The file is stored for real, so the run gets real time below. The
    // screen's microphone and temp-dir clean-up then reach their channels.
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    for (final String channel in <String>[
      'com.llfbandit.record/messages',
      'plugins.flutter.io/path_provider',
    ]) {
      messenger.setMockMethodCallHandler(
        MethodChannel(channel),
        (MethodCall call) async => null,
      );
      addTearDown(
        () => messenger.setMockMethodCallHandler(MethodChannel(channel), null),
      );
    }
    final FakeRelayController controller = await pumpThread(tester);
    controller.emit(
      const AgentsRelayRunState(sessionKey: 'thread-1', state: 'idle'),
    );
    controller.emit(const AgentsRelayUser('Zip bitte', mid: 1));
    controller.emit(const AgentsRelayDelta(_answerText, replay: true, mid: 2));
    controller.emit(
      AgentsRelayFile(
        name: 'starbucks-tassen-deutschland.zip',
        mimeType: 'application/zip',
        declaredSize: 4,
        bytes: Uint8List.fromList(<int>[80, 75, 5, 6]),
        replay: true,
        mid: 3,
      ),
    );
    controller.emit(const AgentsRelayDone(reason: 'replay', replay: true));
    for (int i = 0; i < 5; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
    }
    final Rect text = tester.getRect(find.textContaining(_answerText).last);
    final Rect file = tester.getRect(find.byType(SandboxArtifactBlock).first);
    expect(file.top, greaterThan(text.bottom));
    expect(file.top - text.bottom, lessThan(24));
    await closeThread(tester);
  });
}
