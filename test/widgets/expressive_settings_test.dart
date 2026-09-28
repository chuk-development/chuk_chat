import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/ui/expressive/motion.dart';
import 'package:chuk_chat/widgets/expressive_settings.dart';

Widget _host({required Widget child}) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

void main() {
  // One settings kit for both builds: upstream chuk_chat's tile, icon and
  // spacing, whatever the Agents flag says.
  for (final bool agents in <bool>[false, true]) {
    final String build = agents ? ' (Agents)' : '';

    group('ExpressiveTile$build', () {
      setUp(() => debugAgentsChatCoreOverride = agents);
      tearDown(() => debugAgentsChatCoreOverride = null);

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

      testWidgets('a section header keeps upstream\'s spacing', (
        WidgetTester tester,
      ) async {
        await tester.pumpWidget(
          _host(child: const ExpressiveSectionHeader('Account')),
        );
        final Padding padding = tester.widget<Padding>(
          find
              .ancestor(of: find.text('Account'), matching: find.byType(Padding))
              .first,
        );
        expect(padding.padding, const EdgeInsets.fromLTRB(6, 16, 6, 8));
      });
    });
  }

  group('onColorFor', () {
    testWidgets('picks plain white on a dark tone and black on a light one', (
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

      expect(scheme.onColorFor(const Color(0xFF102030)), Colors.white);
      expect(scheme.onColorFor(const Color(0xFFF0F0F0)), Colors.black);
    });
  });
}
