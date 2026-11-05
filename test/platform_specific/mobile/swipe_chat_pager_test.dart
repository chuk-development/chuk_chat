import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';

const List<SwipeChatEntry> _entries = <SwipeChatEntry>[
  SwipeChatEntry(id: 'a', title: 'Alpha'),
  SwipeChatEntry(id: 'b', title: 'Beta'),
  SwipeChatEntry(id: 'c', title: 'Gamma'),
];

/// A stand-in for the live chat view: it counts how often its State is born.
class _Chat extends StatefulWidget {
  const _Chat({required this.chatId});
  final String chatId;

  @override
  State<_Chat> createState() => _ChatState();
}

int _chatStates = 0;

class _ChatState extends State<_Chat> {
  @override
  void initState() {
    super.initState();
    _chatStates++;
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: Colors.white,
      child: Column(
        children: <Widget>[
          Text('chat ${widget.chatId}'),
          const SizedBox(
            width: 300,
            child: TextField(key: ValueKey<String>('field'), maxLines: 3),
          ),
          SizedBox(
            height: 60,
            child: ListView(
              key: const ValueKey<String>('hscroll'),
              scrollDirection: Axis.horizontal,
              children: <Widget>[
                for (int i = 0; i < 20; i++)
                  SizedBox(width: 100, child: Text('cell $i')),
              ],
            ),
          ),
          const Expanded(child: SizedBox.expand()),
        ],
      ),
    );
  }
}

class _Host extends StatefulWidget {
  const _Host({required this.initial, this.controller});
  final String initial;
  final SwipeChatPagerController? controller;

  @override
  State<_Host> createState() => _HostState();
}

class _HostState extends State<_Host> {
  late String selected = widget.initial;
  final List<String> calls = <String>[];

  /// A jump from outside the pager (the switcher sheet, say).
  void select(String id) => setState(() => selected = id);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Scaffold(
        body: SwipeChatPager(
          entries: _entries,
          selectedId: selected,
          controller: widget.controller,
          onSelected: (String id) => setState(() {
            calls.add(id);
            selected = id;
          }),
          child: _Chat(chatId: selected),
        ),
      ),
    );
  }
}

