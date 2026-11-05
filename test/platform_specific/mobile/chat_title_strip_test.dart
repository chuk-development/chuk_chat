import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';

const List<SwipeChatEntry> _entries = <SwipeChatEntry>[
  SwipeChatEntry(id: 'a', title: 'Alpha', subtitle: 'first', unread: true),
  SwipeChatEntry(
    id: 'b',
    title: 'Beta',
    subtitle: 'second line',
    leading: Icon(Icons.person, key: ValueKey<String>('face_b')),
  ),
  SwipeChatEntry(id: 'c', title: 'Gamma', subtitle: 'third', working: true),
];

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('shows title, subtitle, leading and the position dots', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(const ChatTitleStrip(entries: _entries, selectedId: 'b')),
    );
    final Finder current = find.byKey(
      const ValueKey<String>('chat_title_strip_current'),
    );
    expect(
      find.descendant(of: current, matching: find.text('Beta')),
      findsOneWidget,
    );
    expect(find.text('second line'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('face_b')), findsOneWidget);
    // The position is a dot row, not "2/3" text.
    expect(find.text('2/3'), findsNothing);
    final Finder dots = find.byKey(
      const ValueKey<String>('chat_title_strip_position'),
    );
    expect(dots, findsOneWidget);
    expect(
      tester.widget(
        find.descendant(of: dots, matching: find.byType(CustomPaint)).first,
      ),
      isA<CustomPaint>(),
    );
    expect(
      tester.getSize(find.byType(ChatTitleStrip)).height,
      kChatTitleStripHeight,
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Beta')),
      isSemantics(label: 'Beta', value: '2/3'),
    );
    handle.dispose();
  });

  testWidgets('the neighbours peek in at rest, dimmed, on their side', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(const ChatTitleStrip(entries: _entries, selectedId: 'b')),
    );
    final Finder prev = find.byKey(
      const ValueKey<String>('chat_title_strip_a'),
    );
    final Finder next = find.byKey(
      const ValueKey<String>('chat_title_strip_c'),
    );
    final Finder current = find.byKey(
      const ValueKey<String>('chat_title_strip_current'),
    );
    expect(prev, findsOneWidget);
    expect(next, findsOneWidget);
    expect(
      find.descendant(of: prev, matching: find.text('Alpha')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: next, matching: find.text('Gamma')),
      findsOneWidget,
    );
    final double mid = tester.getCenter(current).dx;
    expect(tester.getCenter(prev).dx, lessThan(mid));
    expect(tester.getCenter(next).dx, greaterThan(mid));
    // A peek is one quiet line: no subtitle.
    expect(find.text('first'), findsNothing);
    final Opacity peek = tester.widget(
      find.descendant(of: next, matching: find.byType(Opacity)).first,
    );
    final Opacity middle = tester.widget(
      find.descendant(of: current, matching: find.byType(Opacity)).first,
    );
    expect(peek.opacity, lessThan(middle.opacity));
  });

  testWidgets('unread shows as a dot next to the title, no edge dots', (
    WidgetTester tester,
  ) async {
    Finder dotIn(Finder of) => find.descendant(
      of: of,
      matching: find.byWidgetPredicate(
        (Widget w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration! as BoxDecoration).shape == BoxShape.circle,
      ),
    );
    await tester.pumpWidget(
      _app(const ChatTitleStrip(entries: _entries, selectedId: 'a')),
    );
    final Finder current = find.byKey(
      const ValueKey<String>('chat_title_strip_current'),
    );
    expect(dotIn(current), findsOneWidget);
    expect(
      dotIn(find.byKey(const ValueKey<String>('chat_title_strip_b'))),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat_strip_unread_l')),
      findsNothing,
    );
    expect(
      find.byKey(const ValueKey<String>('chat_strip_unread_r')),
      findsNothing,
    );
    // Beside the title, on the same line.
    final Rect title = tester.getRect(
      find.descendant(of: current, matching: find.text('Alpha')),
    );
    final Rect dot = tester.getRect(dotIn(current));
    expect(dot.left, greaterThanOrEqualTo(title.right));
    expect(dot.center.dy, closeTo(title.center.dy, 2));
  });

  testWidgets('follows the drag progress like a carousel', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<double> progress = ValueNotifier<double>(0);
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      _app(
        ChatTitleStrip(entries: _entries, selectedId: 'b', progress: progress),
      ),
    );
    final Finder current = find.byKey(
      const ValueKey<String>('chat_title_strip_current'),
    );
    final Finder next = find.byKey(
      const ValueKey<String>('chat_title_strip_c'),
    );
    final Finder prev = find.byKey(
      const ValueKey<String>('chat_title_strip_a'),
    );
    final double restMid = tester.getCenter(current).dx;
    final double restNext = tester.getCenter(next).dx;
    final double restPrev = tester.getCenter(prev).dx;

    progress.value = -0.4; // 40 % towards the next entry
    await tester.pump();
    expect(tester.getCenter(current).dx, lessThan(restMid));
    expect(tester.getCenter(next).dx, lessThan(restNext));
    expect(
      tester.getCenter(next).dx,
      greaterThan(tester.getCenter(current).dx),
    );

    progress.value = 0.5; // towards the previous entry
    await tester.pump();
    expect(tester.getCenter(current).dx, greaterThan(restMid));
    expect(tester.getCenter(prev).dx, greaterThan(restPrev));
  });

  testWidgets('tap in the middle calls onTap; there is no long press', (
    WidgetTester tester,
  ) async {
    int taps = 0;
    await tester.pumpWidget(
      _app(
        ChatTitleStrip(entries: _entries, selectedId: 'b', onTap: () => taps++),
      ),
    );
    await tester.tap(find.byType(ChatTitleStrip));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(
      find.descendant(
        of: find.byType(ChatTitleStrip),
        matching: find.byWidgetPredicate(
          (Widget w) => w is GestureDetector && w.onLongPress != null,
        ),
      ),
      findsNothing,
    );
    // No chevron: the only icon is the face of the entry.
    expect(
      find.descendant(
        of: find.byType(ChatTitleStrip),
        matching: find.byWidgetPredicate(
          (Widget w) => w is Icon && w.key != const ValueKey<String>('face_b'),
        ),
      ),
      findsNothing,
    );
  });

  testWidgets('with a pager, a tap on an edge steps, the middle calls onTap', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    // No working entry: its dots never settle.
    const List<SwipeChatEntry> still = <SwipeChatEntry>[
      SwipeChatEntry(id: 'a', title: 'Alpha'),
      SwipeChatEntry(id: 'b', title: 'Beta'),
      SwipeChatEntry(id: 'c', title: 'Gamma'),
    ];
    String selected = 'b';
    int taps = 0;
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                ChatTitleStrip(
                  entries: still,
                  selectedId: selected,
                  controller: controller,
                  margin: EdgeInsets.zero,
                  onTap: () => taps++,
                ),
                Expanded(
                  child: SwipeChatPager(
                    entries: still,
                    selectedId: selected,
                    controller: controller,
                    onSelected: (String id) => setState(() => selected = id),
                    child: const SizedBox.expand(),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final Rect bar = tester.getRect(find.byType(ChatTitleStrip));
    await tester.tapAt(Offset(bar.left + bar.width * 0.5, bar.center.dy));
    await tester.pumpAndSettle();
    expect(taps, 1);
    expect(selected, 'b');

    await tester.tapAt(Offset(bar.left + bar.width * 0.9, bar.center.dy));
    await tester.pumpAndSettle();
    expect(selected, 'c');

    // At the last entry the right edge has nowhere to go: it is a plain tap.
    await tester.tapAt(Offset(bar.left + bar.width * 0.9, bar.center.dy));
    await tester.pumpAndSettle();
    expect(selected, 'c');
    expect(taps, 2);

    await tester.tapAt(Offset(bar.left + bar.width * 0.1, bar.center.dy));
    await tester.pumpAndSettle();
    expect(selected, 'b');
    expect(taps, 2);
  });

  testWidgets('working entry shows the working dots', (
    WidgetTester tester,
  ) async {
    await tester.pumpWidget(
      _app(const ChatTitleStrip(entries: _entries, selectedId: 'c')),
    );
    expect(find.text('working'), findsOneWidget);
    expect(find.text('third'), findsNothing);
  });

  testWidgets('semantics carry the title and the hint', (
    WidgetTester tester,
  ) async {
    final SemanticsHandle handle = tester.ensureSemantics();
    await tester.pumpWidget(
      _app(ChatTitleStrip(entries: _entries, selectedId: 'b', onTap: () {})),
    );
    expect(
      tester.getSemantics(find.bySemanticsLabel('Beta')),
      isSemantics(
        label: 'Beta',
        hint: 'Swipe to switch chats',
        value: '2/3',
        hasTapAction: true,
      ),
    );
    handle.dispose();
  });

  testWidgets('fits at 360 px and 1.3 text scale', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(360, 640),
            textScaler: TextScaler.linear(1.3),
          ),
          child: Scaffold(
            body: Center(
              child: ChatTitleStrip(
                entries: <SwipeChatEntry>[
                  ..._entries,
                  const SwipeChatEntry(
                    id: 'long',
                    title:
                        'A very long chat title that will never fit on a phone',
                    subtitle:
                        'and a subtitle that is just as long as the title',
                  ),
                ],
                selectedId: 'long',
              ),
            ),
          ),
        ),
      ),
    );
    expect(tester.takeException(), isNull);
  });
}
