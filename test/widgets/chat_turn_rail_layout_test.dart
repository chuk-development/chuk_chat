// The message minimap on the real desktop screen (an Agents thread in
// `MessengerShell`, at desktop sizes): its strips sit centred between the
// header line and the composer, every strip centred on its own line, and
// the hover card's first text line centred on the hovered strip.
//
// Set CHUK_RAIL_SHOT=<dir> to also write a PNG of each size there.

import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/services/multiplex_session.dart';
import 'package:chuk_chat/services/storage/chat_origin.dart';
import 'package:chuk_chat/widgets/chat_turn_rail.dart';

import '../perf/chat_scroll_screen_fixture.dart';
import '../perf/perf_support.dart';

const Timeout _guard = Timeout(Duration(minutes: 3));

Rect _rect(WidgetTester tester, Finder f) => tester.getRect(f);

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

  for (final Size size in const <Size>[Size(1440, 900), Size(1920, 1080)]) {
    testWidgets(
      'minimap strips are centred at ${size.width.toInt()}x'
      '${size.height.toInt()}',
      timeout: _guard,
      (tester) async {
        silenceUnrelatedPlugins(tester);
        tester.view.physicalSize = size;
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        await mountRealScreenThread(tester, disk);
        await tester.pump(const Duration(milliseconds: 300));

        final Finder rail = find.byType(ChatTurnRail);
        expect(rail, findsOneWidget, reason: 'no minimap on the screen');
        final ChatTurnRail widget = tester.widget(rail);
        final Rect pane = _rect(tester, rail);
        final Finder ticks = find.byWidgetPredicate(
          (w) =>
              w is Positioned &&
              w.key is ValueKey<String> &&
              (w.key! as ValueKey<String>).value.startsWith('turn-rail-tick-'),
        );
        final List<Rect> strips =
            ticks
                .evaluate()
                .map((e) => tester.getRect(find.byWidget(e.widget)))
                .toList()
              ..sort((a, b) => a.top.compareTo(b.top));
        expect(strips.length, greaterThanOrEqualTo(2));

        // The free band: below the header line, above the composer.
        final double bandTop = pane.top + widget.topPadding;
        final double bandBottom = pane.bottom - widget.bottomPadding;
        final double bandCentre = (bandTop + bandBottom) / 2;
        final double railCentre =
            (strips.first.center.dy + strips.last.center.dy) / 2;
        final Rect line = _rect(
          tester,
          find.byKey(const ValueKey<String>('turn-rail-guide')),
        );
        // ignore: avoid_print
        print(
          'size=$size pane=$pane band=$bandTop..$bandBottom '
          'railCentre=$railCentre bandCentre=$bandCentre '
          'line=$line first=${strips.first} last=${strips.last}',
        );
        expect((railCentre - bandCentre).abs(), lessThan(1.0));
        // The guide line runs exactly from the first strip's centre to the
        // last one's.
        expect((line.top - strips.first.center.dy).abs(), lessThan(0.6));
        expect((line.bottom - strips.last.center.dy).abs(), lessThan(0.6));
        // Every strip is centred on its own line, and they are evenly
        // spaced.
        for (final Rect s in strips) {
          expect(s.height, 2);
        }
        final double step = strips[1].center.dy - strips[0].center.dy;
        for (int i = 1; i < strips.length; i++) {
          expect(
            (strips[i].center.dy - strips[i - 1].center.dy - step).abs(),
            lessThan(0.01),
          );
        }
        // Inside the band, with its margin.
        expect(strips.first.top, greaterThanOrEqualTo(bandTop));
        expect(strips.last.bottom, lessThanOrEqualTo(bandBottom));
        await _shot(tester, 'rail_${size.width.toInt()}');

        // Hover the middle strip: the card's first line sits on it.
        final int middle = strips.length ~/ 2;
        final TestGesture mouse = await tester.createGesture(
          kind: PointerDeviceKind.mouse,
        );
        await mouse.addPointer(location: strips[middle].center);
        await mouse.moveTo(strips[middle].center);
        await tester.pump(const Duration(milliseconds: 200));
        final Finder firstLine = find.byKey(
          const ValueKey<String>('turn-rail-preview-first-line'),
        );
        expect(firstLine, findsOneWidget);
        final double lineCentre = _rect(tester, firstLine).center.dy;
        final Rect hovered = strips[middle];
        // ignore: avoid_print
        print('hover strip=${hovered.center.dy} cardLine=$lineCentre');
        expect((lineCentre - hovered.center.dy).abs(), lessThan(1.0));
        await _shot(tester, 'rail_${size.width.toInt()}_hover');
        await mouse.removePointer();
        await releaseIdleTimers(tester);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(seconds: 3));
      },
    );
  }
}
