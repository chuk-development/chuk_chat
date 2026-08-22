import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/chat_history_builder.dart';

/// The outgoing payload is `{message: <current turn>, history: [...]}` and the
/// server appends `message` itself. If the current turn is ALSO in `history`,
/// every model sees it twice — which is exactly what shipped on mobile until
/// both platforms were pointed at this one builder.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  List<Map<String, String>> msgs(List<List<String>> pairs) =>
      pairs.map((p) => {'sender': p[0], 'text': p[1]}).toList();

  Future<List<Map<String, dynamic>>> build(
    List<Map<String, String>> messages,
    String pending,
  ) => ChatHistoryBuilder.build(
    messages: messages,
    pendingUserText: pending,
    includeRecentImages: false,
  );

  int userTurns(List<Map<String, dynamic>> history, String text) =>
      history.where((h) => h['role'] == 'user' && h['content'] == text).length;

  group('the pending user turn never lands in history', () {
    test('mobile shape: the turn was already appended to the list', () async {
      // chat_ui_mobile appends the user bubble and a "Thinking..." placeholder
      // before handing the same list over.
      final history = await build(
        msgs([
          ['user', 'hi'],
          ['ai', 'Thinking...'],
        ]),
        'hi',
      );

      expect(
        userTurns(history, 'hi'),
        0,
        reason: 'the pending turn travels in `message`, not in `history`',
      );
    });

    test('desktop shape: the turn is not in the list yet', () async {
      final history = await build(
        msgs([
          ['user', 'erste frage'],
          ['ai', 'erste antwort'],
        ]),
        'hi',
      );

      expect(userTurns(history, 'erste frage'), 1);
      expect(userTurns(history, 'hi'), 0);
    });

    test('both platform shapes produce the same history', () async {
      // The regression that started this: desktop was fixed, mobile was not.
      const priorTurns = [
        ['user', 'erste frage'],
        ['ai', 'erste antwort'],
      ];

      final desktop = await build(msgs(priorTurns), 'hi');
      final mobile = await build(
        msgs([
          ...priorTurns,
          ['user', 'hi'],
          ['ai', 'Thinking...'],
        ]),
        'hi',
      );

      expect(mobile, equals(desktop));
    });

    test('the same text twice in a row keeps the answered copy', () async {
      final history = await build(
        msgs([
          ['user', 'hi'],
          ['ai', 'Hallo!'],
          ['user', 'hi'],
          ['ai', 'Thinking...'],
        ]),
        'hi',
      );

      expect(
        userTurns(history, 'hi'),
        1,
        reason: 'the earlier "hi" was answered and is real history',
      );
      expect(history.last['role'], 'assistant');
    });

    test('an identical earlier turn survives when it is not last', () async {
      final history = await build(
        msgs([
          ['user', 'hi'],
          ['ai', 'Hallo!'],
          ['user', 'was geht'],
          ['ai', 'Nicht viel.'],
        ]),
        'hi',
      );

      expect(userTurns(history, 'hi'), 1);
    });

    test('surrounding whitespace does not defeat the match', () async {
      final history = await build(
        msgs([
          ['user', '  hi  '],
          ['ai', 'Thinking...'],
        ]),
        'hi',
      );

      expect(history, isEmpty);
    });

    test('an empty pending text drops nothing', () async {
      final history = await build(
        msgs([
          ['user', 'hi'],
          ['ai', 'Hallo!'],
        ]),
        '',
      );

      expect(userTurns(history, 'hi'), 1);
    });
  });

  group('history shape', () {
    test('the "Thinking..." placeholder is never sent', () async {
      final history = await build(
        msgs([
          ['user', 'frage'],
          ['ai', 'Thinking...'],
        ]),
        'frage',
      );

      expect(history, isEmpty);
    });

    test('empty user texts are skipped', () async {
      final history = await build(
        msgs([
          ['user', '   '],
          ['user', 'echte frage'],
          ['ai', 'antwort'],
        ]),
        'neue frage',
      );

      expect(history, hasLength(2));
      expect(history.first['content'], 'echte frage');
    });

    test('assistant turns are labelled with the assistant role', () async {
      final history = await build(
        msgs([
          ['user', 'frage'],
          ['assistant', 'antwort'],
        ]),
        'neue frage',
      );

      expect(history.last['role'], 'assistant');
    });
  });

  group('entryText', () {
    test('reads a bare string', () {
      expect(ChatHistoryBuilder.entryText({'content': ' hi '}), 'hi');
    });

    test('reads the text parts of a multimodal entry', () {
      expect(
        ChatHistoryBuilder.entryText({
          'content': [
            {'type': 'text', 'text': 'schau mal'},
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,AAA'},
            },
          ],
        }),
        'schau mal',
      );
    });

    test('returns empty for an unexpected shape', () {
      expect(ChatHistoryBuilder.entryText({'content': 42}), '');
    });
  });

  group('document attachments stay in context for every later turn', () {
    // The stored user `text` is only the display line; the document body lives
    // in `message['attachments']`. The builder must fold the body back into the
    // history text so a follow-up ("solve it") still sees the document.
    List<Map<String, String>> withDoc({
      required String display,
      required String fileName,
      required String content,
    }) => [
      {
        'sender': 'user',
        'text': display,
        'attachments': '[{"fileName":"$fileName","markdownContent":"$content"}]',
      },
      {'sender': 'ai', 'text': 'analysed it'},
      {'sender': 'user', 'text': 'solve it'},
    ];

    test('the document body reaches history on a later turn', () async {
      final history = await build(
        withDoc(
          display: 'Documents: "note.txt"',
          fileName: 'note.txt',
          content: 'ICELAND IS THE KEY',
        ),
        'solve it',
      );

      final firstUser = history.firstWhere((h) => h['role'] == 'user');
      final content = firstUser['content'] as String;
      expect(content, contains('ICELAND IS THE KEY'));
      expect(content, contains('Document: "note.txt"'));
      // The display line is kept too.
      expect(content, contains('Documents: "note.txt"'));
    });

    test('a document-only turn (no typed text) still carries the body',
        () async {
      final history = await build([
        {
          'sender': 'user',
          'text': '',
          'attachments':
              '[{"fileName":"a.txt","markdownContent":"BODY TEXT"}]',
        },
      ], '');

      expect(history, hasLength(1));
      expect(history.first['content'], contains('BODY TEXT'));
    });

    test('messages without attachments are left untouched', () async {
      expect(
        ChatHistoryBuilder.foldAttachmentsIntoText(
          {'sender': 'user', 'text': 'plain'},
          'plain',
        ),
        'plain',
      );
    });

    test('malformed attachments JSON falls back to the display text', () {
      expect(
        ChatHistoryBuilder.foldAttachmentsIntoText(
          {'attachments': 'not json'},
          'shown',
        ),
        'shown',
      );
    });
  });
}
