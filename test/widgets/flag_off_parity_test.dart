// The Agents build draws exactly what chuk_chat draws. There is no Agents look
// for the bubble, the markdown or the table: the flag, and the messenger
// thread's own mode, change behaviour only. These pins keep the cheap-to-check
// part of that parity: chuk_chat's bubble geometry and table, in every mode.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/widgets/chuk_table.dart';
import 'package:chuk_chat/widgets/chuk_table_classic.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';

Widget _wrap(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SingleChildScrollView(child: SizedBox(width: 400, child: child)),
  ),
);

final DateTime _sent = DateTime(2026, 9, 22, 14, 5);

Widget _turn({bool messengerMode = false}) => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: <Widget>[
    MessageBubble(
      message: 'Compare Rust and Go.',
      isUser: true,
      messengerMode: messengerMode,
      sentAt: _sent,
      turnStartedAt: _sent,
    ),
    MessageBubble(
      message: 'Pick Go.',
      isUser: false,
      messengerMode: messengerMode,
      sentAt: _sent,
      turnStartedAt: _sent,
      contentBlocks: const <ContentBlock>[
        ContentBlock.text(
          '| | Rust | Go |\n|---|---|---|\n| Build | 48 s | 6 s |',
        ),
        ContentBlock.text('Pick `Go`.'),
      ],
    ),
  ],
);

/// Every decorated box the bubbles draw, by fill colour.
Iterable<BoxDecoration> _decorations(WidgetTester tester) => tester
    .widgetList<Container>(
      find.descendant(
        of: find.byType(MessageBubble),
        matching: find.byType(Container),
      ),
    )
    .map((Container c) => c.decoration)
    .whereType<BoxDecoration>();

void main() {
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));
  tearDown(() => debugAgentsChatCoreOverride = null);

  for (final (bool flag, bool messenger) in <(bool, bool)>[
    (false, false),
    (true, false),
    (true, true),
  ]) {
    testWidgets(
      'agents $flag, messenger $messenger: chuk_chat bubble and table',
      (tester) async {
        debugAgentsChatCoreOverride = flag;
        await tester.pumpWidget(_wrap(_turn(messengerMode: messenger)));
        await tester.pump(const Duration(milliseconds: 500));

        // No clock stamp in any build.
        expect(find.text('14:05'), findsNothing);
        expect(find.byType(ChukTableClassic), findsOneWidget);
        expect(find.byType(ChukTable), findsNothing);

        final ColorScheme scheme = Theme.of(
          tester.element(find.byType(MessageBubble).first),
        ).colorScheme;
        // chuk_chat's user bubble: the accent at 80 % with a hairline border
        // and the tail corner on the run's last bubble.
        final BoxDecoration user = _decorations(tester).firstWhere(
          (BoxDecoration d) => d.color == scheme.primary.withValues(alpha: .8),
        );
        expect(user.border, isNotNull);
        final BorderRadius radius = user.borderRadius! as BorderRadius;
        expect(radius.topLeft, const Radius.circular(16));
        expect(radius.bottomRight, const Radius.circular(5));
        // chuk_chat draws the answer on the page: no filled bubble behind it.
        expect(
          _decorations(tester).where(
            (BoxDecoration d) =>
                d.color == scheme.surfaceContainerHigh ||
                d.color == scheme.secondaryContainer ||
                d.color == scheme.tertiaryContainer,
          ),
          isEmpty,
        );
        // The widgets above build no timers that outlive the tree.
        await tester.pumpWidget(const SizedBox());
      },
    );
  }
}
