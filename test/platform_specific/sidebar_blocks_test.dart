// Proves the redesigned sidebar is the block stack it claims to be, on both
// platforms: an account card, a navigation block of three cards, one header
// plus its own block per time group, and a bottom bar with the search field
// and the two round actions.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/stored_chat.dart';
import 'package:chuk_chat/platform_specific/sidebar_desktop.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_common.dart';
import '../helpers/icon_finder.dart';

/// Midnight at the start of the current local day — the anchor every seeded
/// chat is offset from. Anchoring on the same boundary the grouping uses is
/// what keeps the buckets the same at 23:59 as at 00:01; offsets from
/// `DateTime.now()` would drift across it.
DateTime _localMidnight() {
  final DateTime now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}

/// Seeds the store the sidebars read from. Returns nothing — the sidebars
/// pull straight off `ChatStorageState`.
void _seedChats() {
  ChatStorageState.chatsById.clear();
  final DateTime midnight = _localMidnight();
  ChatStorageState.chatsById['a'] = _seedChat(
    id: 'a',
    at: midnight,
    title: 'Alpha chat',
  );
  ChatStorageState.chatsById['b'] = _seedChat(
    id: 'b',
    at: midnight.subtract(const Duration(days: 3)),
    title: 'Beta chat',
  );
  ChatStorageState.chatsById['c'] = _seedChat(
    id: 'c',
    at: midnight.subtract(const Duration(days: 400)),
    title: 'Gamma chat',
    starred: true,
  );
}

StoredChat _seedChat({
  required String id,
  required DateTime at,
  required String title,
  bool starred = false,
}) {
  return StoredChat.forSidebar(
    id: id,
    createdAt: at,
    updatedAt: at,
    isStarred: starred,
    title: title,
  );
}

Widget _host(Widget child) {
  return MaterialApp(
    localizationsDelegates: const [AppLocalizations.delegate],
    home: Scaffold(body: SizedBox(width: 320, child: child)),
  );
}

/// Gives the test a window tall enough that a whole sidebar — account card,
/// navigation block and several groups — is on screen at once, so a missing
/// header means a missing header and not a missing scroll.
void _tallWindow(WidgetTester tester) {
  tester.view.physicalSize = const Size(420, 1400);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// The background update check starts a 5 s timeout timer. Tearing the tree
/// down and letting fake time run past it keeps that timer from outliving
/// the test.
Future<void> _settleStartupWork(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 10));
}

