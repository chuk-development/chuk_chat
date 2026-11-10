// The `/` and `@` menu with atomic chips (idea 68): trigger detection, the
// fuzzy order, the keyboard (arrows, Tab drills, Enter picks, Esc), taps,
// chips that Backspace selects before it deletes, at 360 px and desktop width.

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/skill.dart';
import 'package:chuk_chat/services/composer/composer_trigger.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/widgets/composer/chip_text_controller.dart';
import 'package:chuk_chat/widgets/composer/composer_trigger_menu.dart';
import 'package:chuk_chat/widgets/composer/composer_trigger_sources.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TextEditingValue _at(String text, [int? caret]) => TextEditingValue(
  text: text,
  selection: TextSelection.collapsed(offset: caret ?? text.length),
);

List<TriggerItem> _items({
  List<String> picked = const <String>[],
}) => <TriggerItem>[
  for (final String s in <String>['deep-research', 'weather-cards', 'openui'])
    TriggerItem(
      id: 'skill:$s',
      label: s,
      group: TriggerGroup.skills,
      icon: Icons.auto_awesome,
      chipLiteral: '/$s',
      chipKind: ComposerChipKind.skill,
    ),
  TriggerItem(
    id: 'cmd:new',
    label: 'New chat',
    group: TriggerGroup.commands,
    icon: Icons.edit,
    onPicked: () => picked.add('new'),
  ),
];

