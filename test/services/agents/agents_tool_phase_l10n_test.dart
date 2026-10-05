import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chuk_chat/l10n/app_localizations.dart';
import 'package:chuk_chat/services/agents/agents_run_ledger.dart';
import 'package:chuk_chat/services/agents/agents_turn_phase.dart';
import 'package:chuk_chat/services/automations/agents_automation.dart';
import 'package:chuk_chat/widgets/agent_activity/agent_activity_model.dart';

/// The running tool and the automation states speak the reader's language
/// (UI audit 2026-10-05, item 6). English stays the fallback without
/// localisations.
void main() {
  const key = 'thread-l10n';
  final ledger = AgentsRunLedger.instance;
  final AppLocalizations de = AppLocalizations(const Locale('de'));
  final AppLocalizations en = AppLocalizations(const Locale('en'));

  setUp(ledger.reset);
  tearDown(ledger.reset);

  AgentsTurnStatus statusNow() =>
      agentsTurnStatusFor(run: ledger.runFor(key), linkUp: true)!;

  test('an open tool from the ledger is localised', () {
    ledger.begin(key);
    ledger.openTool(key, 'web_search');
    expect(statusNow().phase, AgentsTurnPhase.tool);
    expect(statusNow().label(), 'Searching the web');
    expect(statusNow().label(en), 'Searching the web');
    expect(statusNow().label(de), 'Sucht im Web');
  });

  test('an unknown ledger tool reads "Running …" / "Nutzt …"', () {
    ledger.begin(key);
    ledger.openTool(key, 'make_slides');
    expect(statusNow().label(), 'Running make slides');
    expect(statusNow().label(de), 'Nutzt make slides');
  });

  test('the host\'s phase tool gets a verb, not the bare tool name', () {
    ledger.begin(key);
    ledger.taskSent(key, 't-1');
    ledger.hostPhase(key, phase: 'tool', tool: 'web_search');
    expect(statusNow().label(), 'Searching the web');
    expect(statusNow().label(de), 'Sucht im Web');
    // A host tool with no phrase keeps its own name in every language.
    ledger.hostPhase(
      key,
      phase: 'tool',
      tool: 'mcp__playwright__browser_click',
    );
    expect(statusNow().label(de), 'Browser click');
  });

  test('toolActivityLabel covers the known verbs in German', () {
    expect(toolActivityLabel('bash', de), 'Führt einen Befehl aus');
    expect(toolActivityLabel('fetch_page', de), 'Liest eine Seite');
    expect(toolActivityLabel('search_chats', de), 'Sucht');
    expect(toolActivityLabel('send_file_to_user', de), 'Sendet eine Datei');
  });

  test('automation state chips are localised and in sentence case', () {
    expect(automationStateLabel('active'), 'Active');
    expect(automationStateLabel('paused', de), 'Pausiert');
    expect(automationStateLabel('done', de), 'Erledigt');
    expect(automationStateLabel('failed', en), 'Failed');
    expect(automationStateLabel('sleeping'), 'Sleeping');
  });
}
