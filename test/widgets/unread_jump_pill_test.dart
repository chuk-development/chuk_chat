import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agent_read_marks.dart';
import 'package:chuk_chat/utils/unread_rows.dart';
import 'package:chuk_chat/widgets/unread_jump_pill.dart';

Map<String, String> _row(String sender, DateTime at) => <String, String>{
  'sender': sender,
  'text': 'x',
  'sentAt': at.toUtc().toIso8601String(),
};

class _Harness extends StatefulWidget {
  const _Harness({required this.target, required this.onSeen});

  final int target;
  final VoidCallback onSeen;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  final ScrollController controller = ScrollController();
  final GlobalKey targetKey = GlobalKey();

  @override
  void initState() {
    super.initState();
    // A thread opens at its bottom.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => controller.jumpTo(controller.position.maxScrollExtent),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        ListView.builder(
          controller: controller,
          itemCount: 60,
          itemBuilder: (BuildContext context, int i) {
            final Widget row = SizedBox(height: 80, child: Text('row $i'));
            return i == widget.target
                ? KeyedSubtree(key: targetKey, child: row)
                : row;
          },
        ),
        Positioned(
          top: 8,
          left: 0,
          right: 0,
          child: Center(
            child: UnreadJumpPill(
              controller: controller,
              targetKey: targetKey,
              count: 60 - widget.target,
              onSeen: widget.onSeen,
            ),
          ),
        ),
      ],
    );
  }
}

Widget _app(Widget child, {Locale locale = const Locale('en')}) => MaterialApp(
  locale: locale,
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(body: child),
);

Finder get _pill => find.byKey(const ValueKey<String>('unread-jump-pill'));

double _opacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(of: _pill, matching: find.byType(AnimatedOpacity)),
    )
    .opacity;

void main() {
  group('unread rows', () {
    final DateTime since = DateTime.utc(2026, 10, 21, 10);
    final List<Map<String, String>> rows = <Map<String, String>>[
      _row('ai', since.subtract(const Duration(minutes: 5))),
      _row('user', since.add(const Duration(minutes: 1))),
      _row('ai', since.add(const Duration(minutes: 2))),
      _row('ai', since.add(const Duration(minutes: 3))),
      <String, String>{'sender': 'ai', 'text': 'undated'},
    ];

    test('the first row the agent wrote after the mark', () {
      expect(firstUnreadRowIndex(rows, since), 2);
      expect(unreadRowCount(rows, since), 2);
    });

    test('no mark: nothing is unread', () {
      expect(firstUnreadRowIndex(rows, null), -1);
      expect(unreadRowCount(rows, null), 0);
    });

    test('the reader\'s own rows never count', () {
      final List<Map<String, String>> own = <Map<String, String>>[
        _row('user', since.add(const Duration(minutes: 1))),
      ];
      expect(firstUnreadRowIndex(own, since), -1);
    });
  });

  group('AgentReadMarks.markOpened', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      AgentReadMarks.persistDelay = Duration.zero;
    });

    test('keeps the old mark for the visit, then marks read', () async {
      final AgentReadMarks marks = AgentReadMarks();
      final DateTime old = DateTime.utc(2026, 10, 20);
      await marks.markRead('t', when: old);
      await marks.markOpened('t', when: DateTime.utc(2026, 10, 21));
      expect(marks.unreadSince('t'), old);
      expect(marks.lastRead('t'), DateTime.utc(2026, 10, 21));
      marks.clearUnreadSince('t');
      expect(marks.unreadSince('t'), isNull);
    });

    test('a thread never read has no "since"', () async {
      final AgentReadMarks marks = AgentReadMarks();
      await marks.markOpened('fresh');
      expect(marks.unreadSince('fresh'), isNull);
      expect(marks.lastRead('fresh'), isNotNull);
    });
  });

  group('UnreadJumpPill', () {
    testWidgets('first unread above the screen: the pill shows, a tap '
        'scrolls to it and the pill goes', (tester) async {
      int seen = 0;
      await tester.pumpWidget(_app(_Harness(target: 10, onSeen: () => seen++)));
      // The localizations load first; then the thread is on screen.
      await tester.pump();
      await tester.pump();
      // It waits for the thread to settle before it shows.
      expect(_opacity(tester), 0);
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacity(tester), 1);
      expect(find.text('50 new'), findsOneWidget);
      expect(find.text('row 10'), findsNothing);

      await tester.tap(_pill);
      await tester.pumpAndSettle();
      expect(find.text('row 10'), findsOneWidget);
      expect(seen, 1);
      expect(_opacity(tester), 0);
    });

    testWidgets('scrolling there by hand counts as seen', (tester) async {
      int seen = 0;
      await tester.pumpWidget(_app(_Harness(target: 45, onSeen: () => seen++)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacity(tester), 1);
      await tester.drag(find.byType(ListView), const Offset(0, 300));
      await tester.pumpAndSettle();
      // Not there yet: row 45 is still above the screen.
      expect(seen, 0);
      await tester.drag(find.byType(ListView), const Offset(0, 400));
      await tester.pumpAndSettle();
      expect(seen, 1);
      expect(_opacity(tester), 0);
    });

    testWidgets('first unread already on screen: no pill', (tester) async {
      int seen = 0;
      await tester.pumpWidget(_app(_Harness(target: 58, onSeen: () => seen++)));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 300));
      expect(_opacity(tester), 0);
      expect(seen, 1);
    });

    testWidgets('German', (tester) async {
      await tester.pumpWidget(
        _app(
          _Harness(target: 10, onSeen: () {}),
          locale: const Locale('de'),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 450));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('50 neue'), findsOneWidget);
    });
  });
}
