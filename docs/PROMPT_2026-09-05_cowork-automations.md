# Auftrag fuer Session cowork-automations: Cron, Watcher, Self-Wake

Repo /home/user/git/cowork, Branch cowork, geteilter Working-Tree, KEIN Worktree.
Koordinator: Session `cowork-76`. ZUERST per SendMessage bei `cowork-76` melden mit deinem
Session-Namen (ListAgents) und "Auftrag gelesen"; danach alle Meldungen an cowork-76.

## Lesen
1. docs/COORDINATION.md: Kopf + Abschnitt "STAND 2026-09-05 08:40" + letzte 20 Log-Zeilen.
2. docs/WIRE_CONTRACT.md komplett (run_state, replay, done, Detachment-Regel, Events 266).
3. docs/HANDOVER_2026-09-05_PYTHON.md, docs/HANDOVER_2026-09-05_REPLAY_EVENTS_266.md,
   docs/HANDOVER_2026-09-05_REASONING_TOOLFRAMES.md, docs/PLAN_2026-09-04_COWORK_CHUK_ALIGN.md §WS-7
   (Notifications: host/notify.py, desktop_notify.py — ein Trigger-Run muss den User benachrichtigen).
4. Python: executor/src/cowork_executor/executor.py (_accept_task, Worker-Queue pro Session, _run_task, Frames),
   agent/src/cowork_agent/{tools.py,registry.py,state.py (runs-Tabelle)}, host/src/cowork_host/{host.py,serve.py}.
   Dart: cowork_relay_client.dart, cowork_thread_view.dart, cowork_replay_loader.dart, settings hubs.

## Was gebaut wird (User-Wunsch, sinngemaess)
"Die AI kann Cron-Jobs anlegen und sich selbst wecken, wie Hermes Agent / Claude Code. Sie kann ein
Python-Script schreiben, das 24/7 im Hintergrund laeuft (z. B. alle 5 s eine Webseite fetchen) und erst bei
einer gezielten Aenderung einen Trigger feuert; der Trigger startet dann die Tool-Loop der AI erneut. Der Agent ist
fertig, aber das Script triggert ihn spaeter selbst — via Hook."

### Vertrag (ZUERST in docs/WIRE_CONTRACT.md als additive Sektion "Automations", Kurzfassung an cowork-76 vor dem Code)
- Host-Tabelle `automations` (SQLite neben runs): id, session_key, kind schedule|watcher, spec (cron|interval|at
  bzw. script_path), prompt, state active|paused|done|failed, created_at, last_fired_at, next_fire_at, fire_count,
  last_error. Persistiert, ueberlebt Host-Neustart (Watcher werden beim Start wieder gestartet).
- Frames Host → App: `automation` (state-Aenderung: created/fired/paused/cancelled/failed, mit id, kind, spec,
  prompt, next_fire_at) — live und im Replay (als persistierter Event-Row nach dem 266-Muster, replay:true + mid).
  App → Host: `automation_control` {id, action: pause|resume|cancel}.
- Ein getriggerter Lauf ist ein normaler Task in derselben Session (session_key), mit Prompt =
  "[automation <id> fired: <name>]\n<prompt>\n<payload>" — landet als user-Row im Transkript (Replay zeigt ihn),
  bekommt eine runs-Row, laeuft durch die normale Loop, done-Terminal, Notification ueber den vorhandenen
  Notifier (while_away wenn keine App dran). Reihenfolge: Tasks einer Session werden serialisiert (bestehende
  Worker-Queue), ein Trigger waehrend eines laufenden Runs wird eingereiht, nie parallel.

### Python
- Tools fuer das Modell: `schedule_task(spec, prompt, name?)` (spec: cron-String 5 Felder ODER `every: 300`
  ODER `at: <iso>`), `start_watcher(script_path, name?, restart: true)` (Script liegt im Workspace, laeuft
  supervised im Sandbox als Kindprozess; stdout/stderr in Log-Datei im Workspace `.cowork/automations/<id>.log`;
  bei Crash Restart mit Backoff, max Rate), `list_automations()`, `cancel_automation(id)`, `pause/resume`.
