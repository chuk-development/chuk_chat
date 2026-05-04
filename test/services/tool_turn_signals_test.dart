import 'package:flutter_test/flutter_test.dart';
import 'package:chuk_chat/services/tool_call_handler.dart';

void main() {
  group('ToolTurnSignals', () {
    test('detects OpenAI-style finish_reason tool calls', () {
      final signals = ToolTurnSignals.fromMeta({'finish_reason': 'tool_calls'});

      expect(signals.indicatesToolUse, isTrue);
      expect(signals.indicatesFinalStop, isFalse);
      expect(signals.indicatesTruncated, isFalse);
    });

    test('detects Anthropic-style stop_reason tool_use', () {
      final signals = ToolTurnSignals.fromMeta({'stop_reason': 'tool_use'});

      expect(signals.indicatesToolUse, isTrue);
      expect(signals.indicatesFinalStop, isFalse);
      expect(signals.indicatesTruncated, isFalse);
    });

    test('detects natural final stop', () {
      final signals = ToolTurnSignals.fromMeta({'stop_reason': 'end_turn'});

      expect(signals.indicatesFinalStop, isTrue);
      expect(signals.indicatesToolUse, isFalse);
      expect(signals.indicatesTruncated, isFalse);
    });

    test('detects truncated response', () {
      final signals = ToolTurnSignals.fromMeta({'finish_reason': 'length'});

      expect(signals.indicatesTruncated, isTrue);
      expect(signals.indicatesToolUse, isFalse);
      expect(signals.indicatesFinalStop, isFalse);
    });

    test('reads nested reason fields', () {
      final signals = ToolTurnSignals.fromMeta({
        'provider': {'finish_reason': 'max_tokens'},
      });

      expect(signals.indicatesTruncated, isTrue);
    });
  });
}
