// App side of the agent driver: the Agent finder, the screen state and the
// full-app capture (test_driver/agent_extensions.dart).

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/main.dart' show appCaptureBoundaryKey;

import '../../test_driver/agent_extensions.dart';

Widget _app({bool dialog = false}) {
  return RepaintBoundary(
    key: appCaptureBoundaryKey,
    child: MaterialApp(
      home: Scaffold(
        body: Stack(
          children: <Widget>[
            Column(
              children: <Widget>[
                const Text('Hello'),
                const Text('Hello'),
                Semantics(
                  identifier: 'login_email_field',
                  child: const SizedBox(width: 200, child: TextField()),
                ),
                IconButton(
                  tooltip: 'Settings',
                  icon: const Icon(Icons.settings),
                  onPressed: () {},
                ),
                const Text('Hidden below', key: ValueKey<String>('k1')),
              ],
            ),
            if (dialog)
              const Positioned.fill(
                child: ColoredBox(
                  color: Colors.white,
                  child: Center(child: Text('Dialog on top')),
                ),
              ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('Agent finder: every kind finds its widget', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());
    Finder f(String by, String value, {int index = 0}) =>
        agentFinder(AgentFinder(by: by, value: value, index: index));

    expect(f('text', 'Hello'), findsOneWidget);
    expect(f('text', 'Hello', index: 1), findsOneWidget);
    expect(f('text_contains', 'below'), findsOneWidget);
    expect(f('tooltip', 'Settings'), findsOneWidget);
    expect(f('semantics_id', 'login_email_field'), findsOneWidget);
    expect(f('key', 'k1'), findsOneWidget);
    expect(f('type', 'TextField'), findsOneWidget);
    expect(
      f('icon', '0x${Icons.settings.codePoint.toRadixString(16)}'),
      findsOneWidget,
    );
    expect(f('text', 'Nope'), findsNothing);
    expect(f('text', 'Hello', index: 2), findsNothing);
    expect(() => f('xpath', 'x'), throwsArgumentError);
    expect(() => f('icon', 'gear'), throwsArgumentError);
  });

  testWidgets('hittable drops widgets under a covering layer', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app(dialog: true));
    expect(
      agentFinder(const AgentFinder(by: 'text', value: 'Hello')),
      findsOneWidget,
    );
    expect(
      agentFinder(
        const AgentFinder(by: 'text', value: 'Hello', hittable: true),
      ),
      findsNothing,
    );
  });

  test('parseCodePoint reads hex and decimal', () {
    expect(parseCodePoint('0xe5d2'), 0xe5d2);
    expect(parseCodePoint('E5D2'), 0xe5d2);
    expect(parseCodePoint('58834'), 58834);
    expect(parseCodePoint('gear'), isNull);
  });

  testWidgets('collectUiState lists what a tap can reach', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());
    Map<String, Object?> state = collectUiState();
    List<Object?> texts(Map<String, Object?> s) =>
        (s['texts']! as List<Object?>)
            .map((Object? e) => (e! as Map<String, Object?>)['text'])
            .toList();

    expect(texts(state), containsAll(<String>['Hello', 'Hidden below']));
    expect(
      (state['tooltips']! as List<Object?>).single,
      containsPair('tooltip', 'Settings'),
    );
    expect(
      (state['semantics']! as List<Object?>).single,
      containsPair('id', 'login_email_field'),
    );
    expect(
      (state['icons']! as List<Object?>).single,
      containsPair(
        'codePoint',
        '0x${Icons.settings.codePoint.toRadixString(16)}',
      ),
    );
    final Map<String, Object?> field =
        (state['fields']! as List<Object?>).single! as Map<String, Object?>;
    expect(field['value'], '');
    expect(field['rect'], isA<Map<String, int>>());

    await tester.pumpWidget(_app(dialog: true));
    state = collectUiState();
    expect(texts(state), <String>['Dialog on top']);
    final Map<String, Object?> all = collectUiState(includeHidden: true);
    expect(texts(all), contains('Hello'));
  });

  testWidgets('captureApp renders the root boundary', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(_app());
    final ui.Image? image = await tester.runAsync(() => captureApp());
    expect(image, isNotNull);
    expect(image!.width, 800);
    expect(image.height, 600);
    image.dispose();
  });

  testWidgets('focusTextField focuses the field around a hint text', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: Column(
            children: <Widget>[
              TextField(decoration: InputDecoration(hintText: 'Ask me')),
              TextField(decoration: InputDecoration(hintText: 'Other')),
            ],
          ),
        ),
      ),
    );
    focusTextField(const AgentFinder(by: 'text', value: 'Ask me'));
    await tester.pump();
    final List<EditableText> fields = tester
        .widgetList<EditableText>(find.byType(EditableText))
        .toList();
    expect(fields[0].focusNode.hasFocus, isTrue);
    expect(fields[1].focusNode.hasFocus, isFalse);
    expect(
      () => focusTextField(const AgentFinder(by: 'text', value: 'Nope')),
      throwsStateError,
    );
  });

  testWidgets('tapAt sends a real tap', (WidgetTester tester) async {
    int taps = 0;
    await tester.pumpWidget(
      MaterialApp(
        home: Center(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => taps++,
            child: const SizedBox(width: 100, height: 100),
          ),
        ),
      ),
    );
    await tester.runAsync(() => tapAt(const Offset(400, 300)));
    await tester.pump(const Duration(milliseconds: 500));
    expect(taps, 1);
  });
}
