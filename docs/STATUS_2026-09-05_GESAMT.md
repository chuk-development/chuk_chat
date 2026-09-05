# Cowork Gesamtstatus, 2026-09-05 (Stand ~21:00, HEAD 4370a48)

Geschrieben vom Koordinator cowork-b7 beim Abschluss. Koordinator ab jetzt: cowork-76 / cowork-7b.
Quellen: docs/COORDINATION.md (Log), Beads (`bd list`), Handover-Docs (siehe unten).

## 1. Was fertig und committet ist (181 Commits auf Branch `cowork`, ein Worktree)

### Python (agent / executor / host)
- Native OpenAI Tool-Calls, `<tool_call>`-Textprotokoll komplett entfernt (52d429d); Live-Probe bestanden (deepseek-v4-flash @ fireworks/serverless).
- Hero-Modell-Kompaktion, mem0-Memory (Fix: eine Instanz pro Workspace, Memory ueberlebt Task 2; Live-Beweis 6/6 mit echtem Qdrant), Self-Description = Skills + MCPs.
- Modellwahl pro Task (Felder model / provider / reasoning_effort im Task-Frame), Log + runs-Spalten.
- Worker-Blocker gefixt (Exception bei Modellauflösung toetete den Worker-Thread), Client-Leaks geschlossen.
- Reasoning-Streaming (on_reasoning-Seam, reasoning-Frame, Persistenz fuer Replay), Effort-Clamp; Thinking-Default 'high' statt ungueltigem 'medium' (010c24e).
- Einheitliche Tool-Frames live = replay, mit Zeitstempeln (started_at / completed_at / generation_ms).
- Retry-Duplikate: `regenerate`-Flag kuerzt die Konversation (Host speicherte pro Retry eine User-Row).
- Auth (c91): App besitzt den Token solange verbunden, Host refresht nie mitten im Task, Frames reprovision_request + account_session_rotated; live bestaetigt (Task lief nach Fix durch).
- MCP-OAuth Backend: Refresh bei Ablauf/401, Reconnect, Rueckkanal mcp_credentials fuer rotierte Refresh-Tokens, Cache-Key ignoriert rotierende Tokens, Merge statt Ueberschreiben.
- Secrets-Tresor (025200c): request_secrets, Env-Injektion in die Sandbox, Scrubber, Host-Vault AES-GCM.
- Automations (127fb10): Cron / Watcher / Self-Wake; Live-Beweis: Trigger -> Run in 2 s.
- Terminal + Hintergrund-Jobs (16d9b0a, a951ff4): tmux-Shell-Tools, Jobs mit Weckruf; Live-Beweis in Docker-Sandbox.
- Workspace-Regeln, Transcript-Export, automatisches Memory (03346e5).
- Coworker-Namen auf dem Host (13f3ee4), Skills-Sync Frames (9595e23), Browser-Presence auf dem Draht (7e3ecad), run_ack-Timer (2b0fcb7), Wall-Clock-Guard (56d6984), Replay-Paging (503fbdf).
- Suiten zuletzt: agent 865 passed, executor 167, host 149 (Vollauf unter Last: 14 test_local_run flaky, Bead 02f).

