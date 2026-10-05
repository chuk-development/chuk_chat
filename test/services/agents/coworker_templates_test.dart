import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/strings_de.dart';
import 'package:chuk_chat/l10n/strings_en.dart';
import 'package:chuk_chat/services/agents/coworker_templates.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/ui/expressive/agent_face.dart';

void main() {
  test('the catalogue holds 12 to 15 templates with unique, wire-safe ids', () {
    expect(kCoworkerTemplates.length, inInclusiveRange(12, 15));
    final ids = kCoworkerTemplates.map((t) => t.id).toList();
    expect(ids.toSet(), hasLength(ids.length));
    for (final id in ids) {
      // Same shape the host accepts (`_TEMPLATE_ID` in coworker_templates.py).
      expect(RegExp(r'^[a-z0-9][a-z0-9_-]{0,47}$').hasMatch(id), isTrue);
      expect(coworkerTemplateById(id)?.id, id);
    }
    expect(coworkerTemplateById('nope'), isNull);
  });

  test('every category has templates', () {
    for (final category in CoworkerTemplateCategory.values) {
      expect(
        kCoworkerTemplates.where((t) => t.category == category),
        isNotEmpty,
        reason: '$category',
      );
    }
  });

  test('every string the picker shows exists in English and German', () {
    final keys = <String>[
      for (final t in kCoworkerTemplates) ...[
        t.nameKey,
        t.descriptionKey,
        if (t.starter != null) ...[t.starter!.nameKey, t.starter!.whenKey],
      ],
      for (final tool in CoworkerTemplateTool.values) 'tpl.tool.${tool.name}',
    ];
    for (final key in keys) {
      expect(stringsEn[key], isNotNull, reason: 'en $key');
      expect(stringsDe[key], isNotNull, reason: 'de $key');
      expect(stringsEn[key], isNotEmpty);
      expect(stringsDe[key], isNotEmpty);
    }
  });

  test('personas are short, plain and inside the host limit', () {
    for (final t in kCoworkerTemplates) {
      expect(t.persona.trim(), isNotEmpty, reason: t.id);
      expect(t.persona.length, lessThan(kCoworkerPersonaMaxLength));
      // Short on purpose: a persona is a few lines, not an essay.
      expect(t.persona.length, lessThan(900), reason: t.id);
      expect(t.toWire(), <String, Object?>{'id': t.id, 'persona': t.persona});
    }
  });

  test('faces use the offered palette', () {
    final palette = kAgentAccents.map((c) => c.toARGB32()).toSet();
    for (final t in kCoworkerTemplates) {
      expect(palette, contains(t.accent), reason: t.id);
    }
  });

  test('starter automations are five-field cron schedules with a prompt', () {
    final starters = kCoworkerTemplates
        .where((t) => t.starter != null)
        .map((t) => t.starter!)
        .toList();
    expect(starters, isNotEmpty);
    for (final s in starters) {
      expect(s.cron.split(' '), hasLength(5), reason: s.cron);
      expect(s.prompt.trim(), isNotEmpty);
    }
  });

  group('announceCoworkerToHost', () {
    AgentsAutomation savedRow() => AgentsAutomation.fromPayload(
      <String, dynamic>{
        'id': 'a1',
        'session_key': 'agent-1',
        'kind': 'schedule',
        'name': 'Morning',
        'state': 'active',
        'spec': <String, dynamic>{'cron': '0 8 * * 1-5'},
        'prompt': 'x',
      },
    )!;

    test('no controller: nothing is sent, the starter neither', () async {
      var starters = 0;
      final outcome = await announceCoworkerToHost(
        createAgent: null,
        createStarter: () async {
          starters++;
          return AutomationSaveResult.saved(savedRow());
        },
      );
      expect(outcome.ok, isFalse);
      expect(outcome.notConnected, isTrue);
      expect(outcome.agentFailed, isTrue);
      expect(starters, 0);
    });

    test('a failed agent_create keeps the starter back', () async {
      var starters = 0;
      final outcome = await announceCoworkerToHost(
        createAgent: () async => throw StateError('Not paired'),
        createStarter: () async {
          starters++;
          return AutomationSaveResult.saved(savedRow());
        },
      );
      expect(outcome.agentFailed, isTrue);
      expect(outcome.agentError, contains('Not paired'));
      expect(starters, 0);
    });

    test('agent first, then the starter; a starter failure is reported',
        () async {
      final order = <String>[];
      final outcome = await announceCoworkerToHost(
        createAgent: () async => order.add('agent'),
        createStarter: () async {
          order.add('starter');
          return const AutomationSaveResult.failed('bad cron');
        },
      );
      expect(order, <String>['agent', 'starter']);
      expect(outcome.agentFailed, isFalse);
      expect(outcome.starterError, 'bad cron');
      expect(outcome.ok, isFalse);
    });

    test('everything sent: ok', () async {
      final outcome = await announceCoworkerToHost(
        createAgent: () async {},
        createStarter: () async => AutomationSaveResult.saved(savedRow()),
      );
      expect(outcome.ok, isTrue);
      expect(
        (await announceCoworkerToHost(createAgent: () async {})).ok,
        isTrue,
      );
    });
  });
}
