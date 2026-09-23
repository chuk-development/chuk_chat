# Handover: Skills-Sync Client <-> Server (session cowork-18, bead cowork-qk7)

Stand 2026-09-05. Auftrag (User): "Die Skills muessen komplett synchronisiert
sein zwischen dem Agents-Client und dem Agents-Server in Python ... Es gibt
Built-in-Skills und weitere Skills im Repository."

## Befund vorher

- Python kannte nur `<workspace>/skills/<name>/SKILL.md` (Seeds aus `skills/`
  im Repo, einmalig kopiert durch `chuk_agents_host.seed_skills`). Kein An/Aus.
- Der Client zeigte chuk_chats sechs kompilierte Built-ins (chart-authoring,
  deep-research, ...) und einen Editor fuer Supabase `user_skills`. Nichts davon
  erreichte je den Host. Null Ueberlappung.
- Die "Embedding-Model-Selection" ist im Client nur SharedPreferences und geht
  auch nicht an den Host; als Sync-Vorbild diente stattdessen
  `automation_list`/`automation_control` (Frames) und die Secrets-Persistenz
  (Supabase-Spiegel).

## Was gebaut ist

Host = Wahrheit. Der Client zeigt die Liste des Hosts, ein Switch pro Skill,
der Agent bekommt nur eingeschaltete Skills.

Python (`docs/WIRE_CONTRACT.md`, Abschnitt "Skills"):
- `agent/skills.py`: `SkillSettingsStore` (Tabelle `skill_settings` in
  `executor-state.db`, fehlende Zeile = an), `load_skills(root, settings=)`
  legt abgeschaltete Skills in `SkillLibrary.disabled` (nicht im Katalog, nicht
  im `skill`-Tool), `skills_inventory()` / `apply_skill_control()` sind die
  Frame-Bodies. `build_runtime` liest den Store bei jedem Task.
- `executor.py`: Dispatch `skills_list` / `skill_control`, beide mit einem
  terminalen `skills_list` beantwortet; Kwarg `skills_seed_root` (der Host gibt
  `seed_skills_dir()`), entscheidet `source: builtin|workspace`.
- `protocol.py`: `skills_list_payload`, `skill_control_payload`,
  `skills_list_request_payload`.
- Tests: `agent/tests/test_skills.py` (+8), `executor/tests/test_skills_frames.py` (4).

Dart:
- `services/skills/agents_skill.dart` (Modell + `AgentsSkillsControl`),
  `skills_source.dart` (`SkillsSource.instance`, wie `AutomationsSource`),
  `skill_settings_sync.dart` (Supabase `cowork_skill_settings`, best-effort).
- `agents_relay_client.dart`: `AgentsRelaySkillsList`, `case 'skills_list'`,
  `sendSkillControl` / `requestSkillsList`. Die drei Switch-Cases in
  thread_view / replay_loader / websocket_chat_service hat cowork-af gesetzt.
- `pages/skills_settings_page.dart`: Host-Liste in "Built in" und "Workspace",
  `ExpressiveSwitchRow` pro Skill, Fehler des Hosts als Karte, Offline-Hinweis.
  chuk_chats Built-in-Liste und der Editor sind raus.
- Supabase: `supabase/migrations/20260905150000_cowork_skill_settings.sql`,
  Abschnitt in `docs/SUPABASE_SCHEMA.md`. Der User fuehrt die DDL einmal aus;
  ohne Tabelle laeuft die App weiter (Spiegel best-effort).
- Tests: `test/services/skills/skills_source_test.dart`,
  `test/pages/skills_settings_page_test.dart`.

Spiegel-Regel: nach jeder Host-Antwort wird die Wahrheit des Hosts in die
Tabelle geschrieben. Bei der ERSTEN Antwort nach App-Start geht es einmal
andersherum: ein Skill, den das Konto AUS hat und der Host AN meldet, wird auf
dem Host abgeschaltet (Neuinstallation, zurueckgesetzte Host-DB).

## Offen / nicht in diesem Auftrag

- Skill vom Client zum Host hochladen (`skill_put`): eigenes Bead (angelegt).
- Die untracked chuk_chat-Reste `app/lib/services/skills/{builtin_skills.g,
  skill_frontmatter_parser,skill_registry,user_skills_service}.dart` und
  `app/lib/models/skill.dart` referenziert nichts mehr; koennen geloescht
  werden (nicht von cowork-18 angelegt, daher nicht angefasst).
- Die Liste wird erst angefragt, wenn die Skills-Seite geoeffnet wird. Soll der
  Spiegel auch ohne Seitenaufruf greifen, `SkillsSource.instance.attach()` +
  `refresh()` nach dem Pairing in `agents_shell_state.dart` aufrufen (Datei
  gehoert einer anderen Session).
- Live-Nachweis mit laufendem Host (#5/#6 Neustart) und Screenshot der Seite
  nach "Bildschirm frei".

## Nachtrag: Connector-Status-Sync mit chuk_chat (bead cowork-hza, session cowork-18)

Symptom: in chuk_chat verbundene MCP-Connectoren zeigten in Agents "connect".
Ursache: zwei getrennte Spiegel im selben Supabase-Projekt. chuk_chat schreibt
`service_credentials` (eine Zeile pro Connector, `service_name = 'mcp_<id>'`,
`encrypted_data` = Envelope von `{"connection": McpConnection.toJson,
"secrets": _McpSecrets.toJson | null}`); Agents las nur seine eigene Tabelle
`cowork_mcp_connectors` (ein Blob pro User). Gleicher Key, gleiche Modelle,
gleiche Katalog-Ids, also direkt lesbar.

Gebaut (`app/lib/services/mcp/`):
- `chuk_mcp_mirror.dart`: `ChukMcpRow` (fromBlob/toBlob in chuks Form),
  `ChukMcpMirror`-Interface, `ChukMcpSync` (select `mcp_%`, decrypt, upsert,
  delete; alles best-effort, nichts Entschluesseltes im Log), `Noop`.
- `mcp_service.dart`: `_pullRemote` = eigener Blob, dann `_pullChukMirror`
  (fehlende Connection anlegen, Secrets nur wenn lokal kein brauchbarer Record
  (47's Regel), API-Credentials nur wenn lokal leer, Liste danach neu);
  `_pushRemote` schreibt zusaetzlich `_pushChukRows` (eine `mcp_<id>`-Zeile
  pro lokalem Connector, Tools entfernt); `disconnect` loescht chuks Zeile nur
  nach Ruecklesen und Id-Abgleich (`_deleteChukRow`), nie pauschal.
  `resetForTest(chukMirror:)`, `pushRemoteForTest()`.
- Tests `app/test/services/mcp/chuk_mcp_mirror_test.dart` (17): Lesepfad,
  Vorrang des eigenen Spiegels, appSession/apiKey, unlesbare Tabelle,
  Rueckweg-Form, Loeschregeln.

Kein Python, kein Contract, keine Migration (chuks Tabelle existiert). Offen:
Live-Nachweis nach Login (chuk-Connector erscheint in Agents als verbunden,
Token kommt beim naechsten Task am Host an).
