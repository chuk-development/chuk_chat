/// The pure half of the `@mention` autocomplete: which token the caret is in,
/// what the text looks like after a pick, and what a query matches. None of it
/// needs a widget, so none of it is tested through one.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/agents_agent.dart';
import 'package:chuk_chat/models/agents_room.dart';
import 'package:chuk_chat/widgets/room_mention_picker.dart';

/// The caret sits where the `|` is; the `|` is removed before the call.
MentionToken? tokenAt(String marked) {
  final int caret = marked.indexOf('|');
  expect(caret, isNot(-1), reason: 'mark the caret with |');
  return activeMentionToken(marked.replaceFirst('|', ''), caret);
}

AgentsAgent agent(String id, String name, {String? role}) =>
    AgentsAgent(id: id, name: name, role: role, threads: const []);

void main() {
  group('activeMentionToken', () {
    test('the caret inside a token reads what was typed', () {
      final MentionToken? t = tokenAt('@am|');
      expect(t, isNotNull);
      expect(t!.start, 0);
      expect(t.end, 3);
      expect(t.query, 'am');
    });

    test('a bare @ is a token with an empty query — list everyone', () {
      final MentionToken? t = tokenAt('@|');
      expect(t, isNotNull);
      expect(t!.query, '');
      expect(t.start, 0);
      expect(t.end, 1);
    });

    test('a token that opens a word mid-sentence is found', () {
      final MentionToken? t = tokenAt('hey @am| can you look');
      expect(t, isNotNull);
      expect(t!.start, 4);
      // The whole run of handle characters, not only what precedes the caret.
      expect(t.end, 7);
      expect(t.query, 'am');
    });

    test('the caret after a completed mention and its space is not in it', () {
      expect(tokenAt('@amber |'), isNull);
      expect(tokenAt('@amber what do you think|'), isNull);
    });

    test('the caret still touching the last character is inside', () {
      expect(tokenAt('@amber|')?.query, 'amber');
    });

    test('an @ in the middle of a word is not a token', () {
      expect(tokenAt('foo@bar|'), isNull);
      expect(tokenAt('foo@|'), isNull);
    });

    test('an email address is not a token', () {
      expect(tokenAt('write to amber@example.com|'), isNull);
      expect(tokenAt('write to amber@exa|mple.com'), isNull);
    });

    test('the caret before the @ is not inside the token', () {
      expect(activeMentionToken('@amber', 0), isNull);
    });

    test('a caret past the end of the text reads nothing', () {
      expect(activeMentionToken('@am', 9), isNull);
      expect(activeMentionToken('@am', -1), isNull);
    });

    test('a newline opens a word just as a space does', () {
      expect(tokenAt('first line\n@am|')?.query, 'am');
    });

    test('a handle may carry digits and dashes', () {
      expect(tokenAt('@re-2|')?.query, 're-2');
    });
  });

  group('applyMention', () {
    test('a token at the start becomes the handle and a space', () {
      final MentionToken t = activeMentionToken('@am', 3)!;
      final MentionEdit e = applyMention(
        text: '@am',
        token: t,
        handle: 'amber',
      );
      expect(e.text, '@amber ');
      expect(e.caret, 7);
    });

    test('a bare @ becomes the handle', () {
      final MentionToken t = activeMentionToken('@', 1)!;
      expect(
        applyMention(text: '@', token: t, handle: 'cobalt'),
        const MentionEdit(text: '@cobalt ', caret: 8),
      );
    });

    test('a token mid-sentence keeps the text after it', () {
      const String text = 'hey @am can you look';
      final MentionToken t = activeMentionToken(text, 7)!;
      final MentionEdit e = applyMention(text: text, token: t, handle: 'amber');
      // The space already there is not doubled; the caret hops over it.
      expect(e.text, 'hey @amber can you look');
      expect(e.caret, 11);
      expect(e.text.substring(0, e.caret), 'hey @amber ');
    });

    test('a token followed by punctuation gets its own space', () {
      const String text = 'ok @am, thanks';
      final MentionToken t = activeMentionToken(text, 6)!;
      final MentionEdit e = applyMention(text: text, token: t, handle: 'amber');
      expect(e.text, 'ok @amber , thanks');
      expect(e.caret, 10);
    });

    test('picking from the middle of a token replaces the whole token', () {
      const String text = '@amb';
      final MentionToken t = activeMentionToken(text, 3)!; // between b and ...
      expect(
        applyMention(text: text, token: t, handle: 'amber'),
        const MentionEdit(text: '@amber ', caret: 7),
      );
    });
  });

  group('mentionEntriesFor / filterMentions', () {
    final List<AgentsRoomMember> members = const <AgentsRoomMember>[
      AgentsRoomMember(agentId: 'a', handle: 'amber'),
      AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
      AgentsRoomMember(agentId: 'c', handle: 'ash'),
    ];
    final List<AgentsAgent> agents = <AgentsAgent>[
      agent('a', 'Amber', role: 'researcher'),
      agent('b', 'Cobalt'),
    ];

    test('an empty room offers nothing at all', () {
      expect(mentionEntriesFor(members: const <AgentsRoomMember>[]), isEmpty);
    });

    test('the broadcast row is first and counts the members', () {
      final List<MentionEntry> e = mentionEntriesFor(members: members);
      expect(e.first.handle, 'all');
      expect(e.first.label, 'Everyone');
      expect(e.first.trailing, '3 coworkers');
      expect(e.first.agentId, isNull);
      expect(e.first.broadcast, isTrue);
    });

    test('a member takes its name and role from the roster', () {
      final List<MentionEntry> e = mentionEntriesFor(
        members: members,
        agents: agents,
      );
      expect(e[1].label, 'Amber');
      expect(e[1].role, 'researcher');
      expect(e[2].role, isNull);
      // No agent on the roster: the handle stands in for the name.
      expect(e[3].label, 'ash');
    });

    test('an empty query lists everyone in room order', () {
      final List<MentionEntry> out = filterMentions(
        mentionEntriesFor(members: members, agents: agents),
        '',
      );
      expect(out.map((MentionEntry e) => e.handle), <String>[
        'all',
        'amber',
        'cobalt',
        'ash',
      ]);
    });

    test('a handle prefix wins over a name prefix, room order inside', () {
      final List<MentionEntry> out = filterMentions(
        mentionEntriesFor(
          members: const <AgentsRoomMember>[
            AgentsRoomMember(agentId: 'a', handle: 'zeta'),
            AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
          ],
          agents: <AgentsAgent>[agent('a', 'Cora'), agent('b', 'Cobalt')],
        ),
        'co',
      );
      // cobalt matches by handle, zeta only by its name Cora.
      expect(out.map((MentionEntry e) => e.handle), <String>['cobalt', 'zeta']);
    });

    test('matching is case-insensitive', () {
      final List<MentionEntry> out = filterMentions(
        mentionEntriesFor(members: members, agents: agents),
        'am',
      );
      expect(out.single.handle, 'amber');
    });

    test('the broadcast row answers to all, everyone and room', () {
      final List<MentionEntry> entries = mentionEntriesFor(members: members);
      for (final String q in <String>['a', 'al', 'ev', 'ro', 'e']) {
        expect(
          filterMentions(entries, q).any((MentionEntry e) => e.broadcast),
          isTrue,
          reason: 'the broadcast row should answer to "$q"',
        );
      }
      // …and it stays on top even when a member matches too.
      expect(filterMentions(entries, 'a').first.broadcast, isTrue);
    });

    test('a query nothing starts with matches nothing', () {
      expect(
        filterMentions(mentionEntriesFor(members: members), 'zzz'),
        isEmpty,
      );
    });
  });

  group('RoomMentionPicker', () {
    Future<void> pumpPicker(
      WidgetTester tester,
      List<MentionEntry> entries, {
      int selected = 0,
      void Function(MentionEntry)? onPick,
    }) => tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.bottomCenter,
            child: RoomMentionPicker(
              entries: entries,
              selected: selected,
              onPick: onPick ?? (_) {},
            ),
          ),
        ),
      ),
    );

    testWidgets('a row names the coworker, the handle and the role', (
      tester,
    ) async {
      await pumpPicker(
        tester,
        mentionEntriesFor(
          members: const <AgentsRoomMember>[
            AgentsRoomMember(agentId: 'a', handle: 'amber'),
          ],
          agents: <AgentsAgent>[agent('a', 'Amber', role: 'researcher')],
        ),
      );
      expect(find.text('Amber'), findsOneWidget);
      expect(find.text('@amber'), findsOneWidget);
      expect(find.text('researcher'), findsOneWidget);
      // The broadcast row is plain: a label, the handle, the count, no face.
      expect(find.text('Everyone'), findsOneWidget);
      expect(find.text('@all'), findsOneWidget);
      expect(find.text('1 coworker'), findsOneWidget);
    });

    testWidgets('a tap reports the row it hit', (tester) async {
      final List<String> picked = <String>[];
      await pumpPicker(
        tester,
        mentionEntriesFor(
          members: const <AgentsRoomMember>[
            AgentsRoomMember(agentId: 'a', handle: 'amber'),
            AgentsRoomMember(agentId: 'b', handle: 'cobalt'),
          ],
        ),
        onPick: (MentionEntry e) => picked.add(e.handle),
      );
      await tester.tap(find.text('@cobalt'));
      expect(picked, <String>['cobalt']);
    });

    testWidgets('a narrow phone at 1.3 text scale fits the row', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: const MediaQueryData(
              size: Size(360, 640),
              textScaler: TextScaler.linear(1.3),
            ),
            child: Scaffold(
              body: Align(
                alignment: Alignment.bottomCenter,
                child: RoomMentionPicker(
                  entries: mentionEntriesFor(
                    members: const <AgentsRoomMember>[
                      AgentsRoomMember(agentId: 'a', handle: 'amber-the-long'),
                    ],
                    agents: <AgentsAgent>[
                      agent(
                        'a',
                        'Amber Understudy Longname',
                        role: 'release manager and note taker',
                      ),
                    ],
                  ),
                  selected: 1,
                  onPick: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      // An overflow paints a striped banner and fails the test on its own; the
      // names only have to stay on one line each.
      expect(find.byType(RoomMentionPicker), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('a long list stays bounded and scrolls', (tester) async {
      await pumpPicker(
        tester,
        mentionEntriesFor(
          members: <AgentsRoomMember>[
            for (int i = 0; i < 20; i++)
              AgentsRoomMember(agentId: 'a$i', handle: 'agent-$i'),
          ],
        ),
      );
      final double height = tester
          .getSize(find.byType(RoomMentionPicker))
          .height;
      expect(height, lessThanOrEqualTo(248));
      expect(find.byType(Scrollable), findsWidgets);
    });
  });
}
