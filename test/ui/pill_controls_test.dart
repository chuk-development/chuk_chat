/// The two pill controls: the filter switch above a list and the floating
/// navigation bar.
///
/// Three things were wrong and all three are checked here. The switch lost its
/// tap to the list it sits above, so it selects on pointer down now — and a
/// press that turns into a drag still counts, exactly once. An unselected
/// segment drew an outline before the selection landed, so it draws none. And
/// the capsule sat too tight in the shell, so the ring around it is wider
/// while the target a finger hits stays at least 48.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/mobile/mobile_layout.dart';
import 'package:chuk_chat/platform_specific/mobile/mobile_nav_bar.dart';
import 'package:chuk_chat/ui/expressive/connected_group.dart';
import 'package:chuk_chat/ui/expressive/huge_icon.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/ui/expressive/pill_geometry.dart';

const List<MobileNavDestination> _destinations = <MobileNavDestination>[
  MobileNavDestination(icon: HugeIcons.message01, label: 'Chats', badge: 7),
  MobileNavDestination(icon: HugeIcons.album02, label: 'Media'),
  MobileNavDestination(icon: HugeIcons.folder03, label: 'Files'),
  MobileNavDestination(icon: HugeIcons.settings01, label: 'Settings'),
];

Future<void> _pumpPhone(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: child)),
    ),
  );
}

/// The pill and the list under it, the arrangement the tap used to be lost in.
Future<void> _pumpInsideAScrollView(
  WidgetTester tester,
  Widget pill,
) async {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: ListView(
          children: <Widget>[
            pill,
            for (int i = 0; i < 40; i++) SizedBox(height: 64, child: Text('$i')),
          ],
        ),
      ),
    ),
  );
}