void main() {
  setUp(_seedChats);
  tearDown(ChatStorageState.chatsById.clear);

  group('SidebarDesktop', () {
    testWidgets('replaces a chat title after a single-chat update', (
      tester,
    ) async {
      _tallWindow(tester);
      await tester.pumpWidget(
        _host(
          SidebarDesktop(
            onChatSelected: (_) {},
            onSettingsTapped: () {},
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () {},
            selectedChatId: 'a',
            isCompactMode: false,
            showWorkspacesButton: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Alpha chat'), findsOneWidget);

      ChatStorageState.chatsById['a'] = ChatStorageState.chatsById['a']!
          .copyWith(
            customName: 'Generated summary',
            title: 'Generated summary',
          );
      ChatStorageState.notifyChanges('a');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(find.text('Generated summary'), findsOneWidget);
      expect(find.text('Alpha chat'), findsNothing);
      await _settleStartupWork(tester);
    });

    testWidgets('navigation block holds one card per destination', (
      tester,
    ) async {
      _tallWindow(tester);
      await tester.pumpWidget(
        _host(
          SidebarDesktop(
            onChatSelected: (_) {},
            onSettingsTapped: () {},
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () {},
            selectedChatId: null,
            isCompactMode: false,
            showWorkspacesButton: true,
          ),
        ),
      );
      await tester.pump();

      // New chat leads, on the row the collapsed rail keeps it on.
      // Workspaces is off, so the block is three cards, not four.
      expect(find.byType(SbNavCard), findsNWidgets(3));
      expect(find.text('New chat'), findsOneWidget);
      expect(find.text('Workspaces'), findsNothing);
      expect(find.text('Media'), findsOneWidget);
      expect(find.text('Search'), findsOneWidget);

      await _settleStartupWork(tester);
    });

    testWidgets('every time group has a header and its own chats', (
      tester,
    ) async {
      _tallWindow(tester);
      await tester.pumpWidget(
        _host(
          SidebarDesktop(
            onChatSelected: (_) {},
            onSettingsTapped: () {},
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () {},
            selectedChatId: null,
            isCompactMode: false,
            showWorkspacesButton: true,
          ),
        ),
      );
      await tester.pump();

      // Pinned first, then the time buckets the seed data falls into.
      expect(find.widgetWithText(SbGroupHeader, 'Pinned'), findsOneWidget);
      expect(find.widgetWithText(SbGroupHeader, 'Today'), findsOneWidget);
      expect(find.widgetWithText(SbGroupHeader, 'This week'), findsOneWidget);
      expect(find.text('Alpha chat'), findsOneWidget);
      expect(find.text('Beta chat'), findsOneWidget);
      expect(find.text('Gamma chat'), findsOneWidget);

      // The chevron folds a group away without touching its neighbours.
      await tester.tap(find.widgetWithText(SbGroupHeader, 'Today'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha chat'), findsNothing);
      expect(find.text('Beta chat'), findsOneWidget);
      expect(find.widgetWithText(SbGroupHeader, 'Today'), findsOneWidget);

      await _settleStartupWork(tester);
    });

    testWidgets('the chrome carries the account line and both actions', (
      tester,
    ) async {
      _tallWindow(tester);
      var settings = 0;
      var newChat = 0;
      await tester.pumpWidget(
        _host(
          SidebarDesktop(
            onChatSelected: (_) {},
            onSettingsTapped: () => settings++,
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () => newChat++,
            selectedChatId: null,
            isCompactMode: false,
            showWorkspacesButton: true,
          ),
        ),
      );
      await tester.pump();

      // The account moved out of the list and into the bottom bar, and the
      // search field only exists once the Search row is tapped.
      expect(find.byType(SbAccountLine), findsOneWidget);
      expect(find.byType(SbSearchField), findsNothing);

      await tester.tap(find.byTooltip('Settings'));
      await tester.tap(find.text('New chat'));
      await tester.pump();
      expect(settings, 1);
      expect(newChat, 1);

      // The Search row becomes the field, and typing filters the list
      // without any second field appearing.
      await tester.tap(find.text('Search'));
      await tester.pumpAndSettle();
      expect(find.byType(SbSearchField), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'Beta');
      await tester.pump();
      expect(find.text('Alpha chat'), findsNothing);
      expect(find.text('Beta chat'), findsOneWidget);

      // The field watches its own controller, so the clear button follows
      // the text rather than the host's rebuilds.
      expect(findIcon(Icons.close_rounded), findsOneWidget);
      await tester.tap(findIcon(Icons.close_rounded));
      await tester.pump();
      expect(findIcon(Icons.close_rounded), findsNothing);
      expect(find.text('Alpha chat'), findsOneWidget);

      await _settleStartupWork(tester);
    });

    testWidgets('carries no collapse button — the hamburger is the one', (
      tester,
    ) async {
      _tallWindow(tester);
      await tester.pumpWidget(
        _host(
          SidebarDesktop(
            onChatSelected: (_) {},
            onSettingsTapped: () {},
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () {},
            selectedChatId: null,
            isCompactMode: false,
            showWorkspacesButton: true,
          ),
        ),
      );
      await tester.pump();

      // The host draws the hamburger over the panel's own head bar, so a
      // second control beside it would fold the sidebar twice.
      expect(find.byTooltip('Hide sidebar'), findsNothing);

      await _settleStartupWork(tester);
    });

    testWidgets('the workspaces flag drops its card, not the block', (
      tester,
    ) async {
      _tallWindow(tester);
      await tester.pumpWidget(
        _host(
          SidebarDesktop(
            onChatSelected: (_) {},
            onSettingsTapped: () {},
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () {},
            selectedChatId: null,
            isCompactMode: true,
            showWorkspacesButton: false,
          ),
        ),
      );
      await tester.pump();

      expect(find.text('Workspaces'), findsNothing);
      expect(find.byType(SbNavCard), findsNWidgets(3));

      await _settleStartupWork(tester);
    });

    testWidgets('a folded group stays folded when the list rebuilds', (
      tester,
    ) async {
      _tallWindow(tester);
      Widget sidebar({String? selected}) => _host(
        SidebarDesktop(
          onChatSelected: (_) {},
          onSettingsTapped: () {},
          onWorkspacesTapped: () {},
          onMediaTapped: () {},
          onNewChatTapped: () {},
          selectedChatId: selected,
          isCompactMode: false,
          showWorkspacesButton: true,
        ),
      );

      await tester.pumpWidget(sidebar());
      await tester.pump();
      await tester.tap(find.widgetWithText(SbGroupHeader, 'Today'));
      await tester.pumpAndSettle();
      expect(find.text('Alpha chat'), findsNothing);

      // The fold is remembered by label rather than by index, so a chat
      // arriving in the same bucket joins a group that is still shut.
      ChatStorageState.chatsById['d'] = _seedChat(
        id: 'd',
        at: _localMidnight(),
        title: 'Delta chat',
      );
      await tester.pumpWidget(sidebar(selected: 'b'));
      await tester.pumpAndSettle();

      expect(find.widgetWithText(SbGroupHeader, 'Today'), findsOneWidget);
      expect(find.text('Alpha chat'), findsNothing);
      expect(find.text('Delta chat'), findsNothing);
      expect(find.text('Beta chat'), findsOneWidget);

      await _settleStartupWork(tester);
    });
  });

  group('SidebarMobile', () {
    testWidgets('replaces a chat title after a single-chat update', (
      tester,
    ) async {
      _tallWindow(tester);
      await tester.pumpWidget(
        _host(
          SidebarMobile(
            onChatSelected: (_) {},
            onSettingsTapped: () {},
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () {},
            selectedChatId: 'a',
            isCompactMode: true,
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Alpha chat'), findsOneWidget);

      ChatStorageState.chatsById['a'] = ChatStorageState.chatsById['a']!
          .copyWith(
            customName: 'Generated summary',
            title: 'Generated summary',
          );
      ChatStorageState.notifyChanges('a');
      await tester.pump(const Duration(milliseconds: 150));
      await tester.pump();

      expect(find.text('Generated summary'), findsOneWidget);
      expect(find.text('Alpha chat'), findsNothing);
      await _settleStartupWork(tester);
    });

    testWidgets('shows the same blocks as the desktop sidebar', (tester) async {
      _tallWindow(tester);
      var settings = 0;
      var newChat = 0;
      var collapsed = 0;
      await tester.pumpWidget(
        _host(
          SidebarMobile(
            onChatSelected: (_) {},
            onSettingsTapped: () => settings++,
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () => newChat++,
            onCollapseTapped: () => collapsed++,
            selectedChatId: null,
            isCompactMode: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // Media and Search. The phone keeps its one new-chat action in the
      // head bar, so the list does not repeat it as a row.
      expect(find.byType(SbNavCard), findsNWidgets(2));
      expect(find.text('New chat'), findsNothing);
      // The account moved out of the list and into the bottom bar, and the
      // search field only exists once the Search row is tapped — the bar
      // below carries no second one.
      expect(find.byType(SbAccountLine), findsOneWidget);
      expect(find.byType(SbSearchField), findsNothing);
      expect(find.widgetWithText(SbGroupHeader, 'Pinned'), findsOneWidget);
      expect(find.widgetWithText(SbGroupHeader, 'Today'), findsOneWidget);
      expect(find.text('Alpha chat'), findsOneWidget);

      await tester.tap(find.byTooltip('Settings'));
      await tester.tap(find.byTooltip('New chat'));
      await tester.tap(find.byTooltip('Hide sidebar'));
      await tester.pump();
      expect(settings, 1);
      expect(newChat, 1);
      expect(collapsed, 1);

      await _settleStartupWork(tester);
    });

    testWidgets('a header folds its own group only', (tester) async {
      _tallWindow(tester);
      await tester.pumpWidget(
        _host(
          SidebarMobile(
            onChatSelected: (_) {},
            onSettingsTapped: () {},
            onWorkspacesTapped: () {},
            onMediaTapped: () {},
            onNewChatTapped: () {},
            selectedChatId: null,
            isCompactMode: true,
          ),
        ),
      );
      await tester.pump();
      await tester.pump();

      // The options button carries Material's minimum touch target, so a
      // near miss cannot land on the tile underneath it.
      expect(
        tester.getSize(find.byTooltip('Chat options').first),
        const Size(48, 48),
      );

      expect(find.text('Gamma chat'), findsOneWidget);
      await tester.tap(find.widgetWithText(SbGroupHeader, 'Pinned'));
      await tester.pumpAndSettle();
      expect(find.text('Gamma chat'), findsNothing);
      expect(find.text('Alpha chat'), findsOneWidget);

      await _settleStartupWork(tester);
    });
  });

  group('sbGroupByTime', () {
    final DateTime now = DateTime(2026, 6, 15, 12);
    String month(DateTime d) => '${d.month}/${d.year}';

    List<String> labelsFor(List<DateTime> dates) {
      return sbGroupByTime<DateTime>(
        dates,
        (d) => d,
        monthLabel: month,
        now: now,
      ).map((g) => g.label).toList();
    }

    test('splits today, this week, this month and the older months', () {
      final labels = labelsFor([
        DateTime(2026, 6, 15, 9),
        DateTime(2026, 6, 12),
        DateTime(2026, 6, 2),
        DateTime(2026, 5, 20),
        DateTime(2026, 4, 3),
      ]);
      expect(labels, ['Today', 'This week', 'This month', '5/2026', '4/2026']);
    });

    test('an empty bucket produces no header', () {
      expect(labelsFor([DateTime(2026, 6, 15, 1)]), ['Today']);
      expect(labelsFor(const []), isEmpty);
    });

    test('two chats from the same old month share one group', () {
      final groups = sbGroupByTime<DateTime>(
        [DateTime(2026, 3, 20), DateTime(2026, 3, 2)],
        (d) => d,
        monthLabel: month,
        now: now,
      );
      expect(groups, hasLength(1));
      expect(groups.single.items, hasLength(2));
    });

    test('the week window reaches back six days, not seven', () {
      // 9 June is six days before 15 June and still "this week"; 8 June is
      // not, and falls through to the month bucket.
      expect(labelsFor([DateTime(2026, 6, 9)]), ['This week']);
      expect(labelsFor([DateTime(2026, 6, 8)]), ['This month']);
    });
  });

  group('shared sidebar titles', () {
    test('removes generated title markers and nested markdown wrappers', () {
      expect(
        normalizeSidebarTitle('Title: ## **_Quarterly   plan_**'),
        'Quarterly plan',
      );
    });

    test('prefers a custom name over the stored title and preview', () {
      final chat = StoredChat.forSidebar(
        id: 'title-test',
        createdAt: DateTime(2026),
        isStarred: false,
        title: 'Stored title',
        customName: '**Custom title**',
      );

      expect(deriveSidebarChatTitle(chat), 'Custom title');
    });
  });
}
