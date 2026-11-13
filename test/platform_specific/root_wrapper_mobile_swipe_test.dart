// RootWrapperMobile with `swipeNavigation: true`: the Agents build's phone
// layout for the Chats half (owner, 2026-11-05). No drawer, no bottom bar; a
// top bar with the switch and a title strip; a sideways swipe on the chat
// moves to the next or the previous chat in the same chat view.
//
// The real ChukChatUIMobile is pumped. The seeded chats carry no messages
// and there is no Supabase client, so opening one only reads an empty
// local cache.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/platform_specific/chat/chat_ui_mobile.dart';
import 'package:chuk_chat/platform_specific/mobile/chat_title_strip.dart';
import 'package:chuk_chat/platform_specific/mobile/swipe_chat_pager.dart';
import 'package:chuk_chat/platform_specific/root_wrapper_mobile.dart';
import 'package:chuk_chat/platform_specific/sidebar_mobile.dart';
import 'package:chuk_chat/services/chat_storage_service.dart';
import 'package:chuk_chat/services/chat_storage_state.dart';

import 'mobile/mobile_support.dart' show findId;
import '../support/shell_config.dart';
import '../support/test_app.dart';

const Size _kPhone = Size(360, 800);
const ValueKey<String> _kSwitchKey = ValueKey<String>('test-mode-switch');

/// A chat that is already fully loaded (an empty transcript), so opening it
/// does not go to the backend for its messages.
StoredChat _chat(String id, String title, DateTime at) => StoredChat(
  id: id,
  messages: const <ChatMessage>[],
  createdAt: at,
  updatedAt: at,
  isStarred: false,
  title: title,
);

void _seed() {
  ChatStorageState.chatsById.clear();
  final DateTime now = DateTime.now();
  ChatStorageState.chatsById['a'] = _chat(
    'a',
    'Alpha chat',
    now.subtract(const Duration(minutes: 1)),
  );
  ChatStorageState.chatsById['b'] = _chat(
    'b',
    'Beta chat',
    now.subtract(const Duration(days: 2)),
  );
}

/// Route names pushed on the app's navigator.
class _Routes extends NavigatorObserver {
  final List<String?> pushed = <String?>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushed.add(route.settings.name);
  }
}

