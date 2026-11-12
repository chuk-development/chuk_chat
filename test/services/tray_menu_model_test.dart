import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/services/tray_action_bus.dart';
import 'package:chuk_chat/services/tray_menu_model.dart';

StoredChat _chat(String id, {String? title, String? customName}) =>
    StoredChat.forSidebar(
      id: id,
      createdAt: DateTime(2026, 11, 12),
      isStarred: false,
      title: title,
      customName: customName,
    );

List<String> _labels(List<TrayMenuEntry> entries) =>
    entries.map((e) => e.isSeparator ? '---' : e.label).toList();

void main() {
  final AppLocalizations en = AppLocalizations(const Locale('en'));
  final AppLocalizations de = AppLocalizations(const Locale('de'));

  group('buildTrayMenu', () {
    test('plain build: items in order, window shown', () {
      final entries = buildTrayMenu(
        l: en,
        chats: <StoredChat>[_chat('a', title: 'First chat')],
        windowVisible: true,
      );
      expect(_labels(entries), <String>[
        'New chat',
        '---',
        'Recent chats',
        'First chat',
        '---',
        'Hide window',
        'Settings',
        '---',
        'Quit Chuk Chat',
      ]);
      expect(entries.first.action, TrayMenuAction.newChat);
      expect(entries.last.action, TrayMenuAction.quit);
      expect(entries[2].enabled, isFalse, reason: 'heading is not clickable');
      expect(entries[3].action, TrayMenuAction.openChat);
      expect(entries[3].chatId, 'a');
    });

    test('hidden window offers Show window', () {
      final entries = buildTrayMenu(
        l: en,
        chats: const <StoredChat>[],
        windowVisible: false,
      );
      final toggle = entries.singleWhere(
        (e) => e.action == TrayMenuAction.toggleWindow,
      );
      expect(toggle.label, 'Show window');
    });

    test('no chats shows a disabled placeholder', () {
      final entries = buildTrayMenu(
        l: en,
        chats: const <StoredChat>[],
        windowVisible: true,
      );
      final placeholder = entries.firstWhere((e) => e.label == 'No chats yet');
      expect(placeholder.enabled, isFalse);
      expect(placeholder.action, isNull);
      expect(
        entries.where((e) => e.action == TrayMenuAction.openChat),
        isEmpty,
      );
    });

    test('lists at most five chats, in the given order, skips untitled', () {
      final chats = <StoredChat>[
        _chat('1', title: 'One'),
        _chat('blank'),
        _chat('2', title: 'Two'),
        _chat('3', customName: 'Renamed', title: 'Three'),
        _chat('4', title: 'Four'),
        _chat('5', title: 'Five'),
        _chat('6', title: 'Six'),
      ];
      final recent = buildTrayMenu(
        l: en,
        chats: chats,
        windowVisible: true,
      ).where((e) => e.action == TrayMenuAction.openChat).toList();
      expect(recent.map((e) => e.chatId), <String>['1', '2', '3', '4', '5']);
      expect(recent[2].label, 'Renamed', reason: 'custom name wins');
    });

    test('long titles are cut to one line with an ellipsis', () {
      final entries = buildTrayMenu(
        l: en,
        chats: <StoredChat>[
          _chat('x', title: 'Line one\nline two ${'z' * 80}'),
        ],
        windowVisible: true,
      );
      final item = entries.singleWhere(
        (e) => e.action == TrayMenuAction.openChat,
      );
      expect(item.label.contains('\n'), isFalse);
      expect(item.label.runes.length, kTrayChatTitleMaxChars);
      expect(item.label.endsWith('…'), isTrue);
      expect(item.label.startsWith('Line one line two'), isTrue);
    });

    test(
      'Agents build adds the Chats/Agents pair with the front one checked',
      () {
        final entries = buildTrayMenu(
          l: en,
          chats: const <StoredChat>[],
          windowVisible: true,
          agentsBuild: true,
          agentsInFront: true,
        );
        final chats = entries.singleWhere(
          (e) => e.action == TrayMenuAction.showChats,
        );
        final agents = entries.singleWhere(
          (e) => e.action == TrayMenuAction.showAgents,
        );
        expect(chats.label, 'Chats');
        expect(chats.checked, isFalse);
        expect(agents.label, 'Sidekicks');
        expect(agents.checked, isTrue);
        expect(entries.indexOf(chats), 1, reason: 'right under New chat');
      },
    );

    test('plain build has no Chats/Agents pair', () {
      final entries = buildTrayMenu(
        l: en,
        chats: const <StoredChat>[],
        windowVisible: true,
      );
      expect(
        entries.where(
          (e) =>
              e.action == TrayMenuAction.showChats ||
              e.action == TrayMenuAction.showAgents,
        ),
        isEmpty,
      );
    });

    test('labels follow the UI language', () {
      final entries = buildTrayMenu(
        l: de,
        chats: const <StoredChat>[],
        windowVisible: true,
      );
      expect(
        _labels(entries),
        containsAll(<String>[
          'Letzte Chats',
          'Noch keine Chats',
          'Fenster ausblenden',
          'Chuk Chat beenden',
        ]),
      );
    });
  });

  group('truncateTrayLabel', () {
    test('short text is kept', () {
      expect(truncateTrayLabel('  hello   world '), 'hello world');
    });

    test('does not split a surrogate pair', () {
      final String text = '😀' * 50;
      final String cut = truncateTrayLabel(text, max: 10);
      expect(cut.runes.length, 10);
      expect(cut, '${'😀' * 9}…');
    });
  });

  group('TrayActionBus', () {
    test('requestOpenChat carries the chat and notifies every time', () {
      final bus = TrayActionBus.instance;
      final List<String?> seen = <String?>[];
      void listener() => seen.add(bus.requestedChatId);
      bus.chatOpenRequested.addListener(listener);
      addTearDown(() => bus.chatOpenRequested.removeListener(listener));

      bus.requestOpenChat('c1');
      bus.requestOpenChat('c1');
      expect(seen, <String?>['c1', 'c1']);
    });

    test('requestSettings notifies', () {
      final bus = TrayActionBus.instance;
      var fired = 0;
      void listener() => fired++;
      bus.settingsRequested.addListener(listener);
      addTearDown(() => bus.settingsRequested.removeListener(listener));
      bus.requestSettings();
      expect(fired, 1);
    });
  });
}