### Flutter (app)
- chuk_chat-Chat-UI verbatim importiert (Manifest tools/chat_ui_manifest.txt, Script scripts/import_chat_ui.sh, 103 Dateien in f22a189) mit Relay-Adapter (websocket_chat_service), Ledger, ReplayLoader, lokalem Cache.
- Shell nach chuk root-wrapper (535756f), Agenten-Sidebar auf chuk-Chrome neu designt, Copy-full-chat oben rechts, Model-Selection 1:1 (Dropdown, Fast/Thinking), Katalog-Default api.chuk.chat.
- Scroll-Springen beim Streaming gefixt (chat_scroll_mixin, in chuk_chat master UNCOMMITTED, in cowork committet).
- Storage: chuk-Storage verbatim (SQLite + Supabase-Sync, Tabelle cowork_chats), History-Migration des alten JSON-Caches, verwaiste Cursor werden verworfen (History von gestern kommt beim naechsten Start zurueck), Cloud-Outbox.
- MCP-OAuth auf dem Geraet verbatim (mcp_oauth, Loopback-Redirect), voller Secret-Record, Spiegel; Connector-Status aus chuk_chats Spiegel (268dcf6).
- Logout-Fix: kein Netz-Refresh solange Access-Token gueltig, Refresh-Fehler loescht nie die Session, auth_gate holt erst das Host-Paar.
- Agent-Browser nur oben rechts, nur sichtbar bei offenem Browser, Vollbild-Route mit Toggle (cb93b5b).
- Account-Seite 1:1 mit Credits im Footer, Coworker umbenennen / anlegen mit chuk-Dialog (b21dd18).
- Skills-Seite zeigt die Host-Liste mit Schalter (b91746a).
- Notifications (2790c89): lokale Toasts, FCM-Token-Row, Android-Manifest; Host-Notifier + Edge Function notify-run.
- Mobile-Layer nach Grok-Bot-Vorbild (platform_specific/mobile/**, docs/MOBILE_GROKBOT_STRUCTURE.md).
- Replay-Duplikate: invalidateCursor bei Live-done, Netz im Loader (ea6daad).

### VNC (Agent-Browser-Stream)
- Tight-Kompression (4,1 MB -> ~0,2 MB pro Vollframe, 30 FPS moeglich), RFB-Byte-Filter (nur Protokoll, Clipboard raus), VNC-Secret pro View (Auth live bewiesen), FIFO-Sendekette, Mausrad, Rect-/zlib-/JPEG-Haertung (4bcfcf8, on behalf of cowork-13).

## 2. Gebaut, committet, aber Live-Beweis mit Screenshot fehlt
Braucht "Bildschirm frei" vom User (Sessions bedienen die App nur nach Ansage) und einen App-Neubau auf HEAD.
| Bead | Thema | Session |
|---|---|---|
| cowork-0ia | Reasoning sichtbar gestreamt | b5 |
| cowork-b45 / al2 | Tool-Karten + "Worked for" live gleich replay | 84 |
| cowork-4ih / 817 | Account-Seite mit Credits, Coworker umbenennen/anlegen | af |
| cowork-qk7 | Skills-Seite vom Host | 18 |
| cowork-hza | Connector-Status aus chuk-Spiegel | 18 |
| cowork-6x2 | Mobile-Ansicht (Grok-Bot) | c6 |
| cowork-3sn | Secrets-Tresor, 5-Schritte-Nachweis (docs/HANDOVER_2026-09-05_SECRETS.md) | 26 |
| cowork-266 | Karten nach Replay, Browser-Screenshots | f5 |
| cowork-2n1 | Logout-Fix Live-Repro | 9e |
| cowork-fjf | Copy-Debug-Chat in der laufenden App | offen |
| cowork-bcl | Agent-Browser-Navigation live | offen |
| cowork-czz | Research-Flow nach Neustart | offen |
| cowork-zau | Startup-Politur, Agentenzustaende, History-Sichtbarkeit | offen |

## 3. Nur der User kann das
1. Supabase-Migrationen ausfuehren: `supabase/migrations/20260905120000_cowork_secrets.sql`, `supabase/migrations/20260905150000_cowork_skill_settings.sql` (cowork_chats ist erledigt).
2. In der App per Passwort einloggen (Verschluesselungs-Key fuer System-Prompt, Cloud-Sync, Secrets).
3. App-Neubau freigeben: im Tree arbeitet ein Codex-Agent des Users mit ~52 uncommitted Dateien (messenger_shell, account_session_provider u. a.); App 1467951 haengt unverbunden, Host 1811512 wartet auf Pairing. Codex beenden oder committen lassen, dann GO fuer Neubau #4 (c6/f5).
4. "Bildschirm frei" an den Koordinator, dann laufen alle Live-Beweise aus Abschnitt 2 (ca. 1 h).
5. cowork-sls: MCP-OAuth mit echtem Provider (Google/Notion) anmelden, 2 Minuten nach docs/HANDTEST_MCP_OAUTH.md.
6. Mausrad-Handtest im Agent-Browser (Monitor-Icon oben rechts, Rad ueber der Seite).
7. Scroll-Fix in ~/git/chuk_chat (lib/platform_specific/chat/chat_scroll_mixin.dart + Test) committen; danach Manifest-Pin in tools/chat_ui_manifest.txt anheben.
8. Optional: Firebase google-services.json + Keys fuer Android-Push.
9. Gemini-3 gibt es im Backend-Katalog nicht (nur google/gemma-4-31b-it); wenn gewuenscht, ins Backend aufnehmen.

## 4. Offen ohne Owner (kein Blocker)
- cowork-3yy P1: Agent-Recall auf seine permanente Session scopen (von 76 angelegt).
- cowork-v9x P2: widget_test 'connect affordance' rot nur durch Codex-Hunks (HEAD gruen).
- cowork-wag P2: Skill vom Client zum Host hochladen (skill_put).
- cowork-02f P3: Host-Suite test_local_run 14x rot nur im Volllauf unter Last.
- cowork-eji, cowork-dbw, cowork-kjl.5, cowork-kjl.6: P3 Kleinkram (Browser-Embedded-Mode, mcp_connect_card inline, here.now Push/Accounts).
- cowork-95i.*: P3 Ideen fuer Commerce-Tools (eBay, Booking, Spotify, Reddit, Gmail/Calendar, Lieferdienste).

## 5. Bekannte Stoerquellen
- RAM: 15 GB Maschine, oft < 2 GB frei; Regel: ein Flutter-Compiler gleichzeitig, `pgrep flutter_tester|frontend_server` + `free -m` vor jedem Lauf, Fenster ueber den Koordinator.
- Geteilter git-Index: drei Mischcommits (6d7f75e, f0a5b64, 2790c89, ea6daad) mit fremden Hunks unter falschem Betreff, Inhalt korrekt. Regel in CLAUDE.md: `git commit -o -- <pfade>` in einem Befehl, nie -a/-A/reset, `git diff --stat` vorher, ein Commit-Fenster gleichzeitig.
- Host startet aus dem Working-Tree: halbfertige Zwischenstaende haben den Host zweimal kurz zu Fall gebracht. Empfehlung: Host aus einem Runtime-Checkout auf dem letzten gruenen Commit starten.
- Sessions-Kontext: 1M Fenster, ab 600k keine neuen Aufgaben (`ccmeter list`).

## 6. Sessions und Handover-Docs
Fertig: 13 (VNC), 49 (Python-Kern), 98 (Chat-UI-Import), 5c (Shell/Model/Sidebar), f7 (Shell-Rest, P8-Review), 9e (Logout), 94 (Automations), 75 (Terminal), 47 (Adapter/MCP), 84 (Tool-Karten), b5 (Reasoning/Memory). Aktiv bzw. in Bereitschaft: af (Account/Coworker), 18 (Skills/Connector-Sync), f5 (Browser + Backlog), a4 (Storage), 26 (Secrets), c6 (Mobile, haelt App), 76/7b (Koordinator).
Docs: docs/COORDINATION.md, docs/WIRE_CONTRACT.md, docs/HANDOVER_2026-09-04_FLUTTER_ALIGN.md, docs/HANDOVER_2026-09-05_PYTHON.md, docs/HANDOVER_2026-09-05_ADAPTER_MCP_cowork-47.md, docs/HANDOVER_2026-09-05_SHELL_SETTINGS_cowork-5c.md, docs/HANDOVER_2026-09-05_SHELL_cowork-shell.md, docs/HANDOVER_2026-09-05_SECRETS.md, docs/HANDOVER_2026-09-05_AUTOMATIONS.md, docs/HANDOVER_2026-09-05_TERMINAL.md, docs/HANDOVER_2026-09-05_WORKSPACE_MEMORY.md, docs/HANDOVER_2026-09-05_SKILLS.md, docs/HANDTEST_MCP_OAUTH.md, docs/SUPABASE_SCHEMA.md, docs/PLAN_2026-09-04_COWORK_CHUK_ALIGN.md, docs/PRODUCT_PHILOSOPHY.md, docs/MOBILE_GROKBOT_STRUCTURE.md.
