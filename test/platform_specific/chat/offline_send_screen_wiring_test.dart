// test/platform_specific/chat/offline_send_screen_wiring_test.dart
//
// How the chat screens hand messages to the offline outbox
// (docs/OFFLINE_SEND.md):
//  * a voice recording queued while the user switches chats lands in the
//    chat that started the queue, never in the chat now on screen;
//  * the payload of a fresh send is dropped when its turn ends, and an
//    edit, resend, outbox send or continue never queues an older payload;
//  * desktop restores parked follow-ups also on the cached fast path.
// The screens are too large to pump here, so the wiring is checked in the
// source, and the decision itself through [OfflineSendBridge].

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/platform_specific/chat/offline_send_bridge.dart';

String _src(String file) =>
    File('lib/platform_specific/chat/$file').readAsStringSync();

/// The body of the method that starts with [signature] in [source].
String _body(String source, String signature) {
  final int start = source.indexOf(signature);
  expect(start, isNonNegative, reason: 'missing: $signature');
  // The body opens after the parameter list, which may hold `{` itself.
  final int open =
      RegExp(r'\)\s*(async\s*)?\{').firstMatch(source.substring(start))!.end -
      1 +
      start;
  var depth = 0;
  for (var i = open; i < source.length; i++) {
    if (source[i] == '{') depth++;
    if (source[i] == '}' && --depth == 0) {
      return source.substring(open, i + 1);
    }
  }
  fail('unbalanced body: $signature');
}

void main() {
  group('voice bubble after a chat switch', () {
    final before = <Map<String, String>>[
      {'sender': 'user', 'text': 'old question'},
      {'sender': 'ai', 'text': 'old answer'},
    ];
    final bubble = OfflineSendBridge.voiceBubble(
      queueId: 'q1',
      durationMs: 1200,
      modelId: 'm',
      provider: 'p',
    );

    test('same chat on screen: the live list takes the bubble', () {
      expect(
        OfflineSendBridge.voiceBubbleOffScreen(
          chatId: 'A',
          activeChatId: 'A',
          mounted: true,
          before: before,
          bubble: bubble,
        ),
        isNull,
      );
    });

    test('another chat on screen: the snapshot plus the bubble is saved', () {
      final out = OfflineSendBridge.voiceBubbleOffScreen(
        chatId: 'A',
        activeChatId: 'B',
        mounted: true,
        before: before,
        bubble: bubble,
      )!;
      expect(out.map((m) => m['text']), ['old question', 'old answer', '']);
      expect(out.last['queueId'], 'q1');
      // A copy: the snapshot itself is not changed.
      expect(before, hasLength(2));
    });

    test('the screen went away: the bubble is still saved', () {
      expect(
        OfflineSendBridge.voiceBubbleOffScreen(
          chatId: 'A',
          activeChatId: 'A',
          mounted: false,
          before: before,
          bubble: bubble,
        ),
        hasLength(3),
      );
    });

    for (final file in ['chat_ui_mobile.dart', 'chat_ui_desktop.dart']) {
      test('$file snapshots the chat and checks the target', () {
        final body = _body(_src(file), 'Future<void> _queueVoiceRecording(');
        final int snapshot = body.indexOf(
          'final List<Map<String, String>> before',
        );
        final int firstAwait = body.indexOf('await ');
        expect(snapshot, isNonNegative);
        expect(snapshot, lessThan(firstAwait));
        expect(body, contains('OfflineSendBridge.voiceBubbleOffScreen('));
      });
    }
  });

  group('mobile in-flight payload', () {
    final src = _src('chat_ui_mobile.dart');

    test('the turn end drops it', () {
      expect(
        _body(src, 'Future<void> _finalizeAiMessage('),
        contains('_sendsInFlight.remove(chatId)'),
      );
    });

    test('an edit, resend or outbox send drops it before sending', () {
      final body = _body(src, 'Future<void> _submitEditedMessage(');
      final int clear = body.lastIndexOf('_sendsInFlight.remove(');
      final int send = body.indexOf('_streamingHandler.sendMessage(');
      expect(clear, isNonNegative);
      expect(clear, lessThan(send));
    });

    test('a continue drops it before sending', () {
      final body = _body(src, 'Future<void> _continueGenerationAt(');
      final int clear = body.indexOf('_sendsInFlight.remove(');
      final int send = body.indexOf('_streamingHandler.sendMessage(');
      expect(clear, isNonNegative);
      expect(clear, lessThan(send));
    });
  });

  test('desktop restores parked follow-ups on the cached fast path', () {
    expect(
      _body(
        _src('chat_ui_desktop.dart'),
        'void _applyLoadedChat(StoredChat storedChat, String chatId)',
      ),
      contains('_restoreParkedFollowUp(chatId)'),
    );
  });
}
