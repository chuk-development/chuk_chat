import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/assistant/assistant_config.dart';
import 'package:chuk_chat/assistant/assistant_tools.dart';

void main() {
  group('assistant tool schemas', () {
    test('every tool name is unique', () {
      final names = assistantTools.map((tool) => tool.name).toList();
      expect(names.toSet().length, names.length);
    });

    test('every schema is a well-formed OpenAI function definition', () {
      for (final schema in assistantToolSchemas) {
        expect(schema['type'], 'function');
        final function = schema['function'] as Map<String, dynamic>;
        expect(function['name'], isA<String>());
        expect((function['name'] as String).isNotEmpty, isTrue);
        expect(
          (function['description'] as String).isNotEmpty,
          isTrue,
          reason: '${function['name']} needs a description the model can use',
        );

        final parameters = function['parameters'] as Map<String, dynamic>;
        expect(parameters['type'], 'object');
        final properties = parameters['properties'] as Map<String, dynamic>;
        final required = (parameters['required'] as List).cast<String>();
        for (final key in required) {
          expect(
            properties.containsKey(key),
            isTrue,
            reason: '${function['name']} requires "$key" but never declares it',
          );
        }
      }
    });

    test('no optional parameter is silently dropped from the schema', () {
      // `_string(..., values: null)` must not leave a dangling `enum: null`,
      // which some providers reject outright.
      for (final schema in assistantToolSchemas) {
        final function = schema['function'] as Map<String, dynamic>;
        final parameters = function['parameters'] as Map<String, dynamic>;
        final properties = parameters['properties'] as Map<String, dynamic>;
        for (final entry in properties.entries) {
          final property = entry.value as Map<String, dynamic>;
          expect(
            property.values.any((value) => value == null),
            isFalse,
            reason: '${function['name']}.${entry.key} has a null schema field',
          );
        }
      }
    });

    test('lookup by name covers the whole set', () {
      expect(assistantToolsByName.length, assistantTools.length);
      for (final tool in assistantTools) {
        expect(assistantToolsByName[tool.name], same(tool));
      }
    });

    test('labels never throw on empty or garbage arguments', () {
      for (final tool in assistantTools) {
        expect(() => tool.label(const <String, dynamic>{}), returnsNormally);
        expect(
          () => tool.label(<String, dynamic>{
            'query': 42,
            'seconds': 'zwölf',
            'hour': null,
          }),
          returnsNormally,
          reason: '${tool.name} must survive a model sending the wrong types',
        );
      }
    });

    test('the surface the assistant needs is present', () {
      final names = assistantToolsByName.keys.toSet();
      expect(
        names,
        containsAll(<String>[
          'read_screen',
          'look_at_screen',
          'open_maps',
          'get_location',
          'web_search',
          'search_places',
          'search_restaurants',
          'set_timer',
          'call_contact',
        ]),
      );
    });

    test('chat-only tooling stays out of the assistant surface', () {
      // Artifacts and the rest belong to the chat registry. Every
      // schema here is paid for in every spoken turn.
      final names = assistantToolsByName.keys.toSet();
      expect(
        names.intersection(<String>{
          'create_artifact',
          'artifact_manager',
          'bash',
          'find_tools',
        }),
        isEmpty,
      );
    });
  });

  group('assistant model pin', () {
    test('reasoning is never disabled on the pinned model', () {
      // GLM 5.3 is thinking-only. Both routes answer HTTP 400 to a disable
      // directive: OpenRouter with "Reasoning is mandatory for this endpoint
      // and cannot be disabled", Fireworks with "GLM-5.3 is a thinking-only
      // model". The API server drops a "none" for it, so sending one lands on
      // the provider default (max) — slower, not faster.
      expect(kAssistantModelId, 'z-ai/glm-5.3-flash');
      expect(kAssistantReasoningEffort, isNot('none'));
      expect(kAssistantReasoningEffort, 'low');
    });

    test('the tool loop is bounded', () {
      expect(kAssistantMaxToolRounds, greaterThan(1));
      expect(kAssistantMaxToolRounds, lessThanOrEqualTo(8));
    });
  });

  group('AssistantSettings', () {
    test('defaults to the German recognizer hint', () {
      expect(const AssistantSettings().language, 'de');
    });

    test('copyWith keeps the fields it is not given', () {
      const settings = AssistantSettings(language: 'en');
      expect(settings.copyWith().language, 'en');
      expect(settings.copyWith(language: 'de').language, 'de');
    });
  });
}