void main() {
  group('detectTrigger', () {
    test('a / or @ at a word start, caret after it', () {
      expect(detectTrigger(_at('/'))!.query, '');
      expect(detectTrigger(_at('hi @da'))!.query, 'da');
      expect(detectTrigger(_at('hi @da'))!.start, 3);
      expect(detectTrigger(_at('/deep'))!.trigger, '/');
    });

    test('not inside words, paths, mails or a selection', () {
      expect(detectTrigger(_at('mail me@home')), isNull);
      expect(detectTrigger(_at('a/b')), isNull);
      expect(detectTrigger(_at('/usr/bin')), isNull);
      expect(detectTrigger(_at('hi @da ')), isNull, reason: 'word ended');
      expect(
        detectTrigger(
          const TextEditingValue(
            text: '/abc',
            selection: TextSelection(baseOffset: 0, extentOffset: 4),
          ),
        ),
        isNull,
      );
    });

    test('a chip own @ is not a trigger', () {
      expect(detectTrigger(_at('@Notes'), inChip: (o) => o == 0), isNull);
    });
  });

  test('fuzzy: prefix first, then word start, contains, subsequence', () {
    expect(fuzzyTier('dee', 'deep-research'), 0);
    expect(fuzzyTier('res', 'deep-research'), 1);
    expect(fuzzyTier('ear', 'deep-research'), 2);
    expect(fuzzyTier('drs', 'deep-research'), 3);
    expect(fuzzyTier('xyz', 'deep-research'), isNull);
    final List<TriggerItem> ranked = filterTriggerItems(<TriggerItem>[
      for (final String l in <String>['apples-red', 'red', 'bread', 'rxexd'])
        TriggerItem(
          id: l,
          label: l,
          group: TriggerGroup.files,
          icon: Icons.add,
        ),
    ], 'red');
    expect(ranked.map((i) => i.label), <String>[
      'red',
      'apples-red',
      'bread',
      'rxexd',
    ]);
  });

  group('ChipTextEditingController', () {
    test('a chip keeps its text; Backspace selects it, then deletes it', () {
      final c = ChipTextEditingController(text: 'see /de');
      c.selection = const TextSelection.collapsed(offset: 7);
      c.insertChip(
        start: 4,
        end: 7,
        literal: '/deep-research',
        label: '/deep-research',
        kind: ComposerChipKind.skill,
      );
      expect(c.text, 'see /deep-research ');
      expect(c.chips.single.start, 4);
      expect(c.chips.single.end, 18);
      // Remove the space first (plain text).
      c.value = _at('see /deep-research');
      expect(c.chips, hasLength(1));
      // First Backspace at the chip end: the chip is selected, not cut.
      c.value = _at('see /deep-researc');
      expect(c.text, 'see /deep-research');
      expect(c.selection, const TextSelection(baseOffset: 4, extentOffset: 18));
      // Second Backspace deletes the selection: the whole chip.
      c.value = _at('see ', 4);
      expect(c.text, 'see ');
      expect(c.chips, isEmpty);
    });

    test('the caret never stops inside a chip', () {
      final c = ChipTextEditingController(text: '@x');
      c.insertChip(start: 0, end: 2, literal: '@Notes', label: '@Notes');
      c.selection = const TextSelection.collapsed(offset: 0);
      c.selection = const TextSelection.collapsed(offset: 3);
      expect(c.selection.baseOffset, 6, reason: 'moved right: to the end');
      c.selection = const TextSelection.collapsed(offset: 7);
      c.selection = const TextSelection.collapsed(offset: 4);
      expect(c.selection.baseOffset, 0, reason: 'moved left: to the start');
    });

    test('typing before a chip moves it; clearing drops it', () {
      final c = ChipTextEditingController(text: '@x');
      c.insertChip(start: 0, end: 2, literal: '@Notes', label: '@Notes');
      c.value = const TextEditingValue(
        text: 'a@Notes ',
        selection: TextSelection.collapsed(offset: 1),
      );
      expect(c.chips.single.start, 1);
      expect(c.chips.single.end, 7);
      c.clear();
      expect(c.chips, isEmpty);
    });
  });

  group('ComposerTriggerController', () {
    test('keyboard: Tab drills a group, Enter picks, Esc closes', () {
      final picked = <String>[];
      final text = ChipTextEditingController();
      final menu = ComposerTriggerController(
        text: text,
        source: () =>
            ComposerTriggerSource(slash: () => _items(picked: picked)),
      );
      text.value = _at('/');
      expect(menu.isOpen, isTrue);
      // No query: one row per group; the single command shows as itself.
      expect(menu.visible.first.isGroup, isTrue);
      expect(menu.visible.last.label, 'New chat');
      bool key(LogicalKeyboardKey k) => menu.handleKey(
        KeyDownEvent(
          physicalKey: PhysicalKeyboardKey.keyA,
          logicalKey: k,
          timeStamp: Duration.zero,
        ),
      );
      expect(key(LogicalKeyboardKey.tab), isTrue);
      expect(menu.group?.group, TriggerGroup.skills);
      expect(menu.visible, hasLength(3));
      expect(key(LogicalKeyboardKey.arrowDown), isTrue);
      expect(key(LogicalKeyboardKey.enter), isTrue);
      expect(text.text, '/weather-cards ');
      expect(text.chips.single.kind, ComposerChipKind.skill);
      expect(menu.isOpen, isFalse);

      text.value = _at('${text.text}/new');
      expect(menu.visible.single.label, 'New chat');
      expect(key(LogicalKeyboardKey.escape), isTrue);
      expect(menu.isOpen, isFalse, reason: 'Esc closes');
      text.value = _at('${text.text}x');
      expect(menu.isOpen, isFalse, reason: 'stays closed in that word');
      menu.dispose();
    });

    test('a command runs and leaves no text', () {
      final picked = <String>[];
      final text = ChipTextEditingController();
      final menu = ComposerTriggerController(
        text: text,
        source: () =>
            ComposerTriggerSource(slash: () => _items(picked: picked)),
      );
      text.value = _at('/new');
      menu.pick(menu.visible.single);
      expect(picked, <String>['new']);
      expect(text.text, '');
      menu.dispose();
    });
  });

  test('sources: skills, commands, files of the chat, other chats', () async {
    final l = AppLocalizations(const Locale('en'));
    final refs = <String>[];
    final src = buildComposerTriggerSource(
      l: l,
      chatId: 'me',
      messages: <Map<String, String>>[
        <String, String>{
          'sender': 'user',
          'text': 'x',
          'attachments': '[{"fileName":"plan.pdf","markdownContent":"m"}]',
        },
      ],
      agentsThread: false,
      onNewChat: () {},
      onReferenceChat: refs.add,
      skills: const <Skill>[
        Skill(name: 'deep-research', description: 'Research', body: 'b'),
      ],
      chats: <StoredChat>[
        StoredChat(
          id: 'me',
          createdAt: DateTime(2026),
          isStarred: false,
          customName: 'Self',
        ),
        StoredChat(
          id: 'c2',
          createdAt: DateTime(2026),
          isStarred: false,
          customName: 'Budget',
        ),
      ],
    );
    final slash = await src.slash();
    expect(slash.map((i) => i.id), <String>['skill:deep-research', 'cmd:new']);
    final at = await src.at();
    expect(at.map((i) => i.id), <String>['file:plan.pdf', 'chat:c2']);
    at.last.onPicked!();
    expect(refs, <String>['c2']);
    expect(at.last.chipLiteral, '@Budget');
  });

  for (final double width in <double>[360, 1280]) {
    testWidgets('menu in a field at $width px: tap picks, chip renders', (
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = Size(width, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final text = ChipTextEditingController();
      final menu = ComposerTriggerController(
        text: text,
        source: () => ComposerTriggerSource(slash: () => _items()),
      );
      addTearDown(menu.dispose);
      await tester.pumpWidget(
        MaterialApp(
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            AppLocalizations.delegate,
          ],
          home: Scaffold(
            body: Align(
              alignment: Alignment.bottomCenter,
              child: SizedBox(
                width: width - 16,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ComposerTriggerMenu(controller: menu),
                    TextField(controller: text, maxLines: null),
                  ],
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump(); // The string table loads asynchronously.
      await tester.enterText(find.byType(TextField), '/de');
      await tester.pump();
      expect(find.byKey(const ValueKey('composer-trigger-menu')), findsOne);
      await tester.tap(
        find.byKey(const ValueKey('composer-trigger-row-skill:deep-research')),
      );
      await tester.pump();
      expect(find.byKey(const ValueKey('composer-trigger-menu')), findsNothing);
      expect(text.text, '/deep-research ');
      expect(find.byType(ComposerChipPill), findsOne);
      expect(tester.takeException(), isNull);
    });
  }
}
