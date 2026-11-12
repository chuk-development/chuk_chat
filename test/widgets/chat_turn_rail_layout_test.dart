// The message minimap on the real desktop screens, in both halves of the
// app: the plain chat (`ChukChatUIDesktop`) and an Agents thread (in
// `MessengerShell`). In every window size and for short and long chats the
// rail's middle is the middle of the chat area: between the header line and
// the window's bottom edge (the list runs behind the composer, as in
// T3 Code). It never reaches into the composer. The hover card's first
// text line sits on the hovered strip.
//
// Set CHUK_RAIL_SHOT=<dir> to also write a PNG of each case there.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/widgets/chat_turn_rail.dart';

import '../perf/chat_scroll_screen_fixture.dart';
import '../perf/perf_support.dart';
import '../support/test_app.dart';

const Timeout _guard = Timeout(Duration(minutes: 3));

const List<Size> _sizes = <Size>[
  Size(1440, 1035),
  Size(1920, 1080),
  Size(1440, 900),
];

/// [turns] questions, each with an answer.
List<Map<String, String>> _transcript(int turns) => <Map<String, String>>[
  for (int i = 0; i < turns; i++) ...<Map<String, String>>[
    <String, String>{'sender': 'user', 'text': 'Question $i, please help.'},
    <String, String>{
      'sender': 'ai',
      'text': 'Answer $i. ${"The assistant explains a step. " * 6}',
    },
  ],
];

Future<void> _shot(WidgetTester tester, String name) async {
  final String? dir = Platform.environment['CHUK_RAIL_SHOT'];
  if (dir == null || dir.isEmpty) return;
  final RenderRepaintBoundary boundary = tester.renderObject(
    find.byType(RepaintBoundary).first,
  );
  await tester.runAsync(() async {
    final ui.Image image = await boundary.toImage();
    final ByteData? png = await image.toByteData(
      format: ui.ImageByteFormat.png,
    );
    await File('$dir/$name.png').writeAsBytes(png!.buffer.asUint8List());
  });
}

/// Measures the rail on screen and checks it; returns the strips.
List<Rect> _expectCentred(WidgetTester tester, String label) {
  final Finder rail = find.byType(ChatTurnRail);
  expect(rail, findsOneWidget, reason: '$label: no minimap on the screen');
  final ChatTurnRail widget = tester.widget(rail);
  final Rect pane = tester.getRect(rail);
  final List<Rect> strips =
      find
          .byWidgetPredicate(
            (w) =>
                w is Positioned &&
                w.key is ValueKey<String> &&
                (w.key! as ValueKey<String>).value.startsWith(
                  'turn-rail-tick-',
                ),
          )
          .evaluate()
          .map((e) => tester.getRect(find.byWidget(e.widget)))
          .toList()
        ..sort((a, b) => a.top.compareTo(b.top));
  expect(strips.length, greaterThanOrEqualTo(2), reason: label);

  final double areaTop = pane.top + widget.topPadding;
  final double areaCentre = (areaTop + pane.bottom) / 2;
  final double composerTop = pane.bottom - widget.bottomPadding;
  final double railCentre =
      (strips.first.center.dy + strips.last.center.dy) / 2;
  // ignore: avoid_print
  print(
    '$label: area ${areaTop.toStringAsFixed(1)}..${pane.bottom} '
    '(middle ${areaCentre.toStringAsFixed(1)}), composer from '
    '${composerTop.toStringAsFixed(1)}, strips '
    '${strips.first.center.dy.toStringAsFixed(1)}..'
    '${strips.last.center.dy.toStringAsFixed(1)} '
    '(middle ${railCentre.toStringAsFixed(1)}), ${strips.length} strips',
  );
  expect(
    (railCentre - areaCentre).abs(),
    lessThanOrEqualTo(1.0),
    reason: label,
  );
  expect(strips.first.top, greaterThanOrEqualTo(areaTop), reason: label);
  expect(strips.last.bottom, lessThanOrEqualTo(composerTop), reason: label);
  final double step = strips[1].center.dy - strips[0].center.dy;
  for (int i = 1; i < strips.length; i++) {
    expect(
      (strips[i].center.dy - strips[i - 1].center.dy - step).abs(),
      lessThan(0.01),
      reason: label,
    );
  }
  return strips;
}

