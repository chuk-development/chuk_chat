// The outbox line under a user bubble says what happens to a waiting
// message, and its Retry / Send / Delete reach the coordinator. The chat
// list badge counts a chat's waiting rows. The rows come straight from
// OfflineRetryManager.instance.rows; nothing here touches sqflite.

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/models/chat_message.dart' show ChatMessageStatus;
import 'package:chuk_chat/models/queued_message.dart';
import 'package:chuk_chat/services/offline_retry_manager.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:chuk_chat/widgets/message_bubble/outbox_status_line.dart';
import 'package:chuk_chat/widgets/sidebar/sidebar_chrome.dart';

import '../support/icon_finder.dart';

Widget wrap(Widget child) => MaterialApp(
  localizationsDelegates: const <LocalizationsDelegate<Object>>[
    AppLocalizations.delegate,
    GlobalMaterialLocalizations.delegate,
    GlobalWidgetsLocalizations.delegate,
    GlobalCupertinoLocalizations.delegate,
  ],
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: Center(child: SizedBox(width: 360, child: child)),
  ),
);

QueuedMessage row(
  String id, {
  String chatId = 'chat-1',
  OutboxState state = OutboxState.queued,
  String kind = OutboxKind.text,
  Duration age = Duration.zero,
  String? lastError,
}) {
  final int created =
      DateTime.now().millisecondsSinceEpoch - age.inMilliseconds;
  return QueuedMessage(
    id: id,
    chatId: chatId,
    sendPayload: const <String, dynamic>{},
    attemptCount: 0,
    createdAt: created,
    updatedAt: created,
    kind: kind,
    state: state,
    lastError: lastError,
  );
}

void setRows(List<QueuedMessage> list) {
  OfflineRetryManager.instance.rows.value = <String, QueuedMessage>{
    for (final QueuedMessage r in list) r.id: r,
  };
}

/// The localizations load on a later frame; pump once more for them.
Future<void> pumpLine(WidgetTester tester, Widget widget) async {
  await tester.pumpWidget(widget);
  await tester.pump();
}

