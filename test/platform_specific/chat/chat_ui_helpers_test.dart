import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'package:uuid/uuid.dart';

import 'package:chuk_chat/models/chat_message.dart';
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

  group('ChatUiHelpers.messageToRawMap', () {
    test('preserves messageId, status and queueId across the bridge', () {
      final message = ChatMessage(
        role: 'assistant',
        text: 'partial',
        status: ChatMessageStatus.interrupted,
        queueId: 'q-9',
        messageId: 'm-1',
      );
      final raw = ChatUiHelpers.messageToRawMap(message);
      expect(raw['messageId'], 'm-1');
      expect(raw['status'], 'interrupted');
      expect(raw['queueId'], 'q-9');
    });

    test('omits status/queueId when unset', () {
      final raw = ChatUiHelpers.messageToRawMap(
        ChatMessage(role: 'user', text: 'hi'),
      );
      expect(raw.containsKey('status'), isFalse);
      expect(raw.containsKey('queueId'), isFalse);
    });
  });

  group('ChatMessage.statusString', () {
    test('round-trips every status value', () {
      for (final s in ChatMessageStatus.values) {
        final msg = ChatMessage(role: 'user', text: 't', status: s);
        expect(ChatMessage.fromJson(msg.toJson()).status, s);
      }
    });

    test('is null when status is unset', () {
      expect(ChatMessage(role: 'user', text: 't').statusString, isNull);
    });
  });

  group('answer-version pager helpers', () {
    Map<String, String> aiMessage() => <String, String>{
      'sender': 'ai',
      'text': 'first answer',
      'reasoning': 'thinking one',
      'contentBlocks': '[{"type":"text","text":"first answer"}]',
      'modelId': 'gpt-4',
      'provider': 'openai',
      'messageId': 'mid-1',
      'startedAt': '2024-01-01T00:00:00.000Z',
      'generationMs': '1200',
    };

    test('variantSnapshotOf captures content + archive keys, skips empties',
        () {
      final msg = aiMessage()
        ..['images'] = '' // empty → skipped
        ..['tps'] = '42' // per-answer metric → captured
        ..['debugRequests'] = '[]'; // not a variant key → skipped
      final snap = ChatUiHelpers.variantSnapshotOf(msg);

      expect(snap['text'], 'first answer');
      expect(snap['reasoning'], 'thinking one');
      expect(snap['contentBlocks'], '[{"type":"text","text":"first answer"}]');
      expect(snap['modelId'], 'gpt-4');
      expect(snap['provider'], 'openai');
      expect(snap['generationMs'], '1200');
      expect(snap['tps'], '42');
      // Archive-only keys captured for round-trip completeness.
      expect(snap['messageId'], 'mid-1');
      expect(snap['startedAt'], '2024-01-01T00:00:00.000Z');
      // Empty + non-variant keys excluded.
      expect(snap.containsKey('images'), isFalse);
      expect(snap.containsKey('debugRequests'), isFalse);
    });

    test('writeVariants appends current as the active (last) variant', () {
      final oldSnap = ChatUiHelpers.variantSnapshotOf(aiMessage());

      final message = aiMessage()
        ..['text'] = 'second answer'
        ..['reasoning'] = 'thinking two'
        ..['contentBlocks'] = '[{"type":"text","text":"second answer"}]';
      final newSnap = ChatUiHelpers.variantSnapshotOf(message);

      ChatUiHelpers.writeVariants(
        message: message,
        seed: <Map<String, dynamic>>[oldSnap],
        current: newSnap,
      );

      final decoded = ChatUiHelpers.decodeVariants(message['variants']);
      expect(decoded.length, 2);
      expect(decoded[0]['text'], 'first answer');
      expect(decoded[1]['text'], 'second answer');
      expect(message['activeVariant'], '1');
    });

    test('writeVariants stays at seed+1 when called twice (desktop re-fold)',
        () {
      // The desktop path folds twice per turn: once in _finalizeAiMessage,
      // again after content blocks land. The archive must not grow, and the
      // second call must capture the now-present content blocks.
      final oldSnap = ChatUiHelpers.variantSnapshotOf(aiMessage());
      final message = aiMessage()..['text'] = 'second answer';

      ChatUiHelpers.writeVariants(
        message: message,
        seed: <Map<String, dynamic>>[oldSnap],
        current: ChatUiHelpers.variantSnapshotOf(message),
      );
      // Content blocks land after the first fold on the desktop success path.
      message['contentBlocks'] = '[{"type":"text","text":"second answer"}]';
      ChatUiHelpers.writeVariants(
        message: message,
        seed: <Map<String, dynamic>>[oldSnap],
        current: ChatUiHelpers.variantSnapshotOf(message),
      );

      final decoded = ChatUiHelpers.decodeVariants(message['variants']);
      expect(decoded.length, 2);
      expect(
        decoded[1]['contentBlocks'],
        '[{"type":"text","text":"second answer"}]',
      );
      expect(message['activeVariant'], '1');
    });

    test('variant snapshot captures tps and switch restores it', () {
      final message = aiMessage()..['tps'] = '55.5';
      ChatUiHelpers.writeVariants(
        message: message,
        seed: <Map<String, dynamic>>[
          <String, dynamic>{'text': 'older', 'tps': '10.0'},
        ],
        current: ChatUiHelpers.variantSnapshotOf(message),
      );
      expect(ChatUiHelpers.switchVariant(message, 0), isTrue);
      expect(message['tps'], '10.0');
      expect(ChatUiHelpers.switchVariant(message, 1), isTrue);
      expect(message['tps'], '55.5');
    });

    test('switchVariant swaps top-level content and drops absent keys', () {
      // Variant 0 has no contentBlocks; variant 1 (current) has them.
      final variantZero = <String, dynamic>{
        'text': 'first answer',
        'modelId': 'gpt-4',
      };
      final message = <String, String>{
        'sender': 'ai',
        'text': 'second answer',
        'contentBlocks': '[{"type":"text","text":"second answer"}]',
        'modelId': 'gpt-4o',
        'messageId': 'mid-2',
      };
      ChatUiHelpers.writeVariants(
        message: message,
        seed: <Map<String, dynamic>>[variantZero],
        current: ChatUiHelpers.variantSnapshotOf(message),
      );
      expect(message['activeVariant'], '1');

      // Switch to the older variant.
      final ok = ChatUiHelpers.switchVariant(message, 0);
      expect(ok, isTrue);
      expect(message['text'], 'first answer');
      expect(message['modelId'], 'gpt-4');
      expect(message['activeVariant'], '0');
      // contentBlocks absent in variant 0 → removed from top level so no stale
      // tool cards linger.
      expect(message.containsKey('contentBlocks'), isFalse);
      // The message keeps its own stable id (not restored from the variant).
      expect(message['messageId'], 'mid-2');

      // Switch back to the newest variant restores its content.
      expect(ChatUiHelpers.switchVariant(message, 1), isTrue);
      expect(message['text'], 'second answer');
      expect(
        message['contentBlocks'],
        '[{"type":"text","text":"second answer"}]',
      );
      expect(message['activeVariant'], '1');
    });

    test('switchVariant rejects out-of-range indices', () {
      final message = aiMessage();
      ChatUiHelpers.writeVariants(
        message: message,
        seed: const <Map<String, dynamic>>[],
        current: ChatUiHelpers.variantSnapshotOf(message),
      );
      expect(ChatUiHelpers.switchVariant(message, -1), isFalse);
      expect(ChatUiHelpers.switchVariant(message, 5), isFalse);
    });

    test('decodeVariants tolerates absent / malformed JSON', () {
      expect(ChatUiHelpers.decodeVariants(null), isEmpty);
      expect(ChatUiHelpers.decodeVariants(''), isEmpty);
      expect(ChatUiHelpers.decodeVariants('not json'), isEmpty);
      expect(ChatUiHelpers.decodeVariants('{"not":"a list"}'), isEmpty);
    });

    test('messageToRawMap round-trips variants + activeVariant', () {
      const variantsJson =
          '[{"text":"one"},{"text":"two"}]';
      final map = ChatUiHelpers.messageToRawMap(
        ChatMessage(
          role: 'assistant',
          text: 'two',
          variants: variantsJson,
          activeVariant: 1,
        ),
      );
      expect(map['variants'], variantsJson);
      expect(map['activeVariant'], '1');

      // And the parser turns that stringified index back into a ChatMessage.
      final restored = ChatMessage.fromJson(<String, dynamic>{
        'role': 'assistant',
        'text': map['text'],
        'variants': map['variants'],
        'activeVariant': map['activeVariant'],
      });
      expect(restored.variants, variantsJson);
      expect(restored.activeVariant, 1);
    });
  });
}
