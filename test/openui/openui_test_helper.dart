// Test helpers for lib/openui: pump a program, record actions, read
// fixtures. See docs/OPENUI.md, "Tests".

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/constants.dart';
import 'package:chuk_chat/openui/openui.dart';

/// One recorded [OpenUiActionHandler.sendToAssistant] call.
typedef SentMessage = ({
  String text,
  String? context,
  Map<String, Object?>? formValues,
});

/// An [OpenUiActionHandler] that records every call.
class RecordingOpenUiHandler extends OpenUiActionHandler {
  /// The messages sent to the assistant, in order.
  final List<SentMessage> messages = <SentMessage>[];

  /// The URLs opened, in order.
  final List<String> urls = <String>[];

  /// The store snapshots, in order.
  final List<Map<String, Object?>> states = <Map<String, Object?>>[];

  @override
  void sendToAssistant(
    String text, {
    String? context,
    Map<String, Object?>? formValues,
  }) {
    messages.add((text: text, context: context, formValues: formValues));
  }

  @override
  void openUrl(String url) => urls.add(url);

  @override
  void onStateChanged(Map<String, Object?> state) => states.add(state);
}

/// The app theme the gallery and the tests use.
ThemeData openUiTestTheme(Brightness brightness) => buildAppTheme(
  accent: kDefaultAccentColor,
  iconFg: brightness == Brightness.dark
      ? kDefaultIconFgColor
      : const Color(0xFF1A1C20),
  bg: brightness == Brightness.dark ? kDefaultBgColor : const Color(0xFFF8F9FF),
  brightness: brightness,
);

/// Wraps [child] in the app theme, in a chat-bubble-wide column.
Widget openUiTestApp(
  Widget child, {
  Brightness brightness = Brightness.dark,
  double width = OpenUiTokens.chatColumnWidth,
}) {
  return MaterialApp(
    debugShowCheckedModeBanner: false,
    theme: openUiTestTheme(brightness),
    home: Scaffold(
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(width: width, child: child),
        ),
      ),
    ),
  );
}

/// Pumps [source] in an [OpenUiView] and settles. Returns the handler
/// that records the actions.
Future<RecordingOpenUiHandler> pumpOpenUi(
  WidgetTester tester,
  String source, {
  bool isStreaming = false,
  Brightness brightness = Brightness.dark,
  OpenUiLibrary? library,
  Map<String, ToolExecutor>? tools,
  RecordingOpenUiHandler? handler,
  bool settle = true,
}) async {
  final h = handler ?? RecordingOpenUiHandler();
  await tester.pumpWidget(
    openUiTestApp(
      OpenUiView(
        source: source,
        isStreaming: isStreaming,
        actionHandler: h,
        library: library,
        tools: tools,
      ),
      brightness: brightness,
    ),
  );
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
  return h;
}

/// The fixture directory (canonical upstream example programs).
const String openUiFixtureDir = 'test/openui/fixtures';

/// Every `*.oui` fixture, by file name, sorted.
Map<String, String> readOpenUiFixtures() {
  final files =
      Directory(openUiFixtureDir)
          .listSync()
          .whereType<File>()
          .where((f) => f.path.endsWith('.oui'))
          .toList()
        ..sort((a, b) => a.path.compareTo(b.path));
  return <String, String>{
    for (final f in files) f.uri.pathSegments.last: f.readAsStringSync(),
  };
}
