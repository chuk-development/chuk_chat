import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/models/client_tool.dart';
import 'package:chuk_chat/services/tool_executor.dart';
import 'package:chuk_chat/services/tool_registry.dart' as registry;

/// Registers just the tools a skill test needs.
///
/// `registerBuiltinTools` skips `skill` unless FEATURE_SKILLS is defined, and
/// tests run with the default flags — so register straight from the catalogue.
ToolExecutor _executorWith(List<String> toolNames) {
  final executor = ToolExecutor();
  for (final name in toolNames) {
    executor.registerTool(
      registry.builtinTools.firstWhere((t) => t.name == name),
    );
  }
  return executor;
}

void main() {
  group('skill tool acknowledgement', () {
    test('returns a scrapeable SKILL: marker, not the body', () async {
      // The ack is deliberately short. The body is injected into the next
      // system prompt instead, because tool results get truncated to 4000
      // chars when replayed into a later user turn — a skill returned as a
      // tool result would silently lose most of itself.
      final executor = _executorWith(['skill', 'weather', 'geocode']);

      final result = await executor.execute('skill', {'name': 'weather-cards'});

      expect(result.output, startsWith('SKILL: weather-cards'));
      expect(result.output.length, lessThan(400));
      // The body must NOT be here.
      expect(result.output, isNot(contains('WMO codes')));
    });

    test(
      'states it is a setup step so the model does not stop there',
      () async {
        // The CONTINUATION block tells the model to answer once tool results
        // satisfy the request. After a bare ack that reads as "done".
        final executor = _executorWith(['skill', 'weather', 'geocode']);

        final result = await executor.execute('skill', {
          'name': 'weather-cards',
        });

        expect(result.output, contains('SETUP step, not the answer'));
        expect(result.output, contains('## ACTIVE SKILL: weather-cards'));
      },
    );

    test('lists pre-approved tools from allowed-tools', () async {
      final executor = _executorWith(['skill', 'weather', 'geocode']);

      final result = await executor.execute('skill', {'name': 'weather-cards'});

      expect(result.output, contains('Pre-approved tools'));
      expect(result.output, contains('weather'));
      expect(result.output, contains('geocode'));
    });

    test('never pre-approves a tool that is not available', () async {
      // `allowed-tools` pre-approves tools; it must not conjure one that is
      // absent from the enabled set — whether because the user switched it
      // off or because it was never registered on this platform. Both reach
      // the executor as "not in allTools", which is what this filters on.
      final executor = _executorWith(['skill', 'weather']);

      final result = await executor.execute('skill', {'name': 'weather-cards'});

      expect(result.output, contains('weather'));
      expect(
        result.output,
        isNot(contains('geocode')),
        reason:
            'weather-cards lists geocode in allowed-tools, but it is not '
            'available here — a skill must not grant it anyway',
      );
    });

    test(
      'omits the pre-approved line for a skill with no allowed-tools',
      () async {
        // chart-authoring has none — <chart> is an output tag, not a tool.
        final executor = _executorWith(['skill']);

        final result = await executor.execute('skill', {
          'name': 'chart-authoring',
        });

        expect(result.output, startsWith('SKILL: chart-authoring'));
        expect(result.output, isNot(contains('Pre-approved tools')));
      },
    );
  });

  group('skill tool errors', () {
    test(
      'an unknown skill lists the real ones and emits no SKILL: marker',
      () async {
        // No marker means the activation scraper ignores it — that is how the
        // error path stays inert without the executor flagging it.
        final executor = _executorWith(['skill']);

        final result = await executor.execute('skill', {
          'name': 'does-not-exist',
        });

        expect(result.output, contains('Unknown skill "does-not-exist"'));
        expect(result.output, contains('weather-cards'));
        expect(result.output, isNot(contains('SKILL: does-not-exist')));
      },
    );

    test('a missing name is reported, not silently ignored', () async {
      final executor = _executorWith(['skill']);

      for (final args in [
        <String, dynamic>{},
        {'name': '  '},
      ]) {
        final result = await executor.execute('skill', args);
        expect(result.output, contains('"name" is required'));
        expect(result.output, isNot(startsWith('SKILL:')));
      }
    });

    test(
      'resolves a name the model typed with odd casing or spacing',
      () async {
        final executor = _executorWith(['skill']);

        final result = await executor.execute('skill', {
          'name': ' Chart-Authoring ',
        });

        expect(result.output, startsWith('SKILL: chart-authoring'));
      },
    );
  });

  group('skill tool registration', () {
    test('is registered as an executable built-in', () {
      // registerTool throws StateError when a tool has no executor, so this
      // failing means `skill` is missing from _builtinExecutableToolNames.
      expect(() => _executorWith(['skill']), returnsNormally);
    });

    test('has a tool definition and a category', () {
      expect(
        registry.builtinTools.where((t) => t.name == 'skill'),
        hasLength(1),
      );
      expect(registry.toolCategoryMap['skill'], ToolCategory.basic);
    });

    test('carries no tags — it must never be a find_tools hit', () {
      final skillTool = registry.builtinTools.firstWhere(
        (t) => t.name == 'skill',
      );
      expect(skillTool.tags, isEmpty);
    });
  });
}
