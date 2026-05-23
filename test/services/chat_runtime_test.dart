import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/chat_runtime.dart';
import 'package:chuk_chat/services/chat_runtime_registry.dart';

void main() {
  group('ChatRuntime', () {
    test('isIdle reflects flags', () {
      final r = ChatRuntime(chatId: 'c1');
      expect(r.isIdle, isTrue);
      r.isSending.value = true;
      expect(r.isIdle, isFalse);
      r.isSending.value = false;
      r.isStreaming.value = true;
      expect(r.isIdle, isFalse);
      r.isStreaming.value = false;
      expect(r.isIdle, isTrue);
      r.dispose();
    });

    test('appendMessage returns new index and notifies listeners', () {
      final r = ChatRuntime(chatId: 'c1');
      var fires = 0;
      r.messages.addListener(() => fires++);
      final i = r.appendMessage({'sender': 'user', 'text': 'hi'});
      expect(i, 0);
      expect(r.messages.value.length, 1);
      expect(fires, 1);
      r.dispose();
    });

    test('updateMessage merges fields without dropping others', () {
      final r = ChatRuntime(chatId: 'c1');
      r.appendMessage({'sender': 'user', 'text': 'hi', 'reasoning': ''});
      r.updateMessage(0, {'text': 'updated'});
      expect(r.messages.value[0]['text'], 'updated');
      expect(r.messages.value[0]['sender'], 'user');
      r.dispose();
    });

    test('updateMessage out-of-range is a no-op', () {
      final r = ChatRuntime(chatId: 'c1');
      r.updateMessage(5, {'text': 'x'});
      expect(r.messages.value, isEmpty);
      r.dispose();
    });

    test('beginStream / endStream flips flags', () {
      final r = ChatRuntime(chatId: 'c1');
      r.appendMessage({'sender': 'user', 'text': 'hi'});
      r.appendMessage({'sender': 'ai', 'text': 'Thinking...'});
      r.beginStream(placeholderIndex: 1, modelId: 'gpt');
      expect(r.isSending.value, isTrue);
      expect(r.isStreaming.value, isTrue);
      expect(r.placeholderIndex, 1);
      expect(r.modelId, 'gpt');
      r.endStream();
      expect(r.isSending.value, isFalse);
      expect(r.isStreaming.value, isFalse);
      expect(r.placeholderIndex, isNull);
      r.dispose();
    });
  });

  group('ChatRuntimeRegistry', () {
    test('get lazily creates and reuses', () {
      final reg = ChatRuntimeRegistry.test();
      final a1 = reg.get('a');
      final a2 = reg.get('a');
      expect(identical(a1, a2), isTrue);
      reg.clear();
    });

    test('runtimes are isolated', () {
      final reg = ChatRuntimeRegistry.test();
      final a = reg.get('a');
      final b = reg.get('b');
      a.appendMessage({'sender': 'user', 'text': 'A'});
      b.appendMessage({'sender': 'user', 'text': 'B'});
      expect(a.messages.value.single['text'], 'A');
      expect(b.messages.value.single['text'], 'B');
      reg.clear();
    });

    test('isAnyStreaming + streamingChatIds reflect live state', () {
      final reg = ChatRuntimeRegistry.test();
      final a = reg.get('a');
      reg.get('b');
      expect(reg.isAnyStreaming, isFalse);
      a.beginStream(placeholderIndex: 0, modelId: 'm');
      expect(reg.isAnyStreaming, isTrue);
      expect(reg.streamingChatIds.toList(), ['a']);
      a.endStream();
      expect(reg.isAnyStreaming, isFalse);
      reg.clear();
    });

    test('release is a no-op while streaming', () {
      final reg = ChatRuntimeRegistry.test();
      final a = reg.get('a');
      a.beginStream(placeholderIndex: 0, modelId: 'm');
      expect(reg.release('a'), isFalse);
      expect(reg.lookup('a'), isNotNull);
      a.endStream();
      expect(reg.release('a'), isTrue);
      expect(reg.lookup('a'), isNull);
      reg.clear();
    });

    test('LRU evicts idle runtimes beyond cap', () async {
      final reg = ChatRuntimeRegistry.test();
      // Fill above cap. One streaming runtime must survive.
      final keep = reg.get('streaming');
      keep.beginStream(placeholderIndex: 0, modelId: 'm');

      for (var i = 0; i < ChatRuntimeRegistry.maxIdleRuntimes + 3; i++) {
        reg.get('idle-$i');
        // Slight time gap to make LRU ordering deterministic.
        await Future<void>.delayed(const Duration(milliseconds: 1));
      }

      // Streaming runtime is preserved.
      expect(reg.lookup('streaming'), isNotNull);
      // Oldest idle runtimes were evicted.
      expect(reg.lookup('idle-0'), isNull);
      // Most-recent idle runtimes survive.
      final last =
          'idle-${ChatRuntimeRegistry.maxIdleRuntimes + 2}';
      expect(reg.lookup(last), isNotNull);

      keep.endStream();
      reg.clear();
    });
  });
}
