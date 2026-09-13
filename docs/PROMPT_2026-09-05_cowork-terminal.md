# Auftrag fuer Session cowork-terminal: interaktive Shell (tmux), Hintergrund-Befehle, Full-Access-Sandbox

Repo /home/user/git/cowork, Branch agents, geteilter Working-Tree, KEIN Worktree.
Koordinator: Session `cowork-76`. ZUERST per SendMessage bei `cowork-76` melden mit deinem
Session-Namen (ListAgents) und "Auftrag gelesen"; danach alle Meldungen an cowork-76.

## Lesen
1. docs/COORDINATION.md: Kopf + "STAND 2026-09-05 08:40" + letzte 30 Log-Zeilen (dort auch die parallelen
   Auftraege Secrets (cowork-26) und Automations (cowork-94), mit denen du dich abstimmst).
2. docs/WIRE_CONTRACT.md komplett, besonders die Sektionen "Tool events and timestamps", "Persisted ... events",
   "Secrets", "Automations".
3. docs/HANDOVER_2026-09-05_PYTHON.md, docs/HANDOVER_2026-09-05_REASONING_TOOLFRAMES.md.
4. Python: agent/src/chuk_agents_runtime/{tools.py (run_command/run_python ueber env.run_bash), environment.py,
   registry.py, prompt.py}, executor/src/chuk_agents_executor/{executor.py (_env_shim, tool_event_observer),
   environment.py, sandbox/ (base/local/docker)}, host/src/chuk_agents_host/host.py. Wie der Docker-Sandbox gebaut
   wird (Image, vnc-up.sh, Dockerfile im Repo suchen).

## Was gebaut wird (User-Wunsch, sinngemaess)
"Der Agent hat sein eigenes Dateisystem (Docker-Sandbox) und darf dort ALLES: Tools installieren, root, apt,
pip — es ist seine Sandbox, wenn er sie brickt, ist das sein Problem. Problem heute: interaktive CLI-Tools
(Prompts 'Wollen Sie ...? y/n', Wizards, TUIs) kann das Modell nicht bedienen. Loesung: Bash laeuft in einer
tmux-Session; das Modell sieht, was passiert ist, wo der Befehl steht, und kann Keys senden (y, Enter, Ctrl-C).
Ausserdem: Befehle im Hintergrund starten, nicht warten, und beim Ende geweckt werden (wie bei Claude Code) —
mit Notification."

### Vertrag (ZUERST in docs/WIRE_CONTRACT.md, additive Sektion "Interactive shell and background commands",
Kurzfassung an cowork-76 vor dem Code)
- Tools (registriert wie bestehende Tools, Namen final): `shell_start(name, command?, cwd?)` (tmux-Session im
  Sandbox, optional gleich ein Befehl), `shell_read(name, lines=200)` (capture-pane inkl. Scrollback, letzte N Zeilen,
  plus Cursor-Zeile/ob ein Prozess laeuft), `shell_send(name, keys)` (send-keys; Sondertasten als Tokens: Enter,
  C-c, C-d, Tab, Up/Down, Esc), `shell_list()`, `shell_kill(name)`. `run_command` bleibt fuer Einzeiler und bekommt
  zusaetzlich `background: true` → startet detached (nohup/setsid oder eigene tmux-Session), gibt sofort {job_id}
  zurueck; `job_status(job_id)`, `job_output(job_id, tail=200)`, `job_cancel(job_id)`.
- Weckruf bei Job-Ende: der Abschluss eines Hintergrund-Jobs weckt den Agenten. Mechanismus: derselbe
  Trigger-Kanal wie cowork-94's Automations (agents_hooks.trigger / triggers.jsonl, Host-Watchdog) — abstimmen
  mit cowork-94, EIN Mechanismus; Semantik: laeuft der Run der Session noch → das Ereignis wird als Tool-Ergebnis
  nachgereicht (Loop-Seam: 'pending events' vor der naechsten Modell-Runde); ist der Run fertig → neuer Task in
  derselben Session "[job <id> finished: exit <code>]\n<letzte 50 Zeilen>" + Notification (Notifier, while_away).
  Kein Polling durch das Modell noetig; ein Timeout-Fallback (Job >24 h) wird gemeldet.
