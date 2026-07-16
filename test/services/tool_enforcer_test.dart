import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/services/tool_enforcer.dart';

Map<String, dynamic> _def(String name) => {
  'name': name,
  'description': '$name tool',
  'parameters': <String, dynamic>{},
};

Map<String, dynamic> _call(String name, [Map<String, dynamic>? args]) => {
  'name': name,
  'arguments': args ?? <String, dynamic>{},
};

void main() {
  group('ToolEnforcer always-allowed set', () {
    // The base set used to be spelled out three times: the field initializer,
    // the alwaysAllowedTools setter, and reset(). Every copy had to be kept in
    // sync by hand, and the setter is only invoked conditionally (createSession
    // calls it only when a workspace or artifacts add a bypass), so a missed
    // copy would misbehave in some sessions and not others. These tests lock
    // the invariant that all three paths agree.

    test('an always-allowed tool is not marked as discovered', () {
      final enforcer = ToolEnforcer()
        ..discoveryMode = true
        ..setDeclaredTools([_def('skill'), _def('weather')]);

      enforcer.enforce([
        _call('skill', {'name': 'weather-cards'}),
      ]);

      expect(
        enforcer.discoveredToolNames,
        isNot(contains('skill')),
        reason:
            'skill bypasses discovery — it must not enter the '
            'discovered set, or its definition gets rendered twice',
      );
    });

    test('a discovery-gated tool IS marked as discovered (control)', () {
      // `calculate` is not in the base set — unlike `weather`, which is, and
      // would make this control pass for the wrong reason.
      final enforcer = ToolEnforcer()
        ..discoveryMode = true
        ..setDeclaredTools([_def('skill'), _def('calculate')]);

      enforcer.enforce([_call('calculate')]);

      expect(enforcer.discoveredToolNames, contains('calculate'));
    });

    test('the setter extends the base set instead of replacing it', () {
      final enforcer = ToolEnforcer()
        ..discoveryMode = true
        ..setDeclaredTools([_def('skill'), _def('update_project')])
        ..alwaysAllowedTools = {'update_project'};

      enforcer.enforce([
        _call('skill', {'name': 'weather-cards'}),
        _call('update_project'),
      ]);

      expect(
        enforcer.discoveredToolNames,
        isNot(contains('skill')),
        reason: 'setting a bypass set must not drop the built-in base set',
      );
      expect(enforcer.discoveredToolNames, isNot(contains('update_project')));
    });

    test('reset() restores the base set', () {
      final enforcer = ToolEnforcer()
        ..discoveryMode = true
        ..setDeclaredTools([_def('skill')])
        ..alwaysAllowedTools = {'update_project'};

      enforcer.reset();

      enforcer
        ..discoveryMode = true
        ..setDeclaredTools([_def('skill')])
        ..enforce([
          _call('skill', {'name': 'weather-cards'}),
        ]);

      expect(
        enforcer.discoveredToolNames,
        isNot(contains('skill')),
        reason: 'reset() must restore the base set, not a partial copy',
      );
    });
  });

  group('ToolEnforcer declared-set gate', () {
    test('rejects a tool that was never declared', () {
      final enforcer = ToolEnforcer()..setDeclaredTools([_def('weather')]);

      final result = enforcer.enforce([_call('definitely_not_a_tool')]);

      expect(result.hasRejections, isTrue);
      expect(result.validCalls, isEmpty);
      expect(
        result.rejectedCalls.single.reason,
        contains('not in declared tool set'),
      );
    });

    test('accepts a declared tool and assigns a call id', () {
      final enforcer = ToolEnforcer()..setDeclaredTools([_def('skill')]);

      final result = enforcer.enforce([
        _call('skill', {'name': 'weather-cards'}),
      ]);

      expect(result.hasRejections, isFalse);
      expect(result.validCalls, hasLength(1));
      expect(result.validCalls.single.name, 'skill');
      expect(result.validCalls.single.callId, 'functions.skill:0');
    });

    test('stops the loop at maxIterations', () {
      final enforcer = ToolEnforcer(maxIterations: 2)
        ..setDeclaredTools([_def('weather')]);

      enforcer.enforce([_call('weather')]);
      enforcer.enforce([_call('weather')]);
      final third = enforcer.enforce([_call('weather')]);

      expect(third.iterationLimitReached, isTrue);
      expect(third.validCalls, isEmpty);
    });
  });
}
