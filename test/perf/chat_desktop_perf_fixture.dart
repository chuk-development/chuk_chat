// The desktop chat screen (`ChukChatUIDesktop`, the plain chat the owner
// uses) with one long chat, for the desktop scroll and rail-jump speed tests:
// `chat_desktop_scroll_perf_test.dart` (widget test, debug, wall clock) and
// `integration_test/chat_desktop_scroll_perf_test.dart` (profile build on
// Linux under Xvfb, the engine's FrameTiming).
//
// The chat: the 300 mixed messages of `scrollPerfTranscript` (markdown,
// lists, tables, code, tool calls) plus 30 more turns, and a picture on every
// tenth question (a 1200x800 PNG as a data URL, decoded like a real one).

import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_desktop.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/widgets/chat_turn_rail.dart';

import '../support/test_app.dart';
import 'chat_scroll_fixture.dart';

const String desktopPerfChatId = 'desktop-perf-chat';

String? _pngDataUrl;

/// A 1200x800 gradient PNG as a data URL, made once.
String desktopPerfImage() {
  return _pngDataUrl ??= () {
    final img.Image picture = img.Image(width: 1200, height: 800);
    for (int y = 0; y < picture.height; y++) {
      for (int x = 0; x < picture.width; x++) {
        picture.setPixelRgb(x, y, x * 255 ~/ 1200, y * 255 ~/ 800, 128);
      }
    }
    final Uint8List png = img.encodePng(picture, level: 1);
    return 'data:image/png;base64,${base64Encode(png)}';
  }();
}

/// The long chat: 330 rows, user and answer in turns.
List<ChatMessage> desktopPerfMessages() {
  final List<Map<String, String>> rows = <Map<String, String>>[
    ...scrollPerfTranscript(),
    ...scrollPerfTranscript().take(30),
  ];
  return <ChatMessage>[
    for (int i = 0; i < rows.length; i++)
      ChatMessage(
        role: rows[i]['sender'] == 'user' ? 'user' : 'assistant',
        text: rows[i]['sender'] == 'user'
            ? 'Question $i: ${"please explain this step in detail. " * (1 + i % 3)}'
            : rows[i]['text'] ?? '',
        modelId: rows[i]['modelId'],
        provider: rows[i]['provider'],
        toolCalls: rows[i]['toolCalls'],
        images: rows[i]['sender'] == 'user' && i % 20 == 0
            ? jsonEncode(<String>[desktopPerfImage()])
            : null,
      ),
  ];
}

/// Puts the long chat in the store under [desktopPerfChatId].
void seedDesktopPerfChat([List<ChatMessage>? messages]) {
  ChatStorageState.chatsById[desktopPerfChatId] = StoredChat(
    id: desktopPerfChatId,
    createdAt: DateTime.utc(2026, 11, 19),
    isStarred: false,
    messages: messages ?? desktopPerfMessages(),
  );
}

void removeDesktopPerfChat() =>
    ChatStorageState.chatsById.remove(desktopPerfChatId);

/// The desktop chat screen with the long chat open.
Widget desktopPerfScreen() => testApp(
  Scaffold(
    body: ChukChatUIDesktop(
      onToggleSidebar: () {},
      selectedChatId: desktopPerfChatId,
      onChatIdChanged: (_) {},
      isSidebarExpanded: false,
      isCompactMode: false,
      showReasoningTokens: false,
      showModelInfo: true,
      showTps: false,
    ),
  ),
);

/// The chat list's scroll position (the one under the rail).
ScrollPosition desktopChatPosition(WidgetTester tester) {
  final ChatTurnRail rail = tester.widget(find.byType(ChatTurnRail));
  final ScrollController? controller = rail.scrollController;
  if (controller == null) throw StateError('the rail has no controller');
  return controller.position;
}

/// The strips of the rail, top to bottom.
List<Rect> desktopRailStrips(WidgetTester tester) {
  final List<Rect> strips =
      find
          .byWidgetPredicate(
            (Widget w) => switch (w.key) {
              ValueKey<String>(:final String value) =>
                w is Positioned && value.startsWith('turn-rail-tick-'),
              _ => false,
            },
          )
          .evaluate()
          .map((Element e) => tester.getRect(find.byWidget(e.widget)))
          .toList()
        ..sort((Rect a, Rect b) => a.top.compareTo(b.top));
  return strips;
}

/// Per-frame scroll offsets, sampled at the end of every frame.
class OffsetSampler {
  OffsetSampler(this.position);

  final ScrollPosition position;
  final List<double> offsets = <double>[];
  bool _on = false;

  void start() {
    _on = true;
    _tick();
  }

  void stop() => _on = false;

  void _tick() {
    if (!_on) return;
    offsets.add(position.pixels);
    SchedulerBinding.instance.addPostFrameCallback((_) => _tick());
  }

  /// How far the list moved in each frame.
  List<double> get steps => <double>[
    for (int i = 1; i < offsets.length; i++)
      (offsets[i] - offsets[i - 1]).abs(),
  ];
}

/// Smoothness of a wheel scroll from its per-frame steps: the largest
/// single-frame jump, and the share of frames inside the motion that did not
/// move at all (a stepped scroll: move, stand, stand, move).
({double maxStep, double stillShare, int frames}) wheelSmoothness(
  List<double> steps,
) {
  int first = steps.indexWhere((double s) => s > 0.5);
  int last = steps.lastIndexWhere((double s) => s > 0.5);
  if (first < 0) return (maxStep: 0, stillShare: 0, frames: 0);
  final List<double> inside = steps.sublist(first, last + 1);
  final int still = inside.where((double s) => s <= 0.5).length;
  return (
    maxStep: inside.reduce((double a, double b) => a > b ? a : b),
    stillShare: still / inside.length,
    frames: inside.length,
  );
}
