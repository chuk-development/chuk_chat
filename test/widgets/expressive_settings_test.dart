import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

/// The scale [MorphTap] currently applies to the tile.
double _tileScale(WidgetTester tester) {
  final Transform transform = tester.widget<Transform>(
    find
        .descendant(of: find.byType(MorphTap), matching: find.byType(Transform))
        .first,
  );
  // The x scale of the press. `getMaxScaleOnAxis` would report the untouched
  // z axis (1) instead.
  return transform.transform.storage[0];
}

Widget _host({required Widget child, bool reducedMotion = false}) {
  return MaterialApp(
    home: MediaQuery(
      data: MediaQueryData(disableAnimations: reducedMotion),
      child: Scaffold(body: Center(child: child)),
    ),
  );
}

void main() {
  // The spring tile, the cascade and the scheme pairing are the Agents app's;
  // chuk_chat's widgets keep their own (see the flag-off test below).
  setUp(() => debugAgentsChatCoreOverride = true);
  tearDown(() => debugAgentsChatCoreOverride = null);

  group('ExpressiveTile', () {
    testWidgets('calls back on tap', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          child: ExpressiveTile(
            onTap: () => taps++,
            child: const Text('a row'),
          ),
        ),
      );

      await tester.tap(find.text('a row'));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });

    testWidgets('still calls back on tap with reduced motion', (
      WidgetTester tester,
    ) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          reducedMotion: true,
          child: ExpressiveTile(
            onTap: () => taps++,
            child: const Text('a row'),
          ),
        ),
      );

      await tester.tap(find.text('a row'));
      await tester.pumpAndSettle();

      expect(taps, 1);
    });

    testWidgets('presses on a spring, not a curve', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(child: ExpressiveTile(onTap: () {}, child: const Text('a row'))),
      );
      expect(_tileScale(tester), 1);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('a row')),
      );
      // The frame the press starts on: the tile has not moved yet, because
      // the press travels instead of jumping.
      await tester.pump();
      expect(_tileScale(tester), moreOrLessEquals(1, epsilon: 0.001));

      // Early in the press: on its way down, not there yet.
      await tester.pump(const Duration(milliseconds: 30));
      final double midPress = _tileScale(tester);
      expect(midPress, lessThan(1));
      expect(midPress, greaterThan(0.985));

      await tester.pump(const Duration(milliseconds: 200));
      expect(_tileScale(tester), moreOrLessEquals(0.985, epsilon: 0.001));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(_tileScale(tester), moreOrLessEquals(1, epsilon: 0.001));
    });

    testWidgets('reduced motion skips the press animation', (
      WidgetTester tester,
    ) async {
      await tester.pumpWidget(
        _host(
          reducedMotion: true,
          child: ExpressiveTile(onTap: () {}, child: const Text('a row')),
        ),
      );

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('a row')),
      );
      await tester.pump();
      // No travel: the pressed scale is reached in the very next frame, where
      // an animated press would still be near 1.
      expect(_tileScale(tester), moreOrLessEquals(0.985, epsilon: 0.001));

      await gesture.up();
      await tester.pump();
      expect(_tileScale(tester), moreOrLessEquals(1, epsilon: 0.001));
    });
  });

  group('onColorFor', () {
    testWidgets('takes the partner colour from the scheme', (
      WidgetTester tester,
    ) async {
      late ColorScheme scheme;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (BuildContext context) {
              scheme = Theme.of(context).colorScheme;
              return const SizedBox();
            },
          ),
        ),
      );

      expect(
        scheme.onColorFor(scheme.primaryContainer),
        scheme.onPrimaryContainer,
      );
      expect(scheme.onColorFor(scheme.error), scheme.onError);
      // An unknown tone still stays inside the scheme.
      const Color foreign = Color(0xFF102030);
      expect(
        <Color>[scheme.surface, scheme.onSurface],
        contains(scheme.onColorFor(foreign)),
      );
    });
  });

  group('ExpressiveTile with the Agents core off (upstream chuk_chat)', () {
    setUp(() => debugAgentsChatCoreOverride = false);

    testWidgets('is upstream\'s squeeze tile: it calls back and scales on '
        'press, with no MorphTap', (WidgetTester tester) async {
      var taps = 0;
      await tester.pumpWidget(
        _host(
          child: ExpressiveTile(
            onTap: () => taps++,
            child: const Text('a row'),
          ),
        ),
      );
      expect(find.byType(MorphTap), findsNothing);
      double scale() =>
          tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;
      expect(scale(), 1);

      final TestGesture gesture = await tester.startGesture(
        tester.getCenter(find.text('a row')),
      );
      await tester.pump();
      expect(scale(), lessThan(1));

      await gesture.up();
      await tester.pumpAndSettle();
      expect(scale(), 1);
      expect(taps, 1);
    });
  });
}