void main() {
  final List<String> retried = <String>[];
  final List<String> discarded = <String>[];
  int fallbackRetries = 0;

  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    retried.clear();
    discarded.clear();
    fallbackRetries = 0;
  });

  tearDown(() {
    OfflineRetryManager.instance.rows.value = const <String, QueuedMessage>{};
  });

  Widget line({
    ChatMessageStatus? status = ChatMessageStatus.pending,
    String? queueId = 'q1',
  }) => wrap(
    OutboxStatusLine(
      status: status,
      queueId: queueId,
      onRetryFallback: () => fallbackRetries++,
      retryRow: (String id) async => retried.add(id),
      discardRow: (String id) async => discarded.add(id),
    ),
  );

  final Finder retry = find.byKey(const ValueKey<String>('outbox_retry'));
  final Finder delete = find.byKey(const ValueKey<String>('outbox_delete'));
  final Finder busy = find.byKey(const ValueKey<String>('outbox_busy'));

  testWidgets('queued: clock and waiting text, no buttons', (tester) async {
    setRows(<QueuedMessage>[row('q1')]);
    await pumpLine(tester, line());

    expect(find.text('Waiting for network'), findsOneWidget);
    expect(findIcon(Icons.schedule), findsOneWidget);
    expect(retry, findsNothing);
    expect(delete, findsNothing);

    // The armed long-pending timer goes with the widget.
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('queued longer than longPending: Retry calls retryRow', (
    tester,
  ) async {
    setRows(<QueuedMessage>[
      row(
        'q1',
        age: OfflineRetryManager.longPending + const Duration(seconds: 1),
      ),
    ]);
    await pumpLine(tester, line());

    expect(find.text('Waiting for network'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(delete, findsNothing);

    await tester.tap(retry);
    await tester.pump();
    expect(retried, <String>['q1']);
    expect(fallbackRetries, 0);
  });

  testWidgets('preparing voice: transcribing with a spinner', (tester) async {
    setRows(<QueuedMessage>[
      row('q1', state: OutboxState.preparing, kind: OutboxKind.voice),
    ]);
    await pumpLine(tester, line());

    expect(find.text('Transcribing…'), findsOneWidget);
    expect(busy, findsOneWidget);
    expect(retry, findsNothing);
    expect(delete, findsNothing);
  });

  testWidgets('preparing text: uploading', (tester) async {
    setRows(<QueuedMessage>[row('q1', state: OutboxState.preparing)]);
    await pumpLine(tester, line());

    expect(find.text('Uploading…'), findsOneWidget);
    expect(busy, findsOneWidget);
    expect(retry, findsNothing);
  });

  testWidgets('sending: sending text, no buttons', (tester) async {
    setRows(<QueuedMessage>[row('q1', state: OutboxState.sending)]);
    await pumpLine(tester, line());

    expect(find.text('Sending…'), findsOneWidget);
    expect(busy, findsOneWidget);
    expect(retry, findsNothing);
    expect(delete, findsNothing);
  });

  testWidgets('failed: error, Retry and Delete reach the coordinator', (
    tester,
  ) async {
    setRows(<QueuedMessage>[
      row('q1', state: OutboxState.failed, lastError: 'HTTP 500'),
    ]);
    await pumpLine(tester, line(status: ChatMessageStatus.failed));

    expect(find.text('Failed to send'), findsOneWidget);
    expect(findIcon(Icons.error_outline), findsOneWidget);
    expect(find.byTooltip('Failed to send: HTTP 500'), findsOneWidget);
    expect(find.text('Retry'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);

    await tester.tap(retry);
    await tester.pump();
    expect(retried, <String>['q1']);

    await tester.tap(delete);
    await tester.pump();
    expect(discarded, <String>['q1']);
    expect(fallbackRetries, 0);
  });

  testWidgets('held: transcript ready, Send and Delete', (tester) async {
    setRows(<QueuedMessage>[
      row('q1', state: OutboxState.held, kind: OutboxKind.voice),
    ]);
    await pumpLine(tester, line());

    expect(find.text('Transcript ready'), findsOneWidget);
    expect(find.text('Send'), findsOneWidget);
    expect(find.text('Delete'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);

    await tester.tap(retry);
    await tester.pump();
    expect(retried, <String>['q1']);

    await tester.tap(delete);
    await tester.pump();
    expect(discarded, <String>['q1']);
  });

  testWidgets('pending without a row: waiting, Retry is the fallback', (
    tester,
  ) async {
    await pumpLine(tester, line(queueId: 'agents-entry'));

    expect(find.text('Waiting for network'), findsOneWidget);
    expect(findIcon(Icons.schedule), findsOneWidget);
    expect(delete, findsNothing);

    await tester.tap(retry);
    await tester.pump();
    expect(fallbackRetries, 1);
    expect(retried, isEmpty);
  });

  testWidgets('a sent message whose row is gone draws nothing', (
    tester,
  ) async {
    await pumpLine(tester, line(status: null));

    expect(find.text('Waiting for network'), findsNothing);
    expect(retry, findsNothing);
  });

  testWidgets('the line follows the row as its state changes', (tester) async {
    setRows(<QueuedMessage>[row('q1', state: OutboxState.sending)]);
    await pumpLine(tester, line());
    expect(find.text('Sending…'), findsOneWidget);

    setRows(<QueuedMessage>[row('q1', state: OutboxState.failed)]);
    await tester.pump();
    expect(find.text('Sending…'), findsNothing);
    expect(find.text('Failed to send'), findsOneWidget);

    setRows(const <QueuedMessage>[]);
    await tester.pump();
    // Status still says pending: the no-row line takes over.
    expect(find.text('Waiting for network'), findsOneWidget);
  });

  testWidgets('a voice bubble with no text says the recording is saved', (
    tester,
  ) async {
    setRows(<QueuedMessage>[
      row('q1', state: OutboxState.queued, kind: OutboxKind.voice),
    ]);
    await pumpLine(tester, 
      wrap(
        const MessageBubble(
          message: '',
          isUser: true,
          isVoiceInput: true,
          status: ChatMessageStatus.pending,
          queueId: 'q1',
        ),
      ),
    );

    expect(
      find.text('Recording saved — will transcribe when online'),
      findsOneWidget,
    );
    expect(find.text('Waiting for network'), findsOneWidget);

    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('chat list badge counts the chat\'s waiting rows', (
    tester,
  ) async {
    setRows(<QueuedMessage>[
      row('a', chatId: 'chat-1'),
      row('b', chatId: 'chat-1', state: OutboxState.failed),
      row('c', chatId: 'chat-2'),
    ]);
    await pumpLine(tester, wrap(const SbOutboxBadge(chatId: 'chat-1')));

    expect(find.text('2'), findsOneWidget);
    expect(find.byTooltip('2 waiting to send'), findsOneWidget);

    setRows(const <QueuedMessage>[]);
    await tester.pump();
    expect(find.text('2'), findsNothing);
  });
}
