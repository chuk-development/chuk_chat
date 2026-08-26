// Tests for CustomModelInfo.fromJson capability parsing, focused on the
// supports_reasoning_effort field added for the reasoning-level dropdown.

import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/pages/model_selector/models/model_info.dart';

Map<String, dynamic> _baseJson({Map<String, dynamic>? extra}) {
  return <String, dynamic>{
    'id': 'vendor/model',
    'name': 'Model',
    'providers': <dynamic>[],
    ...?extra,
  };
}

void main() {
  group('CustomModelInfo.fromJson', () {
    test('parses supports_reasoning_effort when present and true', () {
      final info = CustomModelInfo.fromJson(
        _baseJson(extra: {'supports_reasoning_effort': true}),
      );
      expect(info.supportsReasoningEffort, isTrue);
    });

    test('parses supports_reasoning_effort when present and false', () {
      final info = CustomModelInfo.fromJson(
        _baseJson(extra: {'supports_reasoning_effort': false}),
      );
      expect(info.supportsReasoningEffort, isFalse);
    });

    test('defaults supports_reasoning_effort to true when absent', () {
      final info = CustomModelInfo.fromJson(_baseJson());
      expect(info.supportsReasoningEffort, isTrue);
    });

    test('keeps the existing capability defaults', () {
      final info = CustomModelInfo.fromJson(_baseJson());
      // Vision defaults false; reasoning defaults true (non-regressive).
      expect(info.supportsVision, isFalse);
      expect(info.supportsReasoning, isTrue);
    });
  });
}