- Self-Wake-Hook fuer Scripts: kleines Modul, das das Modell im Script importieren kann
  (`from cowork_hooks import trigger; trigger("Preis unter 100", payload={...})`). Implementierung ohne Netz:
  das Script schreibt eine JSON-Zeile in eine Named-Pipe/Datei `.cowork/automations/triggers.jsonl` (append,
  atomar) oder einen Unix-Socket, den der Host ueberwacht (Watchdog-Thread mit Poll 1 s). Der Host mappt
  Trigger → Task in der Session des Watchers. Rate-Limit: max 1 Trigger pro Watcher pro 30 s (rest wird
  zusammengefasst), Zaehler in der Tabelle. Payload-Groesse capped (16 KB).
- Scheduler: Host-Thread, prueft jede 15 s `next_fire_at <= now`, feuert, berechnet naechsten Termin
  (croniter oder eigene Minimal-Implementierung ohne neue Dependency — Entscheidung begruenden), `at` = einmal.
  Fehlende App = kein Problem (Detachment-Regel). ESTOP-Datei stoppt auch Automations.
- Sicherheit: Watcher-Scripts laufen mit denselben Sandbox-Grenzen wie run_python; kein Zugriff auf Host-Secrets
  ausser ueber den Secrets-Mechanismus der Parallel-Session (env-Injektion beim Prozess-Start — sprich dich mit
  cowork-secrets ueber die Env-Injektionsstelle ab, EIN Mechanismus).
- Tests: agent (Tool-Registrierung, Spec-Parsing, next_fire), executor (Trigger → eingereihter Task, Serialisierung,
  Replay des automation-Events), host (Scheduler feuert, Watcher-Supervisor Restart, Persistenz nach Neustart).
  Import-Test vor JEDEM Speichern (Host startet aus dem Tree). Vollstaendig umbauen, nie halb speichern.

### Dart
- Relay-Client: case `automation` + `sendAutomationControl()`. Thread-View: Karte fuer automation-Events
  (created/fired/… mit Pause/Cancel-Buttons), Replay-Loader-Case (266-Muster). Uebersicht "Automations" als Seite
  in der CoWork-Sektion des Settings-Hubs (Liste aller aktiven mit next_fire/last_fired/fire_count, Pause/Cancel).
  Tests: relay_client (Parse/Send), replay_loader, thread_view-Karte, Seite.

## Grenzen / Regeln (hart)
- Kein Commit, nie, ausser der User gibt es DIR direkt in dieser Session.
- Deine Dateien: neu host/src/cowork_host/automations.py, agent/.../cowork_hooks.py (+ Sandbox-Installationspfad),
  Dart services/automations/**, pages/automations_page.dart, widgets/automation_card.dart. In bestehenden Dateien
  (tools.py/registry.py, executor.py, protocol.py, state.py, host.py, relay_client, thread_view, replay_loader,
  settings hubs, pubspec append-only) nur additive Hunks mit Ansage an cowork-76 VOR dem Edit. Parallel arbeitet
  Session cowork-secrets in denselben Dateien — frisch lesen, nur eigene Hunks, Tree muss zwischen Schritten
  kompilieren; die Env-Injektionsstelle fuer Kindprozesse gehoert cowork-secrets, du rufst sie nur auf.
- Chuk-verbatim-Dateien (tools/chat_ui_manifest.txt) nicht anfassen. browser_view_page.dart, third_party/** tabu.
- Ein Flutter-Compiler gleichzeitig: vor JEDEM flutter test/analyze `pgrep -af 'flutter_tester|frontend_server'`
  (der frontend_server der laufenden App zaehlt nicht) + `free -m` >1,5 GB; Fenster vergibt cowork-76:
  'Fenster?' fragen, erst nach 'Fenster frei (automations)' starten. Tests einzeln. pytest darf parallel laufen.
- Host-Neustart nur nach GO von cowork-76 (gebuendelt). App-Instanz haelt eine andere Session (kein Hot Reload).
- Keine UI-Automation/Screenshots ohne 'Bildschirm frei' vom User. Live-Beweis ohne UI ist erlaubt: ein
  Watcher-Script im Sandbox, das nach 10 s triggert, und der resultierende Task in der Host-DB (runs-Row) — das
  ist dein Definition-of-Done-Beweis, mit Log-Auszug ins Handover.
- Subagenten nur Opus 5, einer gleichzeitig; bei 429 60 s warten.
- Kontext: ab 550k stoppen, Handover docs/HANDOVER_2026-09-05_AUTOMATIONS.md. Beads: `bd create` (Epic + Kinder),
  claimen, schliessen. Status an cowork-76 in 3-5 Zeilen mit Testzahlen; nie gruen melden, was du nicht gesehen
  hast. Antworte dem User knapp auf Deutsch; Code-Kommentare ASD-STE100.
