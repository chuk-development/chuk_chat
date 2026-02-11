import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/message_composition_service.dart';

void main() {
  group('MessageCompositionResult', () {
    test('error factory', () {
      final result = MessageCompositionResult.error('Something failed');
      expect(result.isValid, isFalse);
      expect(result.errorMessage, equals('Something failed'));
      expect(result.displayMessageText, isNull);
      expect(result.aiPromptContent, isNull);
      expect(result.accessToken, isNull);
      expect(result.providerSlug, isNull);
      expect(result.maxResponseTokens, isNull);
      expect(result.effectiveSystemPrompt, isNull);
      expect(result.images, isNull);
    });

    test('success factory', () {
      final result = MessageCompositionResult.success(
        displayMessageText: 'Hello',
        aiPromptContent: 'Hello',
        accessToken: 'token-123',
        providerSlug: 'openai',
        maxResponseTokens: 4096,
        effectiveSystemPrompt: 'You are helpful',
        images: ['user/img.enc'],
      );
      expect(result.isValid, isTrue);
      expect(result.errorMessage, isNull);
      expect(result.displayMessageText, equals('Hello'));
      expect(result.aiPromptContent, equals('Hello'));
      expect(result.accessToken, equals('token-123'));
      expect(result.providerSlug, equals('openai'));
      expect(result.maxResponseTokens, equals(4096));
      expect(result.effectiveSystemPrompt, equals('You are helpful'));
      expect(result.images, hasLength(1));
    });

    test('success without optional fields', () {
      final result = MessageCompositionResult.success(
        displayMessageText: 'Hi',
        aiPromptContent: 'Hi',
        accessToken: 'token',
        providerSlug: 'anthropic',
        maxResponseTokens: 512,
      );
      expect(result.isValid, isTrue);
      expect(result.effectiveSystemPrompt, isNull);
      expect(result.images, isNull);
    });

    test('error with empty message', () {
      final result = MessageCompositionResult.error('');
      expect(result.isValid, isFalse);
      expect(result.errorMessage, equals(''));
    });

    test('const constructor', () {
      const result = MessageCompositionResult(
        isValid: false,
        errorMessage: 'const error',
      );
      expect(result.isValid, isFalse);
      expect(result.errorMessage, equals('const error'));
    });
  });
}