Future<_HostState> _pump(
  WidgetTester tester, {
  String initial = 'b',
  SwipeChatPagerController? controller,
}) async {
  tester.view.physicalSize = const Size(400, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  _chatStates = 0;
  await tester.pumpWidget(_Host(initial: initial, controller: controller));
  return tester.state<_HostState>(find.byType(_Host));
}

void main() {
  testWidgets(
    'a swipe over a SelectionArea transcript switches with the Android slop',
    (WidgetTester tester) async {
      await tester.pumpWidget(const _SelectableHost());
      final _SelectableHostState host = tester.state(
        find.byType(_SelectableHost),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('message line 3')),
      );
      for (int i = 0; i < 20; i++) {
        await gesture.moveBy(const Offset(-15, 0));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(host.selected, 'b');
    },
  );

  testWidgets(
    'a vertical scroll with a little sideways jitter does not switch',
    (WidgetTester tester) async {
      await tester.pumpWidget(const _SelectableHost());
      final _SelectableHostState host = tester.state(
        find.byType(_SelectableHost),
      );
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('message line 3')),
      );
      for (int i = 0; i < 10; i++) {
        await gesture.moveBy(const Offset(-3, -12));
        await tester.pump(const Duration(milliseconds: 16));
      }
      await gesture.up();
      await tester.pumpAndSettle();
      expect(host.selected, 'a');
    },
  );

  testWidgets('a drag to the left past the threshold selects the next chat', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester);
    await tester.timedDrag(
      find.text('chat b'),
      const Offset(-160, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(host.calls, <String>['c']);
    expect(find.text('chat c'), findsOneWidget);
  });

  testWidgets('a drag to the right selects the previous chat', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester);
    await tester.timedDrag(
      find.text('chat b'),
      const Offset(160, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(host.calls, <String>['a']);
  });

  testWidgets('a short drag springs back', (WidgetTester tester) async {
    final _HostState host = await _pump(tester);
    await tester.timedDrag(
      find.text('chat b'),
      const Offset(-50, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(host.calls, isEmpty);
    expect(tester.getTopLeft(find.byType(_Chat)).dx, 0);
  });

  testWidgets('the rubber band at either end does not select', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester, initial: 'c');
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('chat c')),
    );
    for (int i = 0; i < 20; i++) {
      await gesture.moveBy(const Offset(-15, 0));
      await tester.pump(const Duration(milliseconds: 40));
    }
    // 300 px of finger travel; the band holds the chat to a small offset.
    final double dx = tester.getTopLeft(find.byType(_Chat)).dx;
    expect(dx, lessThan(0));
    expect(dx, greaterThan(-0.12 * 400));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(host.calls, isEmpty);
    expect(tester.getTopLeft(find.byType(_Chat)).dx, 0);

    host.select('a');
    await tester.pumpAndSettle();
    await tester.timedDrag(
      find.text('chat a'),
      const Offset(300, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(host.calls, isEmpty);
  });

  testWidgets('a fast fling selects even when short', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester);
    await tester.fling(find.text('chat b'), const Offset(-60, 0), 1500);
    await tester.pumpAndSettle();
    expect(host.calls, <String>['c']);
  });

  testWidgets('the chat keeps its State across a switch', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester);
    final State<_Chat> before = tester.state(find.byType(_Chat));
    await tester.timedDrag(
      find.text('chat b'),
      const Offset(-160, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(host.calls, <String>['c']);
    expect(identical(tester.state(find.byType(_Chat)), before), isTrue);
    expect(_chatStates, 1);
  });

  testWidgets('a drag that starts on a text field does not switch', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester);
    await tester.timedDrag(
      find.byKey(const ValueKey<String>('field')),
      const Offset(-200, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(host.calls, isEmpty);
    expect(find.text('chat b'), findsOneWidget);
  });

  testWidgets('an inner horizontal scrollable wins the drag', (
    WidgetTester tester,
  ) async {
    final _HostState host = await _pump(tester);
    await tester.timedDrag(
      find.text('cell 1'),
      const Offset(-200, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(host.calls, isEmpty);
    expect(find.text('cell 0'), findsNothing);
  });

  testWidgets('the controller publishes progress in pages', (
    WidgetTester tester,
  ) async {
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    await _pump(tester, controller: controller);
    final TestGesture gesture = await tester.startGesture(
      tester.getCenter(find.text('chat b')),
    );
    await gesture.moveBy(const Offset(-30, 0)); // past the slop
    await tester.pump();
    final double start = controller.progress.value;
    await gesture.moveBy(const Offset(-80, 0));
    await tester.pump();
    expect(controller.progress.value, closeTo(start - 80 / 400, 0.001));
    expect(controller.progress.value, lessThan(0));
    await gesture.up();
    await tester.pumpAndSettle();
    expect(controller.progress.value, 0);
  });

  testWidgets('controller.next animates to the next chat', (
    WidgetTester tester,
  ) async {
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    final _HostState host = await _pump(tester, controller: controller);
    controller.next();
    await tester.pumpAndSettle();
    expect(host.calls, <String>['c']);
  });

  testWidgets('disabled pager ignores drags', (WidgetTester tester) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final List<String> calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SwipeChatPager(
            entries: _entries,
            selectedId: 'b',
            enabled: false,
            onSelected: calls.add,
            child: const _Chat(chatId: 'b'),
          ),
        ),
      ),
    );
    await tester.timedDrag(
      find.text('chat b'),
      const Offset(-200, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });

  testWidgets('reduced motion switches without sliding', (
    WidgetTester tester,
  ) async {
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String selected = 'b';
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => MaterialApp(
          home: Builder(
            builder: (BuildContext context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(disableAnimations: true),
              child: Scaffold(
                body: SwipeChatPager(
                  entries: _entries,
                  selectedId: selected,
                  onSelected: (String id) => setState(() => selected = id),
                  child: _Chat(chatId: selected),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.timedDrag(
      find.text('chat b'),
      const Offset(-160, 0),
      const Duration(milliseconds: 800),
    );
    await tester.pump();
    expect(selected, 'c');
    expect(tester.getTopLeft(find.byType(_Chat)).dx, 0);
  });

  /// Steps a committed switch frame by frame and records, per frame, the
  /// carousel, the progress and whether the selection has changed yet.
  Future<List<(double, double, bool)>> sampleSwitch(
    WidgetTester tester,
    SwipeChatPagerController controller,
    _HostState host,
    String from,
  ) async {
    final List<(double, double, bool)> frames = <(double, double, bool)>[];
    for (int i = 0; i < 60; i++) {
      await tester.pump(const Duration(milliseconds: 8));
      frames.add((
        controller.carousel.value,
        controller.progress.value,
        host.selected != from,
      ));
    }
    await tester.pumpAndSettle();
    return frames;
  }

  testWidgets('carousel runs to -1 on the way out and reads 0 on the way in', (
    WidgetTester tester,
  ) async {
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    final _HostState host = await _pump(tester, controller: controller);
    controller.next();
    final List<(double, double, bool)> frames = await sampleSwitch(
      tester,
      controller,
      host,
      'b',
    );
    expect(host.calls, <String>['c']);

    final List<(double, double, bool)> out = <(double, double, bool)>[
      for (final (double, double, bool) f in frames)
        if (!f.$3) f,
    ];
    final List<(double, double, bool)> arriving = <(double, double, bool)>[
      for (final (double, double, bool) f in frames)
        if (f.$3) f,
    ];
    expect(out, isNotEmpty);
    expect(arriving, isNotEmpty);
    // The "out" half: the carousel follows the progress towards -1.
    for (final (double c, double p, bool _) in out) {
      expect(c, p);
      expect(c, inInclusiveRange(-1.0, 0.0));
    }
    expect(
      out.map(((double, double, bool) f) => f.$1).reduce(math.min),
      lessThan(-0.5),
    );
    // The "in" half: the chat comes back from +1, the carousel stays at 0.
    expect(arriving.any(((double, double, bool) f) => f.$2 > 0.3), isTrue);
    for (final (double c, double _, bool _) in arriving) {
      expect(c, 0);
    }
    expect(controller.carousel.value, 0);
    expect(controller.progress.value, 0);
  });

  testWidgets('carousel runs to +1 on the way out to the previous chat', (
    WidgetTester tester,
  ) async {
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    final _HostState host = await _pump(tester, controller: controller);
    controller.previous();
    final List<(double, double, bool)> frames = await sampleSwitch(
      tester,
      controller,
      host,
      'b',
    );
    expect(host.calls, <String>['a']);
    final Iterable<(double, double, bool)> out = frames.where(
      ((double, double, bool) f) => !f.$3,
    );
    expect(
      out.map(((double, double, bool) f) => f.$1).reduce(math.max),
      greaterThan(0.5),
    );
    for (final (double c, double _, bool _) in out) {
      expect(c, inInclusiveRange(0.0, 1.0));
    }
    for (final (double c, double p, bool _) in frames.where(
      ((double, double, bool) f) => f.$3,
    )) {
      expect(c, 0);
      expect(p, lessThanOrEqualTo(0));
    }
  });

  testWidgets('drag methods on the controller drive the pager', (
    WidgetTester tester,
  ) async {
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    final _HostState host = await _pump(tester, controller: controller);

    controller.dragStart();
    controller.dragUpdate(-80);
    await tester.pump();
    expect(controller.progress.value, closeTo(-80 / 400, 0.001));
    expect(controller.carousel.value, closeTo(-80 / 400, 0.001));
    expect(tester.getTopLeft(find.byType(_Chat)).dx, closeTo(-80, 0.5));
    controller.dragUpdate(-40); // 120 px = 0.3 pages, past the threshold
    controller.dragEnd(0);
    await tester.pumpAndSettle();
    expect(host.calls, <String>['c']);
    expect(controller.progress.value, 0);

    // A short drag that ends springs back.
    controller.dragStart();
    controller.dragUpdate(30);
    controller.dragEnd(0);
    await tester.pumpAndSettle();
    expect(host.calls, <String>['c']);
    expect(controller.progress.value, 0);

    // A fast fling commits even when short.
    controller.dragStart();
    controller.dragUpdate(20);
    controller.dragEnd(1500);
    await tester.pumpAndSettle();
    expect(host.calls, <String>['c', 'b']);
  });

  testWidgets('dragCancel springs back without a switch', (
    WidgetTester tester,
  ) async {
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    final _HostState host = await _pump(tester, controller: controller);
    controller.dragStart();
    controller.dragUpdate(-200);
    await tester.pump();
    expect(controller.progress.value, lessThan(-0.4));
    controller.dragCancel();
    await tester.pumpAndSettle();
    expect(host.calls, isEmpty);
    expect(controller.progress.value, 0);
    expect(controller.carousel.value, 0);
    expect(tester.getTopLeft(find.byType(_Chat)).dx, 0);
  });

  testWidgets('a drag on a ChatTitleStrip wired to the pager switches chats', (
    WidgetTester tester,
  ) async {
    final SwipeChatPagerController controller = SwipeChatPagerController();
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(400, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    String selected = 'b';
    await tester.pumpWidget(
      StatefulBuilder(
        builder: (BuildContext context, StateSetter setState) => MaterialApp(
          home: Scaffold(
            body: Column(
              children: <Widget>[
                ChatTitleStrip(
                  entries: _entries,
                  selectedId: selected,
                  controller: controller,
                ),
                Expanded(
                  child: SwipeChatPager(
                    entries: _entries,
                    selectedId: selected,
                    controller: controller,
                    onSelected: (String id) => setState(() => selected = id),
                    child: _Chat(chatId: selected),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final Finder strip = find.byType(ChatTitleStrip);
    await tester.timedDrag(
      strip,
      const Offset(-160, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(selected, 'c');
    expect(find.text('chat c'), findsOneWidget);

    await tester.timedDrag(
      strip,
      const Offset(160, 0),
      const Duration(milliseconds: 600),
    );
    await tester.pumpAndSettle();
    expect(selected, 'b');
  });
}

/// The phone case that slipped past the other tests: the transcript sits in
/// a [SelectionArea], and Android's touch slop (8, from the device) is lower
/// than the default 18. The selection's drag recognizer is deeper in the
/// tree and used to take every sideways swipe.
class _SelectableHost extends StatefulWidget {
  const _SelectableHost();

  @override
  State<_SelectableHost> createState() => _SelectableHostState();
}

class _SelectableHostState extends State<_SelectableHost> {
  String selected = 'a';

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      home: Builder(
        builder: (BuildContext context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            gestureSettings: const DeviceGestureSettings(touchSlop: 8),
          ),
          child: Scaffold(
            body: SwipeChatPager(
              entries: _entries,
              selectedId: selected,
              onSelected: (String id) => setState(() => selected = id),
              child: SelectionArea(
                child: ListView(
                  children: <Widget>[
                    for (int i = 0; i < 30; i++) Text('message line $i'),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
