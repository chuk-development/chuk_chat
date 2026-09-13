# Auftrag fuer Session cowork-secrets: Secrets-Tresor (API-Keys, die die AI nie sieht)

Repo /home/user/git/cowork, Branch agents, geteilter Working-Tree, KEIN Worktree.
Koordinator: Session `cowork-76`. ZUERST per SendMessage bei `cowork-76` melden mit deinem
Session-Namen (ListAgents) und "Auftrag gelesen"; danach alle Meldungen an cowork-76.

## Lesen
1. docs/COORDINATION.md: Kopf + Abschnitt "STAND 2026-09-05 08:40" + letzte 20 Log-Zeilen.
2. docs/WIRE_CONTRACT.md komplett (Frame-Formen, additive Regel).
3. docs/HANDOVER_2026-09-05_PYTHON.md (Layout, Commit-Regeln, Suiten), docs/HANDOVER_2026-09-05_MCP_cowork-47.md
   (wie Geheimnisse heute vom Geraet zum Host wandern: mcp_servers/mcp_credentials, Spiegel in Supabase,
   EncryptionService), docs/SUPABASE_SCHEMA.md, docs/PRODUCT_PHILOSOPHY.md.
4. Python: agent/src/chuk_agents_runtime/{tools.py,registry.py,loop.py}, executor/src/chuk_agents_executor/{executor.py
   (_env_shim, run_command/run_python-Pfad, _accept_task, Frames), protocol.py}, host/src/chuk_agents_host/host.py.
   Dart: app/lib/services/mcp/mcp_store.dart (Secure-Storage + verschluesselter Supabase-Spiegel als Vorbild),
   app/lib/services/agents/agents_relay_client.dart, agents_thread_view.dart (approval_request-Karte als Vorbild
   fuer einen Dialog, den der Host anfordert), app/lib/pages/settings/ (Section-Map im Hub).

## Was gebaut wird (User-Wunsch, woertlich sinngemaess)
"Die AI hat eine .env, kann sie aber niemals lesen; sie existiert nicht wirklich als Datei. Die AI nutzt die
Keys nur programmatisch in Python/Shell. Die AI kann per Tool den User fragen: sie setzt den Namen, der User
setzt den Wert in einem Dialog, schickt ab; die AI sieht nur 'ist eingetragen'. In den Settings kann man die
Keys managen. E2E-verschluesselt in Supabase, E2E zum Python-Host."

### Vertrag (ZUERST in docs/WIRE_CONTRACT.md als additive Sektion "Secrets", Kurzfassung an cowork-76 vor dem Code)
- App → Host `secrets`: voller Satz `{"type":"secrets","entries":[{"name":"OPENAI_API_KEY","value":"..."}],"revision":N}`
  im versiegelten Frame, (a) nach Provision, (b) bei jeder Aenderung in den Settings, (c) als Antwort auf
  `secret_request`. Host ersetzt den Satz komplett (last revision wins).
- Host → App `secret_request`: `{"type":"secret_request","request_id","session_key","names":[...],"purpose":"<text>"}`.
  App zeigt Dialog: pro Name ein Feld (schon gesetzte Namen vorbefuellt als "gesetzt", nicht als Wert), Abschicken
  → Store → `secrets`-Frame → Host antwortet dem Tool. Abbrechen → Tool bekommt "missing" fuer alle offenen.
- Tool-Antwort fuer das Modell: NUR `{"OPENAI_API_KEY":"set","OTHER":"missing"}`. Nie Werte, nie Laengen, nie Prefixe.
- Persistenz auf dem Geraet: Secure Storage + Supabase-Tabelle `cowork_secrets (user_id, name, ciphertext, updated_at;
  PK user_id,name)` mit E2E-Verschluesselung ueber den vorhandenen EncryptionService (wie MCP-Spiegel). Migration als
  supabase/migrations/<ts>_cowork_secrets.sql (User fuehrt sie aus). Owner-only RLS.
- Host: Werte nur im Speicher pro User + at rest mit dem Host-Key verschluesselt (damit ein Host-Neustart ohne App
  weiterlaeuft); NIE in Logs, NIE in der runs/messages-DB, NIE im Modell-Kontext, NIE als Datei im Workspace.

### Python
- Tool `request_secrets(names: list[str], purpose: str)`: sendet `secret_request`, wartet (Condition, Timeout
  ~600 s wie approval), gibt Status-Map zurueck. Zweites Tool `list_secrets()` → nur Namen.