void main() {
  group('the numbers', () {
    test('the capsule, the ring and the target agree', () {
      expect(PillGeometry.inset, 8);
      expect(PillGeometry.segmentHeight, 44);
      expect(PillGeometry.segmentRadius, 22);
      expect(PillGeometry.radius, 30);
      expect(PillGeometry.height, 60);
      // The switch above a list is its own control: flatter, and its capsule
      // all but fills it.
      expect(PillGeometry.filterInset, 3);
      expect(PillGeometry.filterSegmentHeight, 32);
      expect(PillGeometry.filterSegmentRadius, 16);
      expect(PillGeometry.filterRadius, 19);
      expect(PillGeometry.filterHeight, 38);
      // Two thirds of the navigation's height, and still a 48 target.
      expect(
        PillGeometry.filterTapHeight,
        greaterThanOrEqualTo(MobileLayout.minTouchTarget),
      );
      // The ring is the same thickness everywhere: what the shell does not pad
      // at the top and the bottom, the segment carries as tap slop.
      expect(
        PillGeometry.shellPadding.top + PillGeometry.tapSlop,
        PillGeometry.inset,
      );
      expect(PillGeometry.shellPadding.left, PillGeometry.inset);
      // A capsule shorter than the minimum target still hands a finger one.
      expect(
        PillGeometry.tapHeight,
        greaterThanOrEqualTo(MobileLayout.minTouchTarget),
      );
    });
  });

  group('the filter switch', () {
    testWidgets('the whole switch is 38 tall and each target is 48', (
      tester,
    ) async {
      await _pumpPhone(
        tester,
        ConnectedGroup(
          labels: const <String>['All', 'Unread'],
          selected: 0,
          badges: const <int, int>{0: 128, 1: 12},
          onSelected: (_) {},
        ),
      );

      // The strip paints 38; the control reserves the 48 its targets need.
      expect(
        tester.getSize(find.byType(ConnectedGroup)).height,
        PillGeometry.filterTapHeight,
      );
      for (final Element element
          in find.byType(MorphTap).evaluate().toList()) {
        final Size size = tester.getSize(find.byWidget(element.widget));
        expect(size.height, PillGeometry.filterTapHeight);
        expect(
          size.height,
          greaterThanOrEqualTo(MobileLayout.minTouchTarget),
        );
      }
      // Two labels with counts on a 360 phone: no overflow.
      expect(tester.takeException(), isNull);
    });

    testWidgets('no segment hints at a selection with an outline', (
      tester,
    ) async {
      await _pumpPhone(
        tester,
        ConnectedGroup(
          labels: const <String>['All', 'Unread'],
          selected: 0,
          onSelected: (_) {},
        ),
      );

      for (final MorphTap tap
          in tester.widgetList<MorphTap>(find.byType(MorphTap))) {
        expect(tap.pressedOutline, isNull);
        expect(tap.instant, isTrue);
      }
    });

    testWidgets('a tap selects once', (tester) async {
      final List<int> picked = <int>[];
      await _pumpPhone(
        tester,
        ConnectedGroup(
          labels: const <String>['All', 'Unread'],
          selected: 0,
          onSelected: picked.add,
        ),
      );

      await tester.tap(find.text('Unread'));
      await tester.pumpAndSettle();

      expect(picked, <int>[1]);
    });

    testWidgets('a press that turns into a scroll still selects, once', (
      tester,
    ) async {
      final List<int> picked = <int>[];
      await _pumpInsideAScrollView(
        tester,
        ConnectedGroup(
          labels: const <String>['All', 'Unread'],
          selected: 0,
          onSelected: picked.add,
        ),
      );

      // The finger lands on "Unread" and travels: the list wins the arena, so
      // the old ink well was cancelled and nothing happened.
      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('Unread')),
      );
      await tester.pump(const Duration(milliseconds: 20));
      await gesture.moveBy(const Offset(0, -120));
      await tester.pump();
      await gesture.up();
      await tester.pumpAndSettle();

      expect(picked, <int>[1]);
    });

    testWidgets('a second finger on the same segment is not a second pick', (
      tester,
    ) async {
      final List<int> picked = <int>[];
      await _pumpPhone(
        tester,
        ConnectedGroup(
          labels: const <String>['All', 'Unread'],
          selected: 0,
          onSelected: picked.add,
        ),
      );

      final Offset target = tester.getCenter(find.text('Unread'));
      final TestGesture first = await tester.startGesture(target, pointer: 1);
      final TestGesture second = await tester.startGesture(target, pointer: 2);
      await tester.pump();
      await first.up();
      await second.up();
      await tester.pumpAndSettle();

      expect(picked, <int>[1]);
    });
  });

  group('the navigation pill', () {
    testWidgets('four targets fit a 360 phone and each one is 52 tall', (
      tester,
    ) async {
      await _pumpPhone(
        tester,
        MobileNavBar(
          destinations: _destinations,
          index: 0,
          onSelected: (_) {},
        ),
      );

      final List<Element> targets = find.byType(MorphTap).evaluate().toList();
      expect(targets, hasLength(_destinations.length));
      for (final Element element in targets) {
        final Size size = tester.getSize(find.byWidget(element.widget));
        expect(size.height, PillGeometry.tapHeight);
        expect(
          size.width,
          greaterThanOrEqualTo(MobileLayout.minTouchTarget),
        );
      }
      // The shell itself: 60 tall, and four targets still inside a 360 phone.
      final Size pill = tester.getSize(
        find
            .descendant(
              of: find.byType(MobileNavBar),
              matching: find.byType(Container),
            )
            .first,
      );
      expect(pill.height, PillGeometry.height);
      expect(pill.width, lessThanOrEqualTo(360));
      expect(tester.takeException(), isNull);
    });

    testWidgets('a destination that is not current draws no outline', (
      tester,
    ) async {
      await _pumpPhone(
        tester,
        MobileNavBar(
          destinations: _destinations,
          index: 0,
          onSelected: (_) {},
        ),
      );

      for (final MorphTap tap
          in tester.widgetList<MorphTap>(find.byType(MorphTap))) {
        expect(tap.pressedOutline, isNull);
        expect(tap.instant, isTrue);
      }
    });

    testWidgets('the destination changes on pointer down, once', (
      tester,
    ) async {
      final List<int> picked = <int>[];
      await _pumpPhone(
        tester,
        MobileNavBar(
          destinations: _destinations,
          index: 0,
          onSelected: picked.add,
        ),
      );

      final Offset target = tester.getCenter(
        find.byType(MorphTap).at(2),
      );
      final TestGesture gesture = await tester.startGesture(target);
      await tester.pump();
      // Down alone is the whole selection.
      expect(picked, <int>[2]);
      await gesture.up();
      await tester.pumpAndSettle();
      expect(picked, <int>[2]);
    });
  });

  group('an ordinary MorphTap', () {
    testWidgets('still waits for a recognised tap', (tester) async {
      int taps = 0;
      await _pumpPhone(
        tester,
        MorphTap(
          onTap: () => taps++,
          color: const Color(0xFF445566),
          child: const SizedBox(width: 120, height: 48),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.byType(MorphTap)),
      );
      await tester.pump();
      expect(taps, 0, reason: 'the default is not an instant tap');
      await gesture.up();
      await tester.pumpAndSettle();
      expect(taps, 1);
      expect(find.byType(InkWell), findsOneWidget);
    });
  });
}