Future<void> _pump(WidgetTester tester, {_Routes? routes}) async {
  tester.view.physicalSize = _kPhone;
  tester.view.devicePixelRatio = 1;
  tester.view.padding = const FakeViewPadding(top: 24);
  tester.view.viewPadding = const FakeViewPadding(top: 24);
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      localizationsDelegates: kTestLocalizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      navigatorObservers: <NavigatorObserver>[?routes],
      home: RootWrapperMobile(
        config: testShellConfig(),
        swipeNavigation: true,
        headerCenter: const SizedBox(
          key: _kSwitchKey,
          width: 120,
          height: 40,
          child: Text('Chats | Agents'),
        ),
      ),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// The wrapper schedules deferred work at 2 s and 8 s, and a chat view that
/// had a chat open leaves the chat socket a 60 s idle-close timer.
Future<void> _drain(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump(const Duration(seconds: 61));
}

/// Runs [body] and swallows the one error a test without a backend must
/// see: opening a chat asks ArtifactStorageService for the chat's artifacts
/// (unawaited, as in the plain build), and that reads the Supabase client.
/// Every other error fails the test.
Future<void> _withoutBackend(Future<void> Function() body) async {
  final Completer<void> done = Completer<void>();
  runZonedGuarded(
    () async {
      await body();
      if (!done.isCompleted) done.complete();
    },
    (Object error, StackTrace stack) {
      if (error is StateError &&
          error.message.contains('SupabaseService.initialize()')) {
        return;
      }
      if (!done.isCompleted) done.completeError(error, stack);
    },
  );
  await done.future;
}

String? _stripSelected(WidgetTester tester) =>
    tester.widget<ChatTitleStrip>(find.byType(ChatTitleStrip)).selectedId;

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    ChatStorageService.selectedChatId = null;
    _seed();
  });
  tearDown(() {
    ChatStorageService.selectedChatId = null;
    ChatStorageState.chatsById.clear();
  });

  testWidgets('one top row with the title strip; the menu chip opens the '
      'sidebar, which holds the switch', (tester) async {
    await _pump(tester);

    // Closed: the sidebar is off stage, and so is the switch in its head.
    expect(find.byType(SidebarMobile), findsNothing);
    expect(find.byKey(_kSwitchKey), findsNothing);
    // The plain build's floating bar and its sidebar toggle are gone.
    expect(findId('menu_button'), findsNothing);
    expect(findId('mobile_menu_button'), findsOneWidget);
    expect(findId('mobile_more_button'), findsOneWidget);
    // The strip is in the row, between the chips.
    final Rect menu = tester.getRect(findId('mobile_menu_button'));
    final Rect more = tester.getRect(findId('mobile_more_button'));
    final Rect pill = tester.getRect(find.byType(ChatTitleStrip));
    expect(pill.left, greaterThanOrEqualTo(menu.right));
    expect(pill.right, lessThanOrEqualTo(more.left));
    expect(pill.center.dy, moreOrLessEquals(menu.center.dy, epsilon: 0.5));

    await tester.tap(findId('mobile_menu_button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SidebarMobile), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(SidebarMobile),
        matching: find.byKey(_kSwitchKey),
      ),
      findsOneWidget,
    );
    // Android back closes it and stays in the app.
    await tester.binding.handlePopRoute();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(SidebarMobile), findsNothing);
    expect(find.byType(RootWrapperMobile), findsOneWidget);

    final ChatTitleStrip strip = tester.widget(find.byType(ChatTitleStrip));
    expect(strip.selectedId, '__new__');
    expect(strip.entries.map((SwipeChatEntry e) => e.id).toList(), <String>[
      '__new__',
      'a',
      'b',
    ]);
    expect(
      find.descendant(
        of: find.byType(ChatTitleStrip),
        matching: find.text('New chat'),
      ),
      findsOneWidget,
    );

    // A sideways drag on the chat is the pager's, it does not open the
    // sidebar: on the "New chat" page there is nothing to the left, so it
    // springs back.
    await tester.flingFrom(const Offset(10, 500), const Offset(300, 0), 1500);
    await tester.pump(const Duration(seconds: 1));
    expect(find.byType(SidebarMobile), findsNothing);
    expect(_stripSelected(tester), '__new__');
    await _drain(tester);
  });

  testWidgets('the list follows the store: a new chat shows up live', (
    tester,
  ) async {
    await _pump(tester);
    ChatStorageState.chatsById['c'] = _chat('c', 'Gamma chat', DateTime.now());
    ChatStorageState.notifyChangesImmediate('c');
    await tester.pump();
    expect(
      tester
          .widget<ChatTitleStrip>(find.byType(ChatTitleStrip))
          .entries
          .map((SwipeChatEntry e) => e.id)
          .toList(),
      <String>['__new__', 'c', 'a', 'b'],
    );
    await _drain(tester);
  });

  testWidgets('a swipe left from "New chat" opens the newest chat in the '
      'same chat view', (tester) async {
    await _pump(tester);
    final ChukChatUIMobileState before = tester.state(
      find.byType(ChukChatUIMobile),
    );

    await _withoutBackend(() async {
      await tester.flingFrom(
        const Offset(300, 500),
        const Offset(-250, 0),
        1500,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    });

    expect(ChatStorageService.selectedChatId, 'a');
    expect(_stripSelected(tester), 'a');
    expect(
      find.descendant(
        of: find.byType(ChatTitleStrip),
        matching: find.text('Alpha chat'),
      ),
      findsOneWidget,
    );
    final ChukChatUIMobileState after = tester.state(
      find.byType(ChukChatUIMobile),
    );
    expect(identical(before, after), isTrue);
    expect(
      tester
          .widget<ChukChatUIMobile>(find.byType(ChukChatUIMobile))
          .selectedChatId,
      'a',
    );

    // And back to the right: the "New chat" page again.
    await tester.flingFrom(const Offset(60, 500), const Offset(250, 0), 1500);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pump(const Duration(milliseconds: 400));
    expect(_stripSelected(tester), '__new__');
    expect(ChatStorageService.selectedChatId, isNull);
    expect(
      identical(before, tester.state(find.byType(ChukChatUIMobile))),
      isTrue,
    );
    await _drain(tester);
  });

  testWidgets('a tap on the strip opens no sheet and no list', (tester) async {
    final _Routes routes = _Routes();
    await _pump(tester, routes: routes);
    final int before = routes.pushed.length;
    await tester.tap(find.byType(ChatTitleStrip));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(routes.pushed.length, before);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Search chats'), findsNothing);
    expect(_stripSelected(tester), '__new__');
    await _drain(tester);
  });

  testWidgets('the menu has no Rename or Delete while no chat is selected', (
    tester,
  ) async {
    await _pump(tester);
    await tester.tap(findId('mobile_more_button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Delete'), findsNothing);
    await _drain(tester);
  });

  /// Swipes from "New chat" to the newest chat, 'a'.
  Future<void> openAlpha(WidgetTester tester) async {
    await _withoutBackend(() async {
      await tester.flingFrom(
        const Offset(300, 500),
        const Offset(-250, 0),
        1500,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pump(const Duration(milliseconds: 400));
    });
    expect(_stripSelected(tester), 'a');
  }

  Future<void> openMenu(WidgetTester tester) async {
    await tester.tap(findId('mobile_more_button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('with a chat in view the menu renames it: the dialog holds '
      'its name, Cancel keeps it', (tester) async {
    await _pump(tester);
    await openAlpha(tester);
    await openMenu(tester);
    expect(find.text('Rename'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(find.text('Rename'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Rename chat'), findsOneWidget);
    final TextField field = tester.widget(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(TextField),
      ),
    );
    expect(field.controller!.text, 'Alpha chat');

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsNothing);
    expect(ChatStorageState.chatsById['a']!.title, 'Alpha chat');
    expect(_stripSelected(tester), 'a');
    await _drain(tester);
  });

  testWidgets('with a chat in view the menu deletes it after a question; '
      'Cancel keeps it', (tester) async {
    await _pump(tester);
    await openAlpha(tester);
    await openMenu(tester);

    await tester.tap(find.text('Delete'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('Delete chat?'), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.textContaining('Alpha chat'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.text('Cancel'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(AlertDialog), findsNothing);
    expect(ChatStorageState.chatsById.containsKey('a'), isTrue);
    expect(_stripSelected(tester), 'a');
    await _drain(tester);
  });

  testWidgets('the menu chip opens a sheet; Settings opens the settings '
      'page', (tester) async {
    final _Routes routes = _Routes();
    await _pump(tester, routes: routes);
    await tester.tap(findId('mobile_more_button'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));

    expect(find.text('Settings'), findsOneWidget);
    expect(find.text('Media'), findsOneWidget);
    expect(find.text('Copy full chat'), findsOneWidget);
    // No onAddComputer was given.
    expect(find.text('Add your computer'), findsNothing);

    await tester.tap(find.text('Settings'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    expect(routes.pushed, contains('tour:settings'));
    // Settings may log errors without a backend; the route is what counts.
    tester.takeException();
    await _drain(tester);
  });
}
