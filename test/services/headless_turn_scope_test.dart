// test/services/headless_turn_scope_test.dart
//
// A background (headless) turn is marked by a zone value: the chat-scoped
// tools see its chat, and tools that need the screen fail with a clear
// tool error instead of waiting for a screen that is not there.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/headless_turn_scope.dart';

void main() {
  test('outside a headless turn nothing is marked', () {
    expect(HeadlessTurnScope.chatId, isNull);
    expect(HeadlessTurnScope.isActive, isFalse);
    expect(HeadlessTurnScope.blockedDeviceAction('sms_draft'), isNull);
  });

  test('the mark reaches every async step of the turn', () async {
    String? inTimer;
    String? afterAwait;
    await HeadlessTurnScope.run('chat-9', () async {
      await Future<void>.delayed(Duration.zero);
      afterAwait = HeadlessTurnScope.chatId;
      final c = Completer<void>();
      Timer(Duration.zero, () {
        inTimer = HeadlessTurnScope.chatId;
        c.complete();
      });
      await c.future;
    });
    expect(afterAwait, 'chat-9');
    expect(inTimer, 'chat-9');
    // Not outside.
    expect(HeadlessTurnScope.chatId, isNull);
  });

  test('screen-only device actions fail in a headless turn', () async {
    await HeadlessTurnScope.run('chat-9', () async {
      for (final a in ['create_calendar_event', 'SMS_DRAFT', 'email_draft']) {
        expect(
          HeadlessTurnScope.blockedDeviceAction(a),
          HeadlessTurnScope.needsScreenError,
        );
      }
      expect(HeadlessTurnScope.blockedDeviceAction('set_timer'), isNull);
      expect(HeadlessTurnScope.blockedDeviceAction('get_location'), isNull);
    });
  });
}
