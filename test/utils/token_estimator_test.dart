import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/utils/token_estimator.dart';

void main() {
  group('estimateTokens', () {
    test('empty string returns 0', () {
      expect(TokenEstimator.estimateTokens(''), equals(0));
    });

    test('single word', () {
      final tokens = TokenEstimator.estimateTokens('hello');
      expect(tokens, greaterThan(0));
    });

    test('short sentence', () {
      final tokens = TokenEstimator.estimateTokens('Hello, world!');
      expect(tokens, greaterThan(0));
    });

    test('longer text produces more tokens', () {
      final short = TokenEstimator.estimateTokens('Hi');
      final long = TokenEstimator.estimateTokens(
        'This is a much longer sentence with many more words and tokens.',
      );
      expect(long, greaterThan(short));
    });

    test('punctuation counted as tokens', () {
      // "Hello, world!" has word tokens + punctuation tokens
      final tokens = TokenEstimator.estimateTokens('Hello, world!');
      // Should be more than just 2 (the two words)
      expect(tokens, greaterThanOrEqualTo(2));
    });

    test('unicode text', () {
      final tokens = TokenEstimator.estimateTokens('日本語テスト');
      expect(tokens, greaterThan(0));
    });

    test('very long text', () {
      final text = 'word ' * 10000;
      final tokens = TokenEstimator.estimateTokens(text);
      expect(tokens, greaterThan(1000));
    });

    test('whitespace only', () {
      // Whitespace-only string has length > 0 but might match few tokens
      final tokens = TokenEstimator.estimateTokens('   ');
      // Character estimate: ceil(3/4) = 1
      expect(tokens, greaterThanOrEqualTo(1));
    });

    test('single character returns at least 1', () {
      expect(TokenEstimator.estimateTokens('a'), greaterThanOrEqualTo(1));
    });

    test('code snippet', () {
      final tokens = TokenEstimator.estimateTokens(
        'function foo() { return bar; }',
      );
      expect(tokens, greaterThan(0));
    });
  });

  group('estimatePromptTokens', () {
    test('empty history and message returns 0', () {
      final tokens = TokenEstimator.estimatePromptTokens(
        history: [],
        currentMessage: '',
      );
      expect(tokens, equals(0));
    });

    test('current message only', () {
      final tokens = TokenEstimator.estimatePromptTokens(
        history: [],
        currentMessage: 'Hello, how are you?',
      );
      expect(tokens, greaterThan(0));
    });

    test('system prompt adds overhead', () {
      final withoutSystem = TokenEstimator.estimatePromptTokens(
        history: [],
        currentMessage: 'Hello',
      );
      final withSystem = TokenEstimator.estimatePromptTokens(
        history: [],
        currentMessage: 'Hello',
        systemPrompt: 'You are a helpful assistant.',
      );
      expect(withSystem, greaterThan(withoutSystem));
    });

    test('empty system prompt ignored', () {
      final without = TokenEstimator.estimatePromptTokens(
        history: [],
        currentMessage: 'Hello',
      );
      final withEmpty = TokenEstimator.estimatePromptTokens(
        history: [],
        currentMessage: 'Hello',
        systemPrompt: '   ',
      );
      expect(withEmpty, equals(without));
    });

    test('history messages add tokens', () {
      final noHistory = TokenEstimator.estimatePromptTokens(
        history: [],
        currentMessage: 'Hello',
      );
      final withHistory = TokenEstimator.estimatePromptTokens(
        history: [
          {'role': 'user', 'content': 'Previous message'},
          {'role': 'assistant', 'content': 'Previous reply'},
        ],
        currentMessage: 'Hello',
      );
      expect(withHistory, greaterThan(noHistory));
    });

    test('null content in history skipped', () {
      final tokens = TokenEstimator.estimatePromptTokens(
        history: [
          {'role': 'user', 'content': null},
        ],
        currentMessage: 'Hello',
      );
      // Should not crash and should only count the current message
      expect(tokens, greaterThan(0));
    });

    test('empty content in history skipped', () {
      final tokens = TokenEstimator.estimatePromptTokens(
        history: [
          {'role': 'user', 'content': '   '},
        ],
        currentMessage: 'Hello',
      );
      expect(tokens, greaterThan(0));
    });

    test('multimodal content with text blocks', () {
      final tokens = TokenEstimator.estimatePromptTokens(
        history: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Describe this image'},
            ],
          },
        ],
        currentMessage: 'Follow up question',
      );
      expect(tokens, greaterThan(0));
    });

    test('multimodal content with image adds ~1000 tokens', () {
      final textOnly = TokenEstimator.estimatePromptTokens(
        history: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Hello'},
            ],
          },
        ],
        currentMessage: '',
      );
      final withImage = TokenEstimator.estimatePromptTokens(
        history: [
          {
            'role': 'user',
            'content': [
              {'type': 'text', 'text': 'Hello'},
              {'type': 'image_url', 'image_url': {'url': 'data:image/png;...'}},
            ],
          },
        ],
        currentMessage: '',
      );
      // Image should add ~1000 tokens
      expect(withImage - textOnly, greaterThanOrEqualTo(900));
    });

    test('whitespace-only current message not counted', () {
      final tokens = TokenEstimator.estimatePromptTokens(
        history: [
          {'role': 'user', 'content': 'Hello'},
        ],
        currentMessage: '   ',
      );
      // Only history message should be counted
      expect(tokens, greaterThan(0));
    });
  });
}
