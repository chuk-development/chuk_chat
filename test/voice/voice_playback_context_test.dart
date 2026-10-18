import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/widgets/message_bubble.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/chat_message.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';
import 'package:chuk_chat/voice/voice_playback_context.dart';
import 'package:chuk_chat/voice/widgets/voice_playback_caption.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  final metadata = jsonEncode({
    'intended_text': 'Hello. Here is the answer.',
    'interrupted': true,
    'generation_complete': true,
  });

  test(
    'model serialization, copies and UI rows preserve playback metadata',
    () {
      final message = ChatMessage(
        role: 'assistant',
        text: 'Hello.',
        voicePlayback: metadata,
        images: '["image.enc"]',
        attachments: '[]',
      );
      final restored = ChatMessage.fromJson(message.toJson())
          .copyWith(text: 'Hello.');
      expect(restored.voicePlayback, metadata);
      expect(restored.images, message.images);
      expect(restored.attachments, message.attachments);
      expect(
        ChatUiHelpers.messageToRawMap(restored)['voicePlayback'],
        metadata,
      );
      expect(ChatUiHelpers.kVariantContentKeys, contains('voicePlayback'));
    },
  );

  test('ordinary and malformed turns keep their original context', () {
    for (final value in [null, '', '{', '[]', '{"interrupted":true}']) {
      expect(voicePlaybackContext('Hello.', value), 'Hello.');
    }
    expect(
      voicePlaybackContext(
        'Hello.',
        jsonEncode({'intended_text': 'Hello.', 'interrupted': false}),
      ),
      'Hello.',
    );
  });

  test(
    'typed history marks intended draft as unheard without changing storage',
    () async {
      final rows = <Map<String, String>>[
        {'sender': 'ai', 'text': 'Hello.', 'voicePlayback': metadata},
      ];
      final history = await ChatHistoryBuilder.build(
        messages: rows,
        pendingUserText: 'Continue',
        includeRecentImages: false,
      );
      final context = history.single['content'] as String;
      expect(context, startsWith('[Voice playback interruption:'));
      expect(context, contains('Only the text labelled Spoken to user'));
      expect(context, contains('do not assume the user heard'));
      expect(context, contains('Hello. Here is the answer.'));
      expect(rows.single['text'], 'Hello.');
    },
  );

  test('changed message text ignores archived playback metadata', () {
    final stale = jsonEncode({
      'spoken_text': 'Old reply',
      'intended_text': 'Old reply continues',
      'interrupted': true,
    });
    expect(voicePlaybackContext('New reply', stale), 'New reply');
  });

  test('partial generation is explicitly not a complete planned answer', () {
    expect(
      voicePlaybackContext(
        '',
        jsonEncode({
          'intended_text': 'Maybe',
          'interrupted': true,
          'generation_complete': false,
        }),
      ),
      contains('generation was not complete'),
    );
  });

  testWidgets('heard text is normal and continuation is dimmed and labelled', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: VoicePlaybackCaption(
            heard: 'Hello.',
            metadata: metadata,
            textStyle: const TextStyle(color: Colors.black),
          ),
        ),
      ),
    );
    expect(find.text('Hello.'), findsOneWidget);
    expect(find.text('Here is the answer.'), findsOneWidget);
    expect(find.text('Interrupted · Not spoken'), findsOneWidget);
    final heard = tester.widget<Text>(find.text('Hello.'));
    final unheard = tester.widget<Text>(find.text('Here is the answer.'));
    expect(heard.style!.color!.a, 1);
    expect(unheard.style!.color!.a, lessThan(heard.style!.color!.a));
  });

  testWidgets(
    'unheard-only draft stays visible without claiming spoken words',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: VoicePlaybackCaption(heard: '', metadata: metadata),
          ),
        ),
      );
      expect(find.text('Hello. Here is the answer.'), findsOneWidget);
      expect(find.text('Interrupted · Not spoken'), findsOneWidget);
    },
  );
  testWidgets('ordinary assistant bubble renders playback metadata', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: const [
          AppLocalizations.delegate,
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SingleChildScrollView(
            child: MessageBubble(
              message: 'Hello.',
              isUser: false,
              voicePlayback: metadata,
              showModelInfo: false,
              showReasoningTokens: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();
    expect(find.text('Hello.'), findsOneWidget);
    expect(find.text('Here is the answer.'), findsOneWidget);
    expect(find.text('Interrupted · Not spoken'), findsOneWidget);
    expect(find.textContaining('Voice playback interruption:'), findsNothing);
  });
}
