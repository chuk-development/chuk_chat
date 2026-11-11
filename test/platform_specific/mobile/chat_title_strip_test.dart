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
    expect(find.text('Beta'), findsOneWidget);
    expect(find.text('second line'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('face_b')), findsOneWidget);
    // The position is a dot row, not "2/3" text.
    expect(find.text('2/3'), findsNothing);
    final Finder dots = find.byKey(
      const ValueKey<String>('chat_title_strip_position'),
    );
    expect(dots, findsOneWidget);
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

  testWidgets('content sits at the left; the neighbours are not drawn', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      _app(const ChatTitleStrip(entries: _entries, selectedId: 'b')),
    );
    final Rect bar = tester.getRect(find.byType(Container).first);
    final Rect face = tester.getRect(
      find.byKey(const ValueKey<String>('face_b')),
    );
    final Rect title = tester.getRect(find.text('Beta'));
    // The face starts right at the pill's inner edge, the title next to it:
    // no empty band on the left.
    expect(face.left - bar.left, lessThan(24));
    expect(title.left - face.right, lessThan(24));
    // The dots sit on the right end.
    final Rect dots = tester.getRect(
      find.byKey(const ValueKey<String>('chat_title_strip_position')),
    );
    expect(bar.right - dots.right, lessThan(24));
    expect(find.text('Alpha'), findsNothing);
    expect(find.text('Gamma'), findsNothing);
  });

  testWidgets('unread shows as a dot next to the title', (
    WidgetTester tester,
  ) async {
    final Finder dot = find.byWidgetPredicate(
      (Widget w) =>
          w is Container &&
          w.decoration is BoxDecoration &&
          (w.decoration! as BoxDecoration).shape == BoxShape.circle,
    );
    await tester.pumpWidget(
      _app(const ChatTitleStrip(entries: _entries, selectedId: 'a')),
    );
    expect(dot, findsOneWidget);
    final Rect title = tester.getRect(find.text('Alpha'));
    final Rect d = tester.getRect(dot);
    expect(d.left, greaterThanOrEqualTo(title.right));
    expect(d.center.dy, closeTo(title.center.dy, 2));

    await tester.pumpWidget(
      _app(const ChatTitleStrip(entries: _entries, selectedId: 'b')),
    );
    expect(dot, findsNothing);
  });

  testWidgets('a swipe slides the title a little and fades it', (
    WidgetTester tester,
  ) async {
    final ValueNotifier<double> progress = ValueNotifier<double>(0);
    addTearDown(progress.dispose);
    await tester.pumpWidget(
      _app(
        ChatTitleStrip(entries: _entries, selectedId: 'b', progress: progress),
      ),
    );
    final double rest = tester.getCenter(find.text('Beta')).dx;
    Opacity fadeOf() => tester.widget<Opacity>(
      find
          .ancestor(of: find.text('Beta'), matching: find.byType(Opacity))
          .first,
    );
    expect(fadeOf().opacity, 1);

    progress.value = -0.2; // 20 % towards the next entry
    await tester.pump();
    final double moved = tester.getCenter(find.text('Beta')).dx;
    expect(moved, lessThan(rest));
    // A short travel, not a page.
    expect(rest - moved, lessThan(20));
    expect(fadeOf().opacity, lessThan(1));

    progress.value = -0.5;
    await tester.pump();
    expect(fadeOf().opacity, 0);
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

  testWidgets('with a pager, a tap anywhere calls onTap; a drag steps', (
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
    for (final double x in <double>[0.1, 0.5, 0.9]) {
      await tester.tapAt(Offset(bar.left + bar.width * x, bar.center.dy));
      await tester.pumpAndSettle();
    }
    expect(taps, 3);
    expect(selected, 'b');

    await tester.timedDrag(
      find.byType(ChatTitleStrip),
      const Offset(-200, 0),
      const Duration(milliseconds: 300),
    );
    await tester.pumpAndSettle();
    expect(selected, 'c');
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
