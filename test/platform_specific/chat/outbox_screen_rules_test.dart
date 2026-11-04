// test/platform_specific/chat/outbox_screen_rules_test.dart
//
// The screen path of an outbox send (docs/OFFLINE_SEND.md): the screen only
// takes a row whose bubble is the last message; a send that never reached
// the server puts the bubble back into the waiting state and drops the
// error row the send path added.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/outbox_screen_turn.dart';

void main() {
  test('only the last bubble is sendable on screen', () {
    final msgs = <Map<String, String>>[
      {'sender': 'user', 'text': 'a', 'queueId': 'q1'},
      {'sender': 'user', 'text': 'b', 'queueId': 'q2'},
    ];
    expect(OutboxScreenRules.sendableIndex(msgs, 'q2'), 1);
    expect(OutboxScreenRules.sendableIndex(msgs, 'q1'), -1);
    expect(OutboxScreenRules.sendableIndex(<Map<String, String>>[], 'q1'), -1);
  });

  test('restoreWaiting drops the error row and marks the bubble again', () {
    final bubble = <String, String>{'sender': 'user', 'text': 'hi'};
    final msgs = <Map<String, String>>[
      {'sender': 'user', 'text': 'old'},
      bubble,
      {'sender': 'ai', 'text': 'Network error'},
    ];
    final error = OutboxScreenRules.restoreWaiting(
      msgs,
      bubble,
      'q1',
      lengthBefore: 2,
    );
    expect(error, 'Network error');
    expect(msgs.length, 2);
    expect(msgs[1]['status'], 'pending');
    expect(msgs[1]['queueId'], 'q1');
  });

  test('restoreWaiting with no row added only marks the bubble', () {
    final bubble = <String, String>{'sender': 'user', 'text': 'hi'};
    final msgs = <Map<String, String>>[bubble];
    final error = OutboxScreenRules.restoreWaiting(
      msgs,
      bubble,
      'q1',
      lengthBefore: 1,
    );
    expect(error, isNull);
    expect(msgs.single['queueId'], 'q1');
  });

  test('restoreWaiting finds a replaced bubble by its text', () {
    final bubble = <String, String>{'sender': 'user', 'text': 'hi'};
    final msgs = <Map<String, String>>[
      {'sender': 'user', 'text': 'hi'},
      {'sender': 'ai', 'text': 'Failed to start streaming.'},
    ];
    OutboxScreenRules.restoreWaiting(msgs, bubble, 'q1', lengthBefore: 1);
    expect(msgs.length, 1);
    expect(msgs.single['status'], 'pending');
  });

  test('answerShowsWork sees tool calls and content blocks', () {
    final bubble = <String, String>{'sender': 'user', 'text': 'hi'};
    expect(
      OutboxScreenRules.answerShowsWork([
        bubble,
        {'sender': 'ai', 'text': 'x', 'toolCalls': '[{"name":"w"}]'},
      ], bubble),
      isTrue,
    );
    expect(
      OutboxScreenRules.answerShowsWork([
        bubble,
        {'sender': 'ai', 'text': 'Network error'},
      ], bubble),
      isFalse,
    );
    expect(OutboxScreenRules.answerShowsWork([bubble], bubble), isFalse);
  });
}
