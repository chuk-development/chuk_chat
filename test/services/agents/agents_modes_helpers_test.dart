import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:chuk_chat/models/tool_call.dart';
import 'package:chuk_chat/services/agents/agents_command_prefix.dart';
import 'package:chuk_chat/services/agents/agents_context_rows.dart';
import 'package:chuk_chat/services/agents/agents_derived_threads.dart';
import 'package:chuk_chat/services/agents/agents_permissions_service.dart';
import 'package:chuk_chat/services/agents/agents_relay_client.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_tool_row_info.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';

void main() {
  group('command prefix', () {
    test('program and subcommand, launchers stripped', () {
      expect(commandPrefixFor('git push origin master'), 'git push');
      expect(commandPrefixFor('/usr/bin/npm test'), 'npm test');
      expect(commandPrefixFor('ls -la /tmp'), 'ls');
      expect(commandPrefixFor('git commit -m "a b" && rm x'), 'git commit');
      expect(commandPrefixFor(''), isNull);
    });

    // M6: a prefix on a shell, an interpreter or a wrapper would allow any
    // command; a new line or a command substitution starts a new command.
    test('never for shells, interpreters and wrappers', () {
      for (final String command in <String>[
        'bash -c "rm -rf ~"',
        'sh x.sh',
        'zsh',
        'fish -c ls',
        'python3 script.py',
        'python -c "print(1)"',
        '/usr/bin/python3.12 x.py',
        'node x.js',
        'perl -e 1',
        'ruby x.rb',
        'php x.php',
        'env BAR=2 npm test',
        'FOO=1 npm test',
        'xargs rm',
        'eval "\$X"',
        'exec rm x',
        'find . -exec rm {} ;',
        'sudo -u root apt install x',
        'doas rm x',
      ]) {
        expect(commandPrefixFor(command), isNull, reason: command);
      }
      expect(commandPrefixFor('git status\nrm -rf /'), 'git status');
      expect(commandPrefixFor(r'echo $(rm -rf /)'), 'echo');
      expect(commandPrefixFor('echo `rm -rf /`'), 'echo');
      // Not even when the host suggests it.
      expect(
        approvalCommandPrefix(
          AgentsRelayApprovalRequest.fromPayload(<String, dynamic>{
            'approval_id': 'a1',
            'action': 'action_approval',
            'tool': 'run_command',
            'options': <String>['once', 'always_this_prefix', 'deny'],
            'details': <String, dynamic>{'prefix': 'bash', 'command': 'bash'},
          })!,
        ),
        isNull,
      );
    });

    test('a request offers it only with the scope; host prefix wins', () {
      AgentsRelayApprovalRequest req(Map<String, dynamic> extra) =>
          AgentsRelayApprovalRequest.fromPayload(<String, dynamic>{
            'approval_id': 'a1',
            'action': 'action_approval',
            'tool': 'run_command',
            ...extra,
          })!;
      expect(
        approvalCommandPrefix(
          req(<String, dynamic>{
            'options': <String>['once', 'deny'],
            'details': <String, dynamic>{'command': 'git push'},
          }),
        ),
        isNull,
      );
      expect(
        approvalCommandPrefix(
          req(<String, dynamic>{
            'options': <String>['once', 'always_this_prefix', 'deny'],
            'details': <String, dynamic>{'command': 'git push -f'},
          }),
        ),
        'git push',
      );
      expect(
        approvalCommandPrefix(
          req(<String, dynamic>{
            'options': <String>['once', 'always_this_prefix', 'deny'],
            'details': <String, dynamic>{
              'command': 'git push -f',
              'prefix': <String>['git'],
            },
          }),
        ),
        'git',
      );
    });
  });

  group('tool rows', () {
    test('diff stats from ui.diff and ui.diffs', () {
      expect(
        unifiedDiffStat('--- a\n+++ b\n@@\n-old\n+new\n+more\n ctx'),
        (added: 2, removed: 1),
      );
      expect(
        toolUiDiffStat(<String, dynamic>{
          'diffs': <Map<String, dynamic>>[
            <String, dynamic>{'path': 'a', 'diff': '+x\n-y'},
            <String, dynamic>{'path': 'b', 'diff': '+z'},
          ],
        }),
        (added: 2, removed: 1),
      );
      expect(toolUiDiffStat(null), isNull);
    });

    test('toolCallFromRelay keeps description and +a -r', () {
      final ToolCall call = toolCallFromRelay(
        AgentsRelayTool.fromPayload(<String, dynamic>{
          'type': 'tool',
          'name': 'edit_file',
          'arguments': <String, dynamic>{'path': 'a.dart'},
          'description': 'Fix the parser',
          'ui': <String, dynamic>{'diff': '+a\n+b\n-c'},
          'status': 'completed',
        }),
      );
      expect(toolCallDescription(call), 'Fix the parser');
      expect(toolCallDiffLabel(call), '+2 -1');
    });

    test('a call without ui has no counts', () {
      final ToolCall call = toolCallFromRelay(
        AgentsRelayTool.fromPayload(<String, dynamic>{
          'type': 'tool',
          'name': 'run_command',
          'arguments': <String, dynamic>{
            'command': 'ls',
            'description': 'List the files',
          },
        }),
      );
      expect(toolCallDescription(call), 'List the files');
      expect(toolCallDiffLabel(call), isNull);
    });
  });

  group('context rows', () {
    test('a context frame maps to one chip call; split lifts it off', () {
      final AgentsRelayContext ctx = AgentsRelayContext.fromPayload(
        <String, dynamic>{
          'type': 'context',
          'source': 'plan',
          'text': 'Plan rules',
          'replay': true,
          'mid': 7,
        },
      )!;
      expect(ctx.replay, isTrue);
      expect(ctx.mid, 7);
      final ToolCall chip = contextCallFromRelay(ctx);
      final ToolCall other = ToolCall(name: 'run_command');
      final split = splitAgentsContext(<ToolCall>[chip, other]);
      expect(split.rest, <ToolCall>[other]);
      expect(split.context.single.source, 'plan');
      expect(split.context.single.text, 'Plan rules');
      expect(
        AgentsRelayContext.fromPayload(<String, dynamic>{'text': 'x'}),
        isNull,
      );
    });

    test('a user row with a source keeps it in inputMode', () {
      expect(
        agentsRowSource(<String, String>{'inputMode': 'agents_source:goal'}),
        'goal',
      );
      expect(agentsRowSource(<String, String>{'inputMode': 'voice'}), isNull);
      expect(agentsRowSource(<String, String>{}), isNull);
    });
  });

  group('derived threads', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      AgentsDerivedThreads.instance.reset();
    });

    test('a fire in a chat of its own adds that thread', () async {
      final AgentsDerivedThreads store = AgentsDerivedThreads();
      store.ingestAutomation(<String, dynamic>{
        'type': 'automation',
        'event': 'fired',
        'id': 'ab12',
        'session_key': 'agent-1',
        'name': 'Morning brief',
        'target': 'new',
        'run_session_key': 'agent-1#auto-ab12-3',
      });
      store.ingestAutomation(<String, dynamic>{
        'type': 'automation',
        'event': 'fired',
        'id': 'cd34',
        'session_key': 'agent-1',
        'name': 'Digest',
        'run_session_key': 'agent-1#auto-cd34',
      });
      // A fire in the owner's own chat adds nothing.
      store.ingestAutomation(<String, dynamic>{
        'type': 'automation',
        'event': 'fired',
        'id': 'ef56',
        'session_key': 'agent-1',
      });
      final list = store.forOwner('agent-1');
      expect(list.map((t) => t.title).toSet(), <String>{
        'Morning brief · 3',
        'Digest',
      });
      expect(AgentsDerivedThreads.ownerOf('agent-1#auto-cd34'), 'agent-1');
      expect(AgentsDerivedThreads.ownerOf('agent-1'), isNull);
      // Stored: a fresh store reads it back.
      await Future<void>.delayed(Duration.zero);
      final AgentsDerivedThreads again = AgentsDerivedThreads();
      await again.load();
      expect(again.forOwner('agent-1'), hasLength(2));
    });
  });

  group('permission presets', () {
    test('presetOf matches, Custom is null', () {
      expect(presetOf(AgentPermissions.defaults), AgentPermissionPreset.full);
      expect(
        presetOf(
          const AgentPermissions(
            sudo: false,
            network: false,
            secretsEnv: false,
            workspaceMount: AgentWorkspaceMount.ro,
          ),
        ),
        AgentPermissionPreset.locked,
      );
      expect(
        presetOf(const AgentPermissions(sudo: false, secretsEnv: false)),
        AgentPermissionPreset.careful,
      );
      expect(presetOf(const AgentPermissions(network: false)), isNull);
    });

    test('external_agents reads off by default and round-trips', () {
      final AgentPermissions p = AgentPermissions.fromJson(
        <String, dynamic>{'external_agents': true},
      );
      expect(AgentPermissions.defaults.externalAgents, isFalse);
      expect(p.isOn(AgentPermissions.keyExternalAgents), isTrue);
      expect(p.toJson()['external_agents'], isTrue);
    });

    test('setSwitches sends only what changes, in one frame', () async {
      final List<Map<String, dynamic>> sent = <Map<String, dynamic>>[];
      final service = AgentsPermissionsService(
        send: (Map<String, dynamic> f) async => sent.add(f),
        capabilities: _Caps(<String>{kAgentPermissionsCapability}),
      );
      final bool ok = await service.setSwitches(
        'a1',
        kAgentPermissionPresets[AgentPermissionPreset.locked]!,
      );
      expect(ok, isTrue);
      expect(sent.single['permissions'], <String, dynamic>{
        'sudo': false,
        'network': false,
        'secrets_env': false,
        'workspace_mount': 'ro',
      });
      expect(presetOf(service.permissionsOf('a1')), AgentPermissionPreset.locked);
    });
  });

  group('automation guards', () {
    test('parseCatchUp', () {
      expect(parseCatchUp(''), isNull);
      expect(parseCatchUp('0'), 0);
      expect(parseCatchUp('30'), 1800);
      expect(parseCatchUp('6h'), '6h');
      expect(() => parseCatchUp('soon'), throwsFormatException);
      expect(catchUpText(1800), '30');
      expect(catchUpText(null), '');
    });

    test('create frame carries target, chaining and catch-up', () {
      final Map<String, dynamic> f = automationCreateFrame(
        sessionKey: 's',
        kind: 'schedule',
        spec: 'every 1h',
        prompt: 'go',
        target: kAutomationTargetNewOnce,
        allowChaining: true,
        catchUp: 600,
      );
      expect(f['target'], 'new_once');
      expect(f['allow_chaining'], isTrue);
      expect(f['catch_up'], 600);
      final Map<String, dynamic> plain = automationCreateFrame(
        sessionKey: 's',
        kind: 'schedule',
        spec: 'every 1h',
        prompt: 'go',
      );
      expect(plain.containsKey('target'), isFalse);
      expect(plain.containsKey('allow_chaining'), isFalse);
      expect(plain.containsKey('catch_up'), isFalse);
    });

    test('a row reads the new fields; update sends only changes', () {
      final AgentsAutomation a = AgentsAutomation.fromPayload(
        <String, dynamic>{
          'id': 'x',
          'session_key': 's',
          'kind': 'schedule',
          'spec': <String, dynamic>{'every': 3600},
          'prompt': 'go',
          'target': 'new',
          'allow_chaining': true,
          'catch_up_seconds': 600,
          'skipped_count': 2,
        },
      )!;
      expect(a.target, 'new');
      expect(a.allowChaining, isTrue);
      expect(a.catchUpSeconds, 600);
      expect(a.skippedCount, 2);
      final Map<String, dynamic>? none = automationUpdateFrame(
        before: a,
        spec: 'every 1h',
        prompt: 'go',
        name: a.name,
        notifyOnChange: false,
        target: 'new',
        allowChaining: true,
        catchUp: 600,
        catchUpSet: true,
      );
      expect(none, isNull);
      final Map<String, dynamic>? some = automationUpdateFrame(
        before: a,
        spec: 'every 1h',
        prompt: 'go',
        name: a.name,
        notifyOnChange: false,
        target: 'this_session',
        allowChaining: false,
        catchUp: null,
        catchUpSet: true,
      );
      expect(some!['target'], 'this_session');
      expect(some['allow_chaining'], isFalse);
      expect(some.containsKey('catch_up'), isTrue);
      expect(some['catch_up'], isNull);
    });
  });
}

class _Caps extends ValueNotifier<Set<String>> {
  _Caps(super.value);
}
