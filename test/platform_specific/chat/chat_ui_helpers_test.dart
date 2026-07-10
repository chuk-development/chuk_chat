import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/chat_model.dart';
import 'package:chuk_chat/models/content_block.dart';
import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/platform_specific/chat/chat_ui_helpers.dart';

void main() {
  group('ChatUiHelpers.finalizeStaleToolCallsInRawMessage', () {
    test('finalizes stale toolCalls JSON entries', () {
      final message = <String, String>{
        'sender': 'ai',
        'text': 'Test',
        'toolCalls': jsonEncode([
          ToolCall(
            id: 'tc-1',
            name: 'web_search',
            status: ToolCallStatus.running,
          ).toJson(),
        ]),
      };

      final changed = ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message);

      expect(changed, isTrue);
      final decoded = (jsonDecode(message['toolCalls']!) as List).cast<Map>();
      final restored = ToolCall.fromJson(Map<String, dynamic>.from(decoded[0]));
      expect(restored.status, ToolCallStatus.error);
      expect(restored.result, isNotEmpty);
    });

    test('finalizes stale toolCalls inside contentBlocks JSON', () {
      final block = ContentBlock.toolCalls([
        ToolCall(
          id: 'tc-2',
          name: 'search_places',
          status: ToolCallStatus.pending,
        ),
      ]);
      final message = <String, String>{
        'sender': 'ai',
        'text': 'Test',
        'contentBlocks': jsonEncode([block.toJson()]),
      };

      final changed = ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message);

      expect(changed, isTrue);
      final decoded = (jsonDecode(message['contentBlocks']!) as List)
          .cast<Map>();
      final restoredBlock = ContentBlock.fromJson(
        Map<String, dynamic>.from(decoded[0]),
      );
      expect(restoredBlock.toolCalls, isNotNull);
      expect(restoredBlock.toolCalls!.first.status, ToolCallStatus.error);
    });

    test('does nothing when all tool calls are already terminal', () {
      final message = <String, String>{
        'sender': 'ai',
        'text': 'Done',
        'toolCalls': jsonEncode([
          ToolCall(
            id: 'tc-3',
            name: 'weather',
            status: ToolCallStatus.completed,
            result: 'Sunny',
          ).toJson(),
        ]),
      };

      final changed = ChatUiHelpers.finalizeStaleToolCallsInRawMessage(message);

      expect(changed, isFalse);
    });
  });

  group('ChatUiHelpers.writeAttachmentsToMessage', () {
    final uuid = const Uuid();

    AttachedFile image(String path) => AttachedFile(
      id: uuid.v4(),
      fileName: 'pic.jpg',
      isImage: true,
      isUploading: false,
      encryptedImagePath: path,
    );

    test('round-trips an image set through reconstructAttachedFilesForResend',
        () {
      final message = <String, String>{'sender': 'user', 'text': 'hi'};
      final files = [image('u/a.enc'), image('u/b.enc')];

      ChatUiHelpers.writeAttachmentsToMessage(message, files);

      // images field holds the encrypted storage paths for the bubble.
      expect(jsonDecode(message['images']!), ['u/a.enc', 'u/b.enc']);

      final restored =
          ChatUiHelpers.reconstructAttachedFilesForResend(message, uuid);
      expect(restored.map((f) => f.encryptedImagePath), [
        'u/a.enc',
        'u/b.enc',
      ]);
    });

    test('removing an image during edit drops it from every stored field', () {
      final message = <String, String>{'sender': 'user', 'text': 'hi'};
      final kept = image('u/keep.enc');
      ChatUiHelpers.writeAttachmentsToMessage(message, [
        kept,
        image('u/remove.enc'),
      ]);

      // Simulate the user removing the second image, then submitting.
      ChatUiHelpers.writeAttachmentsToMessage(message, [kept]);

      expect(jsonDecode(message['images']!), ['u/keep.enc']);
      final restored =
          ChatUiHelpers.reconstructAttachedFilesForResend(message, uuid);
      expect(restored.length, 1);
      expect(restored.single.encryptedImagePath, 'u/keep.enc');
    });

    test('clearing all attachments removes the fields entirely', () {
      final message = <String, String>{'sender': 'user', 'text': 'hi'};
      ChatUiHelpers.writeAttachmentsToMessage(message, [image('u/a.enc')]);

      ChatUiHelpers.writeAttachmentsToMessage(message, const []);

      expect(message.containsKey('images'), isFalse);
      expect(message.containsKey('attachedFilesJson'), isFalse);
      expect(message.containsKey('attachments'), isFalse);
      expect(
        ChatUiHelpers.reconstructAttachedFilesForResend(message, uuid),
        isEmpty,
      );
    });

    test('preserves document attachments separately from images', () {
      final message = <String, String>{'sender': 'user', 'text': 'hi'};
      final doc = AttachedFile(
        id: uuid.v4(),
        fileName: 'notes.md',
        isImage: false,
        isUploading: false,
        markdownContent: '# Notes',
      );

      ChatUiHelpers.writeAttachmentsToMessage(message, [image('u/a.enc'), doc]);

      expect(jsonDecode(message['images']!), ['u/a.enc']);
      final docs = (jsonDecode(message['attachments']!) as List).cast<Map>();
      expect(docs.single['fileName'], 'notes.md');
      expect(docs.single['markdownContent'], '# Notes');
    });
  });

  group('ChatUiHelpers.stableUiKey', () {
    final uuid = const Uuid();

    test('prefers messageId when present', () {
      final message = <String, String>{
        'sender': 'ai',
        'text': 'hi',
        'messageId': 'assistant-123',
      };
      final key = ChatUiHelpers.stableUiKey(message, uuid);
      expect(key, 'assistant-123');
      // Backfilled into the map so it stays constant.
      expect(message[ChatUiHelpers.kUiKeyField], 'assistant-123');
    });

    test('assigns a fresh uuid when no messageId', () {
      final message = <String, String>{'sender': 'user', 'text': 'hi'};
      final key = ChatUiHelpers.stableUiKey(message, uuid);
      expect(key, isNotEmpty);
      expect(key, message[ChatUiHelpers.kUiKeyField]);
    });

    test('is idempotent — repeated calls return the same key', () {
      final message = <String, String>{'sender': 'user', 'text': 'hi'};
      final first = ChatUiHelpers.stableUiKey(message, uuid);
      final second = ChatUiHelpers.stableUiKey(message, uuid);
      expect(first, second);
    });

    test('keeps an already-assigned key even if messageId changes later', () {
      final message = <String, String>{'sender': 'user', 'text': 'hi'};
      final first = ChatUiHelpers.stableUiKey(message, uuid);
      message['messageId'] = 'late-id';
      final second = ChatUiHelpers.stableUiKey(message, uuid);
      expect(second, first);
      expect(second, isNot('late-id'));
    });

    test('distinct messages without ids get distinct keys', () {
      final a = <String, String>{'sender': 'user', 'text': 'a'};
      final b = <String, String>{'sender': 'user', 'text': 'b'};
      expect(
        ChatUiHelpers.stableUiKey(a, uuid),
        isNot(ChatUiHelpers.stableUiKey(b, uuid)),
      );
    });
  });
}