- Injektion: Secrets als Umgebungsvariablen NUR in den Kindprozess von `run_command` und `run_python`
  (env_shim/sandbox exec), nicht in die Shell-Session dauerhaft, keine .env-Datei. Vorhandene
  Sandbox-Grenzen (docker) beachten: Env geht in `docker exec -e`, nicht ins Image.
- Scrubber (Pflicht): jede Ausgabe, die zum Modell oder in den Store geht (Tool-Results, stdout/stderr, gelesene
  Dateien, Fehlertexte, subagent-Outputs), wird gegen alle Secret-Werte (>= 8 Zeichen) ersetzt durch
  `[REDACTED:<NAME>]`. Auch base64/URL-encoded Varianten der Werte. Test: ein Script, das `print(os.environ["X"])`
  macht, liefert dem Modell nur die Maske. Der Scrubber sitzt an EINER Stelle (Tool-Dispatch-Ergebnis + Frame-Emission),
  nicht verstreut.
- Der User weiss, dass es immer einen Umweg gibt; die Anforderung ist: Datei existiert nicht, Standardwege
  (read_file, cat, env-Dump) zeigen nur Masken, Werte landen nie im Transkript.
- Tests: agent (Tool, Scrubber-Einheiten), executor (Frame-Roundtrip, Injektion, Scrubber am Dispatch), host
  (Persistenz verschluesselt, Reload nach Neustart). Suiten wie im Python-Handover, einzeln, ruff F/E9 sauber.
  Import-Test vor JEDEM Speichern (Host startet aus dem Tree). Vollstaendig umbauen, nie halb speichern.

### Dart
- `services/secrets/secrets_store.dart` (Secure Storage + Supabase-Spiegel, Vorbild McpStore), Relay-Client:
  case `secret_request` + `sendSecrets()`; Thread-View: Dialog/Karte bei `secret_request` (Vorbild approval_request),
  Settings-Seite "API Keys" (Liste, hinzufuegen, Wert aendern, loeschen; Werte nie anzeigen, nur "gesetzt"),
  im Hub als Eintrag der Agents-Sektion (Section-Map in pages/settings_page.dart + desktop_settings_modal.dart,
  Owner-Session f7 ist fertig, Ansage an cowork-76 vor dem Edit). Tests: store, relay_client (Frame-Parse/Send),
  thread_view (Dialog → sendSecrets), settings page.

## Grenzen / Regeln (hart)
- Kein Commit, nie, ausser der User gibt es DIR direkt in dieser Session.
- Deine Dateien: neue Dateien unter services/secrets/**, pages/secrets_settings_page.dart, Python: neues Modul
  agent/src/chuk_agents_runtime/secrets.py + executor secrets-Teil; in bestehenden Dateien (tools.py/registry.py,
  executor.py, protocol.py, host.py, relay_client, thread_view, settings hubs, pubspec append-only) nur additive
  Hunks mit Ansage an cowork-76 VOR dem Edit. Parallel arbeitet Session cowork-automations in tools/registry/
  executor/host/relay_client/thread_view — frisch lesen, nur eigene Hunks, Tree muss zwischen Schritten kompilieren.
- Chuk-verbatim-Dateien (tools/chat_ui_manifest.txt) nicht anfassen. browser_view_page.dart, third_party/** tabu.
- Ein Flutter-Compiler gleichzeitig: vor JEDEM flutter test/analyze `pgrep -af 'flutter_tester|frontend_server'`
  (der frontend_server der laufenden App zaehlt nicht) + `free -m` >1,5 GB; Fenster vergibt cowork-76:
  'Fenster?' fragen, erst nach 'Fenster frei (secrets)' starten. Tests einzeln. pytest darf parallel laufen.
- Host-Neustart nur nach GO von cowork-76 (gebuendelt). App-Instanz haelt eine andere Session (kein Hot Reload).
- Keine UI-Automation/Screenshots ohne 'Bildschirm frei' vom User.
- Subagenten nur Opus 5, einer gleichzeitig; bei 429 60 s warten.
- Kontext: ab 550k stoppen, Handover docs/HANDOVER_2026-09-05_SECRETS.md. Beads: `bd create` fuer den Auftrag
  (Epic + Python/Dart-Kinder), claimen, schliessen. Status an cowork-76 in 3-5 Zeilen mit Testzahlen; nie gruen
  melden, was du nicht gesehen hast. Antworte dem User knapp auf Deutsch; Code-Kommentare ASD-STE100.
