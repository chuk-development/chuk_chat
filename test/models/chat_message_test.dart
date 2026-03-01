import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/models/chat_message.dart';

void main() {
  group('ChatMessage constructor', () {
    test('required fields only', () {
      final msg = ChatMessage(role: 'user', text: 'Hello');
      expect(msg.role, equals('user'));
      expect(msg.text, equals('Hello'));
      expect(msg.reasoning, isNull);
      expect(msg.images, isNull);
      expect(msg.attachments, isNull);
      expect(msg.attachedFilesJson, isNull);
      expect(msg.modelId, isNull);
      expect(msg.provider, isNull);
    });

    test('all fields', () {
      final msg = ChatMessage(
        role: 'assistant',
        text: 'Reply',
        reasoning: 'thinking...',
        images: 'path/to/image.enc',
        attachments: 'file.pdf',
        attachedFilesJson: '[]',
        toolCalls: '[{"name":"web_search","status":"completed"}]',
        modelId: 'gpt-4',
        provider: 'openai',
      );
      expect(msg.reasoning, equals('thinking...'));
      expect(msg.images, equals('path/to/image.enc'));
      expect(msg.attachments, equals('file.pdf'));
      expect(msg.attachedFilesJson, equals('[]'));
      expect(
        msg.toolCalls,
        equals('[{"name":"web_search","status":"completed"}]'),
      );
      expect(msg.modelId, equals('gpt-4'));
      expect(msg.provider, equals('openai'));
    });
  });

  group('sender alias', () {
    test('assistant role returns ai', () {
      final msg = ChatMessage(role: 'assistant', text: '');
      expect(msg.sender, equals('ai'));
    });

    test('user role returns user', () {
      final msg = ChatMessage(role: 'user', text: '');
      expect(msg.sender, equals('user'));
    });

    test('system role returns system', () {
      final msg = ChatMessage(role: 'system', text: '');
      expect(msg.sender, equals('system'));
    });
  });

  group('fromJson', () {
    test('basic fields', () {
      final msg = ChatMessage.fromJson({'role': 'user', 'text': 'Hello world'});
      expect(msg.role, equals('user'));
      expect(msg.text, equals('Hello world'));
    });

    test('backwards compat: sender field maps to role', () {
      final msg = ChatMessage.fromJson({
        'sender': 'assistant',
        'text': 'Reply',
      });
      expect(msg.role, equals('assistant'));
    });

    test('role takes precedence over sender', () {
      final msg = ChatMessage.fromJson({
        'role': 'user',
        'sender': 'assistant',
        'text': 'test',
      });
      expect(msg.role, equals('user'));
    });

    test('missing role and sender defaults to user', () {
      final msg = ChatMessage.fromJson({'text': 'orphan message'});
      expect(msg.role, equals('user'));
    });

    test('missing text defaults to empty string', () {
      final msg = ChatMessage.fromJson({'role': 'user'});
      expect(msg.text, equals(''));
    });

    test('all optional fields', () {
      final msg = ChatMessage.fromJson({
        'role': 'assistant',
        'text': 'Reply',
        'reasoning': 'Let me think...',
        'images': 'user123/img.enc',
        'attachments': 'doc.pdf',
        'attachedFilesJson': '[{"id":"1"}]',
        'toolCalls': '[{"name":"web_crawl","status":"completed"}]',
        'modelId': 'claude-3',
        'provider': 'anthropic',
      });
      expect(msg.reasoning, equals('Let me think...'));
      expect(msg.images, equals('user123/img.enc'));
      expect(msg.attachments, equals('doc.pdf'));
      expect(msg.attachedFilesJson, equals('[{"id":"1"}]'));
      expect(
        msg.toolCalls,
        equals('[{"name":"web_crawl","status":"completed"}]'),
      );
      expect(msg.modelId, equals('claude-3'));
      expect(msg.provider, equals('anthropic'));
    });

    test('null optional fields', () {
      final msg = ChatMessage.fromJson({
        'role': 'user',
        'text': 'Hi',
        'reasoning': null,
        'images': null,
      });
      expect(msg.reasoning, isNull);
      expect(msg.images, isNull);
    });
  });

  group('toJson', () {
    test('required fields only', () {
      final msg = ChatMessage(role: 'user', text: 'Hello');
      final json = msg.toJson();
      expect(json['role'], equals('user'));
      expect(json['text'], equals('Hello'));
      expect(json.containsKey('reasoning'), isFalse);
      expect(json.containsKey('images'), isFalse);
      expect(json.containsKey('modelId'), isFalse);
    });

    test('includes non-empty optional fields', () {
      final msg = ChatMessage(
        role: 'assistant',
        text: 'Reply',
        reasoning: 'thought',
        toolCalls: '[{"name":"calculate","status":"completed"}]',
        modelId: 'gpt-4',
        provider: 'openai',
      );
      final json = msg.toJson();
      expect(json['reasoning'], equals('thought'));
      expect(
        json['toolCalls'],
        equals('[{"name":"calculate","status":"completed"}]'),
      );
      expect(json['modelId'], equals('gpt-4'));
      expect(json['provider'], equals('openai'));
    });

    test('excludes empty string optional fields', () {
      final msg = ChatMessage(
        role: 'user',
        text: 'Hi',
        reasoning: '',
        images: '',
        modelId: '',
      );
      final json = msg.toJson();
      expect(json.containsKey('reasoning'), isFalse);
      expect(json.containsKey('images'), isFalse);
      expect(json.containsKey('modelId'), isFalse);
    });
  });

  group('fromJson/toJson roundtrip', () {
    test('full roundtrip preserves data', () {
      final original = ChatMessage(
        role: 'assistant',
        text: 'Hello! How can I help?',
        reasoning: 'User wants help',
        images: 'path/image.enc',
        attachments: 'doc.pdf',
        attachedFilesJson: '[{"id":"file1"}]',
        toolCalls: '[{"name":"web_search","result":"ok","status":"completed"}]',
        modelId: 'claude-3-opus',
        provider: 'anthropic',
      );

      final json = original.toJson();
      final restored = ChatMessage.fromJson(json);

      expect(restored.role, equals(original.role));
      expect(restored.text, equals(original.text));
      expect(restored.reasoning, equals(original.reasoning));
      expect(restored.images, equals(original.images));
      expect(restored.attachments, equals(original.attachments));
      expect(restored.attachedFilesJson, equals(original.attachedFilesJson));
      expect(restored.toolCalls, equals(original.toolCalls));
      expect(restored.modelId, equals(original.modelId));
      expect(restored.provider, equals(original.provider));
    });

    test('minimal roundtrip', () {
      final original = ChatMessage(role: 'user', text: 'Hello');
      final restored = ChatMessage.fromJson(original.toJson());
      expect(restored.role, equals('user'));
      expect(restored.text, equals('Hello'));
    });
  });
}