- Frames: `tool`-Frames wie heute (die Shell-Tools erscheinen als Tool-Karten mit name/arguments/result); ein
  `shell_read`-Ergebnis ist der Bildschirmtext. Kein neuer Frame-Typ noetig, ausser du brauchst einen fuer den
  Job-Abschluss (dann additiv, mit replay-Persistenz nach 266-Muster).
- Full Access: im Docker-Sandbox laeuft die Shell als root ohne Einschraenkungen (apt, pip, npm, systemd-frei);
  bestehende Limits (Output-Caps, Timeouts) bleiben nur fuer die Rueckgabe ans Modell, nicht fuer den Prozess.
  tmux muss im Sandbox-Image sein (Dockerfile ergaenzen, Image-Rebuild mit Ansage an cowork-76, weil vnc-up/VNC
  im selben Image haengen — nur additiv, kein Umbau). Lokaler Sandbox (kein Docker): tmux vom Host, gleiche Tools.
- Secrets: Kindprozesse (shell_start, background jobs) bekommen die Env-Injektion von cowork-26
  (SecretsVault.env / env_provider) — Signatur bei cowork-26 erfragen, nicht selbst bauen. Scrubber greift automatisch
  am Dispatch/Frame.
- Prompt/Skill: skills/terminal/SKILL.md (Muster skills/youtube-transcript/SKILL.md): wann run_command vs.
  shell_*, wie man ein interaktives Tool bedient (start → read → send 'y' Enter → read), wie Hintergrund-Jobs laufen
  und dass der Agent geweckt wird, Hinweis: es ist SEIN Sandbox, alles erlaubt, aber aufraeumen (Workspace-Hygiene,
  die cowork-b5 parallel als Prompt-Regel schreibt).

### Tests
agent: Tool-Registrierung, Key-Token-Mapping, Output-Caps. executor: shell_start/read/send gegen echtes tmux
(lokaler Sandbox in Tests), background job → Trigger → Ereignis als nachgereichtes Tool-Ergebnis (Run laeuft) und
als neuer Task (Run fertig), Persistenz. host: Watchdog-Integration mit 94 (gemeinsamer Test oder abgesprochen).
Live-Beweis ohne UI (dein DoD): auf dem echten Host in der Session eine interaktive Abfrage (z. B. `python3 -c
"input('continue? [y/n] ')"` oder apt-get ohne -y) per shell_start starten, per shell_read sehen, per shell_send 'y'
beantworten; ein Hintergrund-Job `sleep 20 && echo done` weckt den Agenten (runs-Row + Notifier-Log). Log-Auszug ins Handover.

## Grenzen / Regeln (hart)
- Kein Commit, nie, ausser der User gibt es DIR direkt in dieser Session.
- Deine Dateien: neu agent/src/chuk_agents_runtime/shell_tools.py, executor/src/chuk_agents_executor/shell.py (tmux-Treiber,
  Jobs), skills/terminal/SKILL.md, Tests dazu; Dockerfile/Image nur additiv (tmux). In bestehenden Dateien
  (tools.py, registry.py, runtime.py, executor.py, protocol.py, sandbox/*, host.py, loop.py fuer die Pending-Events-
  Seam, prompt.py) nur additive Hunks mit Ansage an cowork-76 VOR dem Edit; parallel arbeiten cowork-26 (Secrets:
  sandbox/* Env-Injektion gehoert 26, registry result_filter, executor Frames) und cowork-94 (Automations: executor
  submit_task/_handle_frame, host Manager, runtime) sowie cowork-b5 (prompt.py Workspace-Regel, Transcript-Export,
  mem0-Tools) in denselben Dateien — frisch lesen, nur eigene Hunks, Import-Test vor JEDEM Speichern (Host
  startet aus dem Tree), Tree muss zwischen Schritten importierbar bleiben.
- Dart: keine Aenderung noetig (Tool-Karten generisch). Falls doch: Ansage.
- Host-Neustart und Image-Rebuild nur nach GO von cowork-76 (gebuendelt). Keine UI-Automation ohne 'Bildschirm frei'.
- Subagenten nur Opus 5, einer gleichzeitig; bei 429 60 s warten.
- Kontext: ab 550k stoppen, Handover docs/HANDOVER_2026-09-05_TERMINAL.md. Beads: `bd create` (Epic + Kinder),
  claimen, schliessen. Status an cowork-76 in 3-5 Zeilen mit Testzahlen; nie gruen melden, was du nicht gesehen
  hast. Antworte dem User knapp auf Deutsch; Code-Kommentare ASD-STE100.
