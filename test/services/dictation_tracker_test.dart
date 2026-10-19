import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_payload_codec.dart';
import 'package:chuk_chat/services/chat_storage_sync.dart'
    show deserializePayloadIsolate;
import 'package:chuk_chat/services/dictation_tracker.dart';

void main() {
  group('DictationTracker', () {
    test('sent as dictated: voice keys with duration, used once', () {
      final t = DictationTracker()
        ..record('hello there', duration: const Duration(seconds: 4));
      expect(t.takeFor('  hello there '), <String, String>{
        'inputMode': 'voice',
        'voiceDurationMs': '4000',
      });
      expect(t.takeFor('hello there'), isEmpty);
    });

    test('a small fix stays voice, a rewrite is typed', () {
      final t = DictationTracker()
        ..record('I want to go to Kiel on friday morning please');
      expect(
        t.takeFor('I want to go to Kiel on Friday morning please'),
        isNotEmpty,
      );
      t.record('short');
      expect(t.takeFor('something completely different and longer'), isEmpty);
    });

    test('an old dictation expires', () {
      DateTime now = DateTime(2026, 1, 1, 12);
      final t = DictationTracker(clock: () => now)..record('hi there');
      now = now.add(const Duration(hours: 1));
      expect(t.takeFor('hi there'), isEmpty);
    });

    test('edit: rewrite by hand drops the voice keys', () {
      final t = DictationTracker();
      final msg = <String, String>{
        'sender': 'user',
        'text': 'a long dictated sentence about the weather',
        'inputMode': 'voice',
        'voiceDurationMs': '3000',
      };
      t.applyToEdit(msg, 'a long dictated sentence about the weather!');
      expect(isVoiceInput(msg), isTrue);
      t.applyToEdit(msg, 'nope');
      expect(isVoiceInput(msg), isFalse);
      expect(msg.containsKey('voiceDurationMs'), isFalse);
    });
  });

  group('payload', () {
    test('voice keys survive ChatMessage + v3 round trip', () {
      final voice = ChatMessage(
        role: 'user',
        text: 'dictated text',
        inputMode: 'voice',
        voiceDurationMs: '12345',
      );
      final typed = ChatMessage(role: 'user', text: 'typed text');
      final v3 = encodeChatPayload([voice.toJson(), typed.toJson()]);
      final back = [
        for (final m in deserializePayloadIsolate(v3).messages)
          ChatMessage.fromJson(m),
      ];
      expect(back[0].inputMode, 'voice');
      expect(back[0].voiceDurationMs, '12345');
      expect(back[1].inputMode, isNull);
      expect(back[1].toJson().containsKey('inputMode'), isFalse);
    });

    test('UI map keeps the keys', () {
      final map = ChatUiHelpers.messageToRawMap(
        ChatMessage(
          role: 'user',
          text: 'x',
          inputMode: 'voice',
          voiceDurationMs: '900',
        ),
      );
      expect(isVoiceInput(map), isTrue);
      expect(voiceInputDuration(map), const Duration(milliseconds: 900));
    });

    test('an old v2 payload without the key reads as typed', () {
      final v2 = jsonEncode({
        'v': 2,
        'messages': [
          {'role': 'user', 'text': 'old'},
        ],
      });
      final m = ChatMessage.fromJson(
        deserializePayloadIsolate(v2).messages.single,
      );
      expect(m.inputMode, isNull);
    });
  });
}
