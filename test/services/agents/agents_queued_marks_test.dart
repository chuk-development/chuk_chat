import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/services/agents/agents_queued_marks.dart';

/// The imported bubble offers **Retry** only for a row whose status is
/// `failed` (`widgets/message_bubble/chrome.dart`, imported). A prompt that is
/// waiting in the outbox has to look like that, or the user has no way to ask
/// for it again.
void main() {
  late Map<String, List<Map<String, dynamic>>> store;

  setUp(() {
    store = <String, List<Map<String, dynamic>>>{};
    AgentsQueuedMarks.readRows = (key) => store[key];
    AgentsQueuedMarks.writeRows = (key, rows) async => store[key] = rows;
  });

  tearDown(() {
    AgentsQueuedMarks.readRows = null;
    AgentsQueuedMarks.writeRows = null;
  });

  test('a queued prompt is marked failed, with the outbox id on it', () async {
    store['t'] = <Map<String, dynamic>>[
      <String, dynamic>{'sender': 'user', 'text': 'alte frage'},
      <String, dynamic>{'sender': 'ai', 'text': 'alte antwort'},
      <String, dynamic>{'sender': 'user', 'text': 'neue frage'},
    ];

    expect(
      await AgentsQueuedMarks.markQueued(
        sessionKey: 't',
        prompt: 'neue frage',
        queueId: 'q1',
      ),
      isTrue,
    );

    // failed, not pending: pending gets no Retry button.
    expect(store['t']![2]['status'], 'failed');
    expect(store['t']![2]['queueId'], 'q1');
    // The turn before it is untouched.
    expect(store['t']![0].containsKey('status'), isFalse);
  });

  test('the mark comes off when the prompt goes out', () async {
    store['t'] = <Map<String, dynamic>>[
      <String, dynamic>{
        'sender': 'user',
        'text': 'frage',
        'status': 'failed',
        'queueId': 'q1',
      },
    ];

    expect(
      await AgentsQueuedMarks.clearMark(sessionKey: 't', queueId: 'q1'),
      isTrue,
    );
    expect(store['t']!.single['status'], 'sent');
    expect(store['t']!.single.containsKey('queueId'), isFalse);
  });

  test('a prompt with no row on screen is not an error', () async {
    store['t'] = <Map<String, dynamic>>[
      <String, dynamic>{'sender': 'ai', 'text': 'nur eine antwort'},
    ];
    expect(
      await AgentsQueuedMarks.markQueued(
        sessionKey: 't',
        prompt: 'nie getippt',
        queueId: 'q1',
      ),
      isFalse,
    );
  });

  test('an empty queue id is refused: a bubble must never carry one', () async {
    store['t'] = <Map<String, dynamic>>[
      <String, dynamic>{'sender': 'user', 'text': 'frage'},
    ];
    expect(
      await AgentsQueuedMarks.markQueued(
        sessionKey: 't',
        prompt: 'frage',
        queueId: '',
      ),
      isFalse,
    );
    expect(store['t']!.single.containsKey('status'), isFalse);
  });

  test('the marks a transcript holds are what a rewrite must carry over', () {
    final marks = AgentsQueuedMarks.marksIn(<ChatMessage>[
      ChatMessage(
        role: 'user',
        text: 'wartet',
        status: ChatMessageStatus.failed,
        queueId: 'q1',
      ),
      ChatMessage(
        role: 'user',
        text: 'flugmodus',
        status: ChatMessageStatus.pending,
        queueId: 'q2',
      ),
      // Already gone out: nothing to carry.
      ChatMessage(
        role: 'user',
        text: 'durch',
        status: ChatMessageStatus.sent,
        queueId: 'q3',
      ),
      ChatMessage(role: 'ai', text: 'antwort'),
    ]);

    expect(marks.keys.toList(), <String>['wartet', 'flugmodus']);
    expect(marks['wartet'], <String, String>{
      'status': 'failed',
      'queueId': 'q1',
    });
    expect(marks['flugmodus']!['status'], 'pending');
  });
}
