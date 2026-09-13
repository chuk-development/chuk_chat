# Handover cowork-f5: Agent-Browser-Presence + Backlog (3hk, sq3, qxa, axx), Host #7

Session cowork-f5, 2026-09-05 (Start ~18:30, Stand 20:55). Koordinator zuletzt
cowork-7b. Alles committet auf `agents`; im Working Tree liegen in
`executor.py`, `host.py`, `messenger_shell_test.dart` NUR fremde (Codex-)Hunks,
nichts von f5.

## Commits (in dieser Reihenfolge)

| Hash | Inhalt | Bead |
|---|---|---|
| cb93b5b | `BrowserPresence` (Browser-offen-Ableitung aus Playwright-`tool`-Frames + `browser_view`), `BrowserViewPage.open()` = Vollbild-Route (fullscreenDialog) + Fullscreen-Toggle, Tests, Proposal | cowork-vzm |
| b21dd18 (af, mit f5-Hunks) | Shell: Rail-Icon + Sidebar-Row + Seitenpanel weg, Top-Right-Button nur bei `_browserOpen`, Phone-Chip gegated; `AgentsRelayRunState.browserOpen`; Contract-Absatz | cowork-vzm |
| 7e3ecad | Host-Wahrheit: `run_state.browser_open`, `browser_view opened/closed` (executor `_on_tool_event`, `_vnc_start` WINDOWS, `stop()`), `protocol.browser_state_from_tool` | cowork-vzm |
| 4d2ff4a (chuk_chat master) + 010c24e | Thinking-Default `high`, Cold-Cache-Leitern ohne `medium`, Unknown-Token-Clamp; Einzel-Re-Import `chat_mode_service.dart`, Manifest-Pin | cowork-3hk |
| 2b0fcb7 | run_ack-Timer im Host (`AGENTS_RUN_ACK_TIMEOUT_SECONDS`, 15 s), `on_run_ack` verdrahtet, Ablauf = while-away-Notify | cowork-sq3 |
| 56d6984 | Wall-Clock-Guard (`AGENTS_RUN_MAX_SECONDS`, 7200), done `reason=timeout`, Dart `wasStopped` | cowork-qxa |
| 503fbdf | Replay-Paging: `replay.limit/before_id`, `done has_more/oldest_mid/before_id`; Loader: erste Seite sofort, aeltere Seiten voranstellen, Floor-Guard | cowork-axx |

Contract: docs/WIRE_CONTRACT.md — Abschnitte "run_state.browser_open and
browser_view opened/closed", "Replay paging", `run_ack`-Zeile/-Absatz,
`done`-Reason-Liste (`timeout`).

## Tests (Stand der letzten Laeufe)

Python: executor 179 passed (ohne docker), host 152 passed (ohne docker/live),
agent Teilsuite (test_replay_paging, test_event_rows, test_state) 34 passed;
volle agent-Suite (fastembed/mem0) NICHT gelaufen (RAM-Regel).
Dart: browser_presence 10, browser_view_page 3, messenger_shell 28,
relay_client 53, replay_loader 27, replay_paging 4, relay_done_reason 2,
mobile_chat_chrome gruen; analyze 0 Fehler (6 Alt-Infos).
Bekannt rot, NICHT f5: `widget_test.dart` "MessengerShell is a chat: connect
affordance" (find.byTooltip('Settings') fehlt — Footer-Pill-Umbau, an af).

## Host #7

20:52: Host 1314544 (Codex/User, Stand 19:27) sauber beendet (runs-Tabelle:
0 running), Neustart aus `host/` mit
`AGENTS_SANDBOX_KIND=docker AGENTS_SANDBOX_IMAGE=agents-browser:latest ./.venv/bin/cowork-host run --sandbox docker`
(Log `.hostlive`). Neuer Host Pid 1770577, HEAD 503fbdf. Befund: App-Device
04c2f52f (App 1467951) reconnected ohne Code, Modell aufgeloest, "token
provisioned; ready to serve tasks", KEIN "expected account_authentication, got
X", kein Fehler; keine neue Skills-Seed-Zeile (bereits seit #5 gesaet,
idempotent).

## Offen (nur Live-Beweise, nach "Bildschirm frei" vom User)

1. Browser (vzm): Agent oeffnet eine Seite -> Button "Agent's browser" erscheint
   oben rechts (und nirgends sonst), oeffnet Vollbild-Route, Toggle; nach
   `browser_close` verschwindet der Button; nach App-Neustart per Replay
   wieder korrekt. Screenshots nach docs/screenshots/cowork-f5/ + SendUserFile.
2. cowork-266 (9e): Datei-/Subagent-/Approval-Karte ueberlebt App-Neustart
   (Code komplett in HEAD, Bead offen mit Note).
3. sq3/qxa/axx live: run_ack-Timer (App im Hintergrund -> Toast nach 15 s),
   Timeout-Done (AGENTS_RUN_MAX_SECONDS klein setzen), Paging bei langem
   Thread (erste Seite paint, Rest folgt).

## Hinweise fuer den Nachfolger

- Commit-Technik bei Dateien mit fremden Working-Tree-Hunks: HEAD-Kopie +
  eigene Ersetzungsskripte (`_scratch/f5/*_edits.py`) -> `git hash-object -w`
  -> `git update-index --cacheinfo` -> `git commit` ohne Pathspec. Skripte
  liegen in `_scratch/f5/` (nicht committet).
- `BrowserPresence` faellt auf Tool-Frames zurueck, wenn der Host kein
  `browser_open` sendet (alter Host); neuer Host gewinnt.
- Replay-Paging: `kReplayPageSize = 200` in relay_client; Delta-Replays
  (`after_id > 0`) sind nie paginiert; der Loader holt aeltere Seiten ueber
  `AgentsRelayLink.instance.controller` selbst (thread_view unveraendert).
