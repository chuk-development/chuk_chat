// With FEATURE_AGENTS off the app must draw exactly what upstream chuk_chat
// draws. A pixel sweep of both trees (desktop and phone chat, sidebar,
// settings, theme, customization, account, the mode picker) found the merged
// bubble, markdown, table and settings rework leaking into the flag-off build.
// These pins keep the cheap-to-check part of that parity: the widgets that
// only the Agents build may show, and upstream's bubble geometry.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/services/agents/agents_chat_core.dart';
import 'package:chuk_chat/ui/expressive/message_stamp.dart';
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

Widget _turn() => Column(
  crossAxisAlignment: CrossAxisAlignment.stretch,
  children: <Widget>[
    MessageBubble(
      message: 'Compare Rust and Go.',
      isUser: true,
      sentAt: _sent,
      turnStartedAt: _sent,
    ),
    MessageBubble(
      message: 'Pick Go.',
      isUser: false,
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

  testWidgets('flag off: no clock stamp, no answer bubble, upstream table', (
    tester,
  ) async {
    debugAgentsChatCoreOverride = false;
    await tester.pumpWidget(_wrap(_turn()));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MessageStamp), findsNothing);
    expect(find.text('14:05'), findsNothing);
    expect(find.byType(ChukTableClassic), findsOneWidget);
    expect(find.byType(ChukTable), findsNothing);

    final ColorScheme scheme = Theme.of(
      tester.element(find.byType(MessageBubble).first),
    ).colorScheme;
    // Upstream's user bubble: the accent at 80 % with a hairline border and
    // the tail corner on the run's last bubble.
    final BoxDecoration user = _decorations(tester).firstWhere(
      (BoxDecoration d) => d.color == scheme.primary.withValues(alpha: .8),
    );
    expect(user.border, isNotNull);
    expect(
      (user.borderRadius! as BorderRadius).bottomRight,
      const Radius.circular(5),
    );
    // Upstream draws the answer on the page: no filled bubble behind it.
    expect(
      _decorations(tester)
          .where((BoxDecoration d) => d.color == scheme.surfaceContainerHigh),
      isEmpty,
    );
  });

  testWidgets('flag on: the Agents bubble keeps its stamp and new table', (
    tester,
  ) async {
    debugAgentsChatCoreOverride = true;
    await tester.pumpWidget(_wrap(_turn()));
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.byType(MessageStamp), findsWidgets);
    expect(find.byType(ChukTable), findsOneWidget);
    expect(find.byType(ChukTableClassic), findsNothing);
    // The widgets above build no timers that outlive the tree.
    await tester.pumpWidget(const SizedBox());
  });
}
