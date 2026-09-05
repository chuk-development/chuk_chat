# Handover: Replay verliert subagent/file/approval_request-Karten (Bead cowork-266)

Session: cowork-9e, 2026-09-05. Contract: docs/WIRE_CONTRACT.md, Sektion
"Persisted subagent / file / approval events". Nichts committet.

## Was gebaut wurde

Python (agent/executor; Import-Test vor jedem Speichern, Suiten gruen in
eigenem Lauf: agent komplett, executor 130/130, host 118/118):

| Datei | Aenderung |
|---|---|
| `agent/src/cowork_agent/state.py` | Schema `event_blobs` (Datei-Bytes, `ON DELETE CASCADE`). `get_conversation(session_id, *, include_events=False)` laesst `event`-Rows per Default weg (Modell-Kontext, loop.py unveraendert). Neu: `append_event` (Wire-Payload als Row-Rolle `event`; `data` eines `file` wird base64-dekodiert als Blob abgelegt), `update_event` (Merge in content, nur `event`-Rows), `close_open_approvals`, `event_blob`. `replay_events` liest `include_events=True`, emittiert jede event-Row als sich selbst + `replay:true` + `mid` (Datei bekommt `data` zurueck), Turn-Zuordnung laeuft weiter ueber die event-freie Liste (eine Datei mitten im Turn trennt Call und Result nicht), stabile Sortierung nach `mid`. `finish_run`/`fail_run`/`sweep_orphan_runs` schliessen offene Approvals als `denied`/`stopped`. |
| `executor/src/cowork_executor/protocol.py` | `approval_outcome_fields(approved, reason, at)` + Konstanten `APPROVAL_*`. |
| `executor/src/cowork_executor/executor.py` | Nur Emissionsstellen: `_persist_event`/`_emit_persisted`/`_emit_subagent` (Helfer, `StateStore(self._db_path)` pro Schreibvorgang wie `_record_run`), `file_sink` und Subagent-`on_event` gehen durch sie (nur `subagent_state` wird gespeichert), `_make_approval_gate(..., session_key)` speichert den Request VOR dem Frame und patcht per `_close_approval` das Ergebnis (User via `_resolve_approval`, Timeout, Stop). `_PendingApproval` hat `mid`/`closed`. |
| Tests | `agent/tests/test_event_rows.py` (8), `executor/tests/test_replay_events.py` (5). |

Dart (app; `flutter analyze` 0 Befunde in diesen Dateien; Tests gruen in
einem Lauf, 92/92 ueber replay_loader (21 Faelle), relay_client, run_ledger
(17) und tool_card_parity (5)):

| Datei | Aenderung |
|---|---|
| `app/lib/services/cowork/cowork_relay_client.dart` | `CoworkRelayFile`/`CoworkRelaySubagent`: `replay`, `mid`. `CoworkRelayApprovalRequest`: `replay`, `mid`, `decision`, `decisionReason`, `isDecided`, `isApproved`. Parser lesen `replay`/`mid`/`decision`/`decision_reason`. |
| `app/lib/services/cowork/cowork_run_ledger.dart` | Drei Top-Level-Abbildungen neben `toolCallFromRelay`: `subagentCallFromRelay(existing, ...)`, `artifactBlockFromFile(storagePath, file)`, `approvalCallFromRelay(request, {decided})`. Ledger-Methoden `subagent`/`file`/`approval` rufen sie; Live-Verhalten unveraendert. Entschiedene Approval: Optionen unter `offered_options` (nicht `options`, das liest `AskUserCard`), plus `decision` (`Publish`/`Deny`/`Expired`) und `decision_reason`. |
| `app/lib/services/cowork/cowork_replay_loader.dart` | Cases: `subagent` (nur `replay`, eine Karte pro `subagent_id`, letzter Zustand gewinnt, `mid`), `file` (nur `replay`, `mid`, Block ueber `artifactBlockFromFile`), `approval_request` (nur `replay`; entschieden oder Run laut `run_state` idle -> Info-Karte, sonst wie live). |
| `app/lib/widgets/cowork_thread_view.dart` | Ein Guard in `_onInbound`: replaytes `approval_request` mit `decision` oder ohne laufenden Run setzt `_approval` nicht (kein Prompt). c6/5c informiert. |
| Tests | `test/services/cowork/cowork_replay_loader_test.dart` (+5; die bestehenden File-/Subagent-Replay-Eingaben tragen jetzt `replay:true`/`mid`, weil der Host das so sendet), `cowork_relay_client_test.dart` (+1), `cowork_run_ledger_test.dart` (+3), `tool_card_parity_test.dart` (Replay-Subagent-Eingabe markiert). |

## Zusammenspiel

Live-Frames sind byte-identisch zu vorher. Ein Host ohne diese Aenderung
replayt keine solchen Rows; eine App ohne sie wuerde ein replaytes
entschiedenes Approval prompten. Deshalb: Host-Neustart #3 (gebuendelt mit
b5's Effort-Clamp) und App-Neubau zusammen.

## Offen

- Live-Beweis nach Host-Neustart #3 + App-Neubau:
  Datei senden lassen, App neu starten, Karte da; Subagent-Karte; Approval
  entschieden -> Karte ohne Buttons.
- Alte Rows (vor dieser Aenderung) haben keine Karten; kein Backfill moeglich.
- `search.py` (FTS) indexiert das kleine JSON der event-Rows mit (Titel,
  Ergebnis, Pfad); Datei-Bytes liegen in `event_blobs`, nie im Index.