/// Hovers the middle strip; the card's first line must sit on it.
Future<void> _expectCardOnStrip(
  WidgetTester tester,
  List<Rect> strips,
  String label,
) async {
  final Rect hovered = strips[strips.length ~/ 2];
  final TestGesture mouse = await tester.createGesture(
    kind: PointerDeviceKind.mouse,
  );
  await mouse.addPointer(location: hovered.center);
  await mouse.moveTo(hovered.center);
  await tester.pump(const Duration(milliseconds: 200));
  final Finder firstLine = find.byKey(
    const ValueKey<String>('turn-rail-preview-first-line'),
  );
  expect(firstLine, findsOneWidget, reason: label);
  final double line = tester.getRect(firstLine).center.dy;
  expect((line - hovered.center.dy).abs(), lessThan(1.0), reason: label);
  // The strips do not move while the card is open.
  final List<Rect> open = _expectCentred(tester, '$label (hover)');
  expect(open.first.top, strips.first.top, reason: label);
  await _shot(tester, '${label.replaceAll(' ', '_')}_hover');
  await mouse.removePointer();
}

void main() {
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);
  ChatOrigin.agentsEnabled = true;
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeDisk disk;
  setUp(() async {
    await resetScreenWorld();
    disk = FakeDisk();
  });
  tearDown(() async {
    await MultiplexSession.shutdown();
    await resetScreenWorld();
  });

  for (final Size size in _sizes) {
    final String px = '${size.width.toInt()}x${size.height.toInt()}';
    for (final int turns in const <int>[5, 150]) {
      testWidgets('Agents thread, $turns questions, $px: rail centred', (
        tester,
      ) async {
        silenceUnrelatedPlugins(tester);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await mountRealScreenThread(
          tester,
          disk,
          transcript: _transcript(turns),
        );
        await tester.pump(const Duration(milliseconds: 300));
        final String label = 'agents $turns $px';
        final List<Rect> strips = _expectCentred(tester, label);
        await _shot(tester, label.replaceAll(' ', '_'));
        await _expectCardOnStrip(tester, strips, label);

        await releaseIdleTimers(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 3));
      }, timeout: _guard);

      testWidgets('plain chat, $turns questions, $px: rail centred', (
        tester,
      ) async {
        silenceUnrelatedPlugins(tester);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        const String chatId = 'rail-layout-chat';
        ChatStorageState.chatsById[chatId] = StoredChat(
          id: chatId,
          createdAt: DateTime.utc(2026, 11, 12),
          isStarred: false,
          messages: <ChatMessage>[
            for (final Map<String, String> row in _transcript(turns))
              ChatMessage(
                role: row['sender'] == 'user' ? 'user' : 'assistant',
                text: row['text']!,
              ),
          ],
        );
        await tester.pumpWidget(
          testApp(
            Scaffold(
              body: ChukChatUIDesktop(
                onToggleSidebar: () {},
                selectedChatId: chatId,
                onChatIdChanged: (_) {},
                isSidebarExpanded: false,
                isCompactMode: false,
                showReasoningTokens: false,
                showModelInfo: false,
                showTps: false,
                // The Agents build's header band (Chat | Agents switch).
                topInset: 52,
              ),
            ),
          ),
        );
        for (int i = 0; i < 20; i++) {
          await tester.pump(const Duration(milliseconds: 50));
        }
        final String label = 'chat $turns $px';
        final List<Rect> strips = _expectCentred(tester, label);
        await _shot(tester, label.replaceAll(' ', '_'));
        await _expectCardOnStrip(tester, strips, label);

        await releaseIdleTimers(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 3));
        ChatStorageState.chatsById.remove(chatId);
      }, timeout: _guard);
    }
  }
}
