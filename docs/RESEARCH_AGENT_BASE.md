# Agents — Recherche: Basis der Agent-Runtime

Vier parallele Recherchen (2026-08-28) zu Loop/MCP, Memory, Compaction und
Scheduling. Ziel: fertige Implementierungen von Leuten finden, die das schon
gelöst haben, und entscheiden was wir nutzen. Der bestehende Plan
(`AGENTS_AGENT_PLATFORM_PLAN.md`) portiert für vieles Hermes Agent (Nous, MIT);
hier steht, was die Recherche bestätigt und was sie daran ändert.

Leitentscheidung über alle vier: **kein Framework adoptieren.** Unser
strukturierter Loop + append-only SQLite ist im Kleinen schon das
OpenHands-Event-Stream-Muster. Wir kopieren Muster und ~50-300-Zeilen-Vorlagen,
importieren keine Monolithen (LangChain/LangGraph/Letta-Server).

## Privacy-Rahmen (harte Vorgabe)

Nur offline + Open Source. Wir adoptieren **keinen Cloud-Dienst** — wir kopieren
Muster und bauen selbst. Alle Daten (Message-Log, Memory, Cron, Checkpoints)
liegen in *unserem* SQLite auf dem Host. Das Einzige was rausgeht sind die
Modell-Calls durch den `api.chuk.chat`-Proxy — dieselbe Grenze wie heute (§14).
Damit ist das Design privacy-sauber by construction.

Explizit meiden (nicht echtes OSS / cloud-first): **Restate** (BSL),
**Inngest** (source-available), **Zep Cloud**, **Mem0/Memobase Cloud-Tier**.
Mem0, Memobase, DBOS, Temporal, Graphiti sind zwar alle OSS + self-hostbar, aber
wir nehmen ohnehin nur die Designs, keine Dienste.

---

## 1. Tool-Call-Loop + MCP-Client

**Protokoll-Referenz = Qwen-Agent** (`QwenLM/Qwen-Agent`, ~11k, Apache-2.0).
Unser `<tool_call>{json}</tool_call>` im Assistant-Text ist exakt deren
Nous/Hermes-Format. Übernehmen: der tolerante Parser (mehrere Blöcke pro Turn,
Whitespace, Prosa drumherum), der `<tools>`-Schema-Block im System-Prompt, die
`<tool_response>`-Feedback-Form. Plus Hermes `Hermes-Function-Calling`
(Apache-2.0): schema-validate der geparsten Args **vor** dem Call (Pydantic).

**Delta zum aktuellen Code (`loop.py`):** Keiner der starken Loops
(OpenHands, Cline, smolagents, SWE-agent) nutzt "bare-text = fertig". Alle haben
ein **explizites Terminal-Tool** (`finish` / `final_answer` /
`attempt_completion` / `submit`). Grund: ein legitimer Mid-Task-Reasoning-Turn
ohne Tool-Call wird sonst als Endantwort fehlgelesen. → strukturelle Regel als
Fallback behalten, `finish`-Tool ergänzen.

**Loop-Härtung kopieren (OpenHands / smolagents / Aider):**
- `max_iterations`-Cap, beim Erreichen ein erzwungener "wrap-up"-Turn statt Hang.
- Token/Cost-Budget pro Task mit Abbruch (OpenHands `max_budget_per_task`).
- Stuck-Loop-Detektor: Hash der letzten Actions, Abbruch bei N Wiederholungen.
- Reflect-on-tool-error: Fehler als Observation zurückspeisen, Retry mit Cap.

**MCP-Client:** offizielles `mcp` SDK (`modelcontextprotocol/python-sdk`),
Version `mcp>=1.28,<2` pinnen (v2 mit `Client` ist neu; v1 `ClientSession` ist
battle-tested). Ablauf: `initialize()` → `list_tools()` → `call_tool()`.
Bridge ~50 Zeilen: jedes MCP-Tool namespaced (`serverid__tool`) in unsere
`ToolRegistry`, `inputSchema` verbatim als Schema, `call_tool`-closure als
Handler → der `<tool_call>`-Parser behandelt MCP-Tools wie native. Referenz:
Qwen-Agent `qwen_agent/tools/mcp_manager.py`.
Gotchas: alles async + context-managed → Sessions über `AsyncExitStack` für die
Agent-Lebensdauer offen halten (nicht pro Call neu spawnen, sonst Subprozess je
Call). Bei sync-Loop: MCP-Client in eigenem Event-Loop-Thread,
`run_coroutine_threadsafe`. `call_tool` liefert Content-Blöcke, nicht String —
`isError` prüfen, `structuredContent` bevorzugen. stdio = lokal, streamable-HTTP
= remote, SSE = legacy.

**Gesperrt (Owner bestätigt, 2026-08-28):**
- **Nicht alle Tool-Schemas in den Kontext kippen.** Bei vielen Servern = 50-150k
  Tokens. → dynamische Tool-Auswahl / tool-search von Anfang an; nur Schemas der
  für den aktuellen Task relevanten Tools injizieren. "code-execution-with-MCP"
  (~98% Token-Cut: MCP-Server als Code-Module im Sandbox, Modell schreibt Code
  statt Tool-Schemas) in der Hinterhand, sobald die Server-Zahl wächst.
- **Nicht auf den MCP-Back-Channel bauen.** sampling/elicitation/roots sind im
  2026-07-28-Spec deprecated (~2027 Sunset). **elicitation** (strukturierte,
  schema-validierte Rückfrage) jetzt nutzen; **sampling ignorieren** (ein fremder
  Server verbrennt sonst unsere Tokens + steuert das Modell). Migrationspfad =
  MRTR `input_required`-Re-Call — ein Tool-Result signalisiert "brauche Input",
  Client sammelt ihn und ruft dasselbe Tool erneut mit `inputResponses`. Das ist
  nur ein weiterer Tool-Turn, passt 1:1 auf unseren append-only Loop.

Weitere gelesene Repos (nur Muster, nicht adoptieren): OpenHands
`All-Hands-AI/OpenHands` (MIT, Event-Stream + AgentState-Maschine), Cline
(Apache-2.0, XML-Tag-Streaming-Parser), smolagents (Apache-2.0, `final_answer`
als Tool), SWE-agent (MIT, Tool-Ergonomie/ACI), Goose (Apache-2.0, MCP-native),
Aider (Apache-2.0, Edit-Formate + reflect-on-error).

---

## 2. Memory

**Bestätigt (Plan §12):** selbst bauen, ~150 Zeilen, kein Framework, kein
Vektor-Server nötig. Der "billiges 2. Modell schreibt Memory"-Ansatz ist ein
etabliertes, mehrfach geshipptes Muster — kein Risiko:
- **Letta sleep-time compute** — 2. Agent teilt sich die Memory-Blocks, schreibt
  sie im Idle um.
- **Mem0** (`mem0ai/mem0`, Apache-2.0) — async extract + update-Modell getrennt
  vom Task-Modell; ADD/UPDATE/DELETE/NOOP-Reconciliation gegen bestehende
  Memories. Blueprint (arxiv 2504.19413), Design kopieren nicht Lib importieren.
- **Memori** (`MemoriLabs/Memori`, SQLite-nativ) — Dual-Mode: *conscious ingest*
  (einmal beim Start, = unser frozen MEMORY.md) + *auto ingest* (dynamisch je
  Query); Background-Worker extrahieren off-path.
- Stanford Generative Agents (2023) — Reflection-Loop.
- LangMem (`langchain-ai/langmem`, MIT) — Taxonomie semantic/episodic/procedural,
  Vokabular übernehmen, nicht die LangGraph-Bindung.

**Deltas zum Plan §12 (aus dem tiefen Durchgang):**
1. **Nicht als ein FTS5-Textblob speichern — typisiertes Profil dazu.**
   Memobase (`memodb-io/memobase`) nutzt bewusst **keine Embeddings**, hält ein
   strukturiertes User-Profil (typisierte Keys), retrievt per SQL — und schlägt
   Mem0/LangMem/OpenAI auf LoCoMo. → `user_profile(key,value)`-Tabelle, immer
   voll injiziert (klein, deterministisch, höchster Hebel).
2. **Nicht hart einfrieren, nicht hart überschreiben.** Anthropics memory tool
   (`memory_20250818`) + context editing validiert MEMORY.md auf
   Plattform-Ebene, editiert die Files aber **live** mid-session (84% weniger
   Tokens über 100 Turns). Gleichzeitig zeigt eine Cluster von 2025/26-Papers
   eine **Drift-Failure-Klasse** bei self-editing (kumulativ, persistent). Auflösung:
   **append/supersede statt destruktiv überschreiben**, periodische
   Konsolidierung, und Start-Snapshot aus Profil + Top-Memories bauen, aber
   mid-session **reload** erlauben statt echtem Freeze.
3. **FTS5-only kostet ~10 Punkte Recall** (LongMemEval: BM25 86% vs +Vektor 95%;
   `xiaowu0162/longmemeval`). Defensiv ohne Vektor-DB: **Porter-Stemming** (nicht
   default-Tokenizer) + **Query-Expansion/Synonyme** + **writer-emittierte Tags**
   pro Memory (A-MEM-Trick, `agiresearch/A-mem`, NeurIPS 2025). Sauberer Seam für
   optionales `sqlite-vec` später (single-file, exakter Flat-Scan, bei 1 User
   trivial schnell) — erst wenn Recall in der Praxis schwächelt.

**Empfohlenes Schema:**
```
user_profile(key PK, value, updated_at, source_msg_id)     -- (a) typisiert, immer injiziert
memory(id PK, kind, subject, body, tags, source_msg_id,    -- (b) atomar, append/supersede
       created_at, supersedes, status DEFAULT 'active')     --     nie hard-delete
-- (c) FTS5 über subject||body||tags, Porter-Stemmer
```
**Write-Trigger:** debounced (alle ~6-10 Turns / Task-Grenze / Token-Schwelle),
**nie pro Message** (Token-Kosten). Cheap-Modell bekommt (letzte N Turns +
aktive Memories + Profil), gibt JSON-Ops zurück (`add` memory, `set` profile),
nur append/supersede. Business-Risiko: Writer läuft auf eigene Kosten mit
Cadence → Input-Context cappen, debouncen.

Verworfen (zu schwer / Server / Graph-DB): Zep/Graphiti (Neo4j), cognee
(eingebettet aber volle Pipeline), Memary (unmaintained), Motorhead (Redis-Server).

---

## 3. Compaction / Context-Management

**Bestätigt (Plan §7.3):** head verbatim + Mitte per LLM-Summary + Schwanz
verbatim, rekursiv (neue Summary aus alter Summary + verdrängter Mitte). Es gibt
keinen "geheimen" besseren Algorithmus — das ist State of the Art
(amortized forgetting + rolling summary, arxiv 2511.03690).

**Delta zur "pre-compact jede Runde"-Idee:** die Trennung *Summary erzeugen* vs
*anwenden* ist richtig und = OpenHands-Modell. Aber **nicht jede Runde**
zusammenfassen (1 LLM-Call/Runde = Geld weg). Trigger erst bei
**Token-Schwelle (~70% Fenster)**, Event-Zahl als billiger Sekundär-Trigger.

**Kern-Trick von OpenHands (kopieren, nicht Framework porten):** ein
`Condensation`-Event (`forgotten_event_ids` + `summary` + `summary_offset`)
wird erzeugt, **der Roh-Log bleibt unangetastet**; vor jedem Call wird eine
**View projiziert**, die vergessene Events rausfiltert und die Summary am Offset
einsetzt. Nichts wird gelöscht, nur eine kompakte Sicht projiziert → jede
Compaction reversibel. Vorlage: `OpenHands/agent-sdk` (MIT)
`openhands-sdk/openhands/sdk/context/condenser/{base.py,llm_summarizing_condenser.py}`
(~300 Zeilen), Parameter `max_size`, `keep_first`, `target_size = len//2`.

**Empfohlenes Design (SQLite):**
```
messages(id, ts, role, content, tool_call_id, token_est, alive DEFAULT 1)  -- Roh-Log, nie löschen
summaries(id, covers_up_to_msg_id, summary_text, token_est, created_ts)    -- append-only, rekursiv
state(key, value)   -- z.B. active_summary_id
```
View pro Turn = System-Prompt + `keep_first` Turns verbatim + aktive Summary +
alle `id > covers_up_to_msg_id` verbatim (Schwanz ~25-30% Budget).
Summary-Prompt zwingt Struktur (offene Aufgaben / Entscheidungen /
Datei-ID-Pfad-Fakten / letzter Fehler / nächster Schritt) → verhindert
Faktenverlust (Schwäche freier Prosa-Summaries). Past-tense-Anchoring, damit ein
resumter Run fertige Aktionen nicht neu ausführt.

**Tool-Outputs separat + früher kürzen:** große Ergebnisse (Logs, HTML,
Suchtreffer) im Roh-Log, in der View nach M Runden auf Kopf/Fuß-Auszug maskieren
(OpenHands `ObservationMaskingCondenser`) — spart oft mehr als die
Gesprächs-Summary, verlustfrei aus SQLite rückholbar.

Andere: Claude Code `/compact` (Voll-Reset, verlustbehaftet), Codex CLI (ähnlich),
Aider `ChatSummary` (head/tail an Assistant-Grenze, rekursiv), LangChain
`trim_messages` / `ConversationSummaryBufferMemory` (deprecated), MemGPT/Letta
(self-editing + recursive summary, braucht Tool-Calls + Vektorspeicher, Overkill).

**Gesperrt (Owner bestätigt, 2026-08-28) — dreht §7.3:** Prompt-Cache ist ein
Prefix-Match, kein Diff. Ein Umschreiben in der Mitte bricht den Cache für alles
danach (10x Kosten: 0,30 vs 3,00 USD/MTok). Deshalb **keine rekursive
in-place-Re-Summarization** (die §7.3/OpenHands macht). Stattdessen **frozen,
append-only Summary-Blocks**: ein Block wird einmal geschrieben und nie wieder
angefasst; ältere Nachrichten werden in einen *neuen* Block zusammengefasst und
angehängt. Struktur: `[system][summary 1-100][summary 101-200]...[letzte N
wörtlich]`. Frühere Blocks bleiben byte-identisch → der gecachte Prefix
überlebt; Kompaktieren kostet nur einen einmaligen Cache-Miss, danach ist der
neue kürzere Prefix wieder heiß. Roh-Log bleibt unmutiert (View-Projektion).
Implementiert in `compaction.py` + `summaries`-Tabelle (append-only).

**Gebaut (2026-08-28):** `finish`-Terminal-Tool + `python`-Code-Action-Tool in
`tools.py`, Loop bricht bei `finish` mit der Summary ab (bare-text bleibt
Fallback). Tests grün.

---

## 4. Scheduling / Cron / Autonomie

**Bestätigt (Plan §13):** Modell emittiert Schedule-String, kleiner
deterministischer Parser (`croniter`), Self-Scheduling-UX nach Letta-Modell —
Agent-Tool schreibt cron-Rows in SQLite, persistent bis Agent sie löscht.

**Nicht-offensichtliches Delta: die echte Lücke ist Durability, nicht der
Trigger.** APScheduler/croniter persistiert nur den *Zeitplan*, nie den
*laufenden Run*. App zu mitten im 90min-Job → Neustart bei null.
**Durable-Execution-Engines** checkpointen jeden Schritt → Run resumed nach
Restart, plus durable timers (`sleep(30d)` überlebt Prozess-Tod) und
wake-on-event statt polling.

- **DBOS Transact-py** (`dbos-inc/dbos-transact-py`, ~1.5k, MIT) — bester Fit,
  **Library nicht Server**. `@DBOS.workflow` / `@DBOS.step` /
  `@DBOS.scheduled("cron")`. Crash-resumable, exactly-once Steps, durable timers.
  **Haken: checkpointet nach Postgres, nicht SQLite.**
- Hatchet (7.8k, MIT, Postgres, Engine), Temporal (22.5k, MIT, braucht Server —
  Goldstandard, zu schwer lokal), Restate (BSL, Lizenz-Risiko), Inngest/Trigger.dev
  (JS-first, source-available).

**Entscheidung (offen, muss nicht jetzt fallen):**
- **Postgres verfügbar** (wir deployen eh über dokploy/`ssh dps` → billig):
  DBOS Transact-py adoptieren. Loop-Turn als `@DBOS.workflow`, Tool-Calls als
  `@DBOS.step`, `@DBOS.scheduled` ersetzt den croniter-Trigger. Lange Runs
  crash-resumable gratis. MIT, kein Lizenz-Risiko.
- **Rein SQLite/lokal:** kein Drop-in. Minimal selbst bauen —
  `run_checkpoints(run_id, last_step, ...)` (LangGraph resume-token-Muster) für
  Resume statt Restart, wake-Tabelle statt polling. Trigger bleibt
  croniter+APScheduler.

MCP-Cron-Server (jolks/mcp-cron, PhialsBasement/scheduler-mcp) = dünne Wrapper,
keine Durability → skip. APScheduler 4.0 = async-Rewrite, aber weiter nur
Schedule-Persistenz, nicht Execution-Durability → gleiche Lücke.

---

## Zusammenfassung der offenen Entscheidungen

1. **`finish`-Terminal-Tool** ergänzen (Loop-Robustheit) — klar ja.
2. **Memory-Schema:** typisiertes `user_profile` + atomare `memory` mit Tags +
   FTS5 Porter, append/supersede statt Freeze/Overwrite — Verfeinerung von §12.
3. **Compaction:** OpenHands-View-Projektion (Roh-Log unangetastet), Trigger bei
   Token-Schwelle nicht per-Runde — Verfeinerung von §7.3.
4. **Durability:** Postgres+DBOS vs SQLite+DIY-Checkpoints — echte
   Architektur-Wahl, an das Deployment gekoppelt. Noch offen.

---

## Umsetzungsstand (2026-08-28)

Gebaut, verdrahtet, getestet (100 passed, 1 skipped in `agent/`):

- **`tools.py`** — `python`-Code-Action-Tool (CodeAct) + `finish`-Terminal-Tool.
- **`loop.py`** — `finish` beendet den Loop mit Summary (bare-text bleibt
  Fallback); optionale `compactor` + `memory_writer` verdrahtet (View statt
  Full-Replay, recall-Injection pro User-Turn, on_turn + maybe_compact pro
  Runde, alles best-effort).
- **`mcp_bridge.py`** — `MCPManager` (MCP v2.1.1 Client, sync-Wrapper über
  daemon-thread, dynamic/eager Mode, namespacing, elicitation-Seam, sampling
  weggelassen, opt-in Memoization). 13 Tests.
- **`compaction.py`** + **`state.py`** — `Compactor` mit frozen-append
  Summary-Blocks (`summaries`-Tabelle), cache-schonende View-Projektion,
  tool-output-Masking (Referenz statt Inhalt), Tool-Fehler bleiben verbatim.
  11 Tests.
- **`memory.py`** + **`memory_writer.py`** — Mem0 offline (Telemetrie aus,
  lokaler Ollama LLM+Embedder oder eigener Proxy, lokaler Qdrant) + debounced
  best-effort Background-Writer mit recall. 10 Tests.
- **`runtime.py`** — `build_runtime` verdrahtet alles optional
  (`enable_compaction`, `memory_writer`, `mcp_manager`); `ModelSummarizer`-Adapter.

**Gesperrt — Embeddings (Owner bestätigt, 2026-08-28):**
- **Text-Embedder = bestes Modell über den Proxy: `Qwen3-Embedding-8B`**
  (Fireworks `fireworks/qwen3-embedding-8b` / DeepInfra `Qwen/Qwen3-Embedding-8B`,
  Top-MTEB, mehrsprachig, resizable) @ **1024 Dims**. Läuft über die
  `/v1/embeddings`-Route, Upstream ist ZDR. LLM ebenfalls über den Proxy,
  Vector-Store = lokaler Qdrant (1024).
- **fastembed `nomic-embed-text-v1.5` (768) = Air-Gap-Fallback**, nicht Default.
- **Kein Multimodal-Embedder.** Bilder werden bei Bedarf per VLM (Haupt-Modell
  oder Gemma 3 / Qwen2.5-VL über DeepInfra) zu **Text** konvertiert und laufen
  dann durch dieselbe Text-Pipeline. Kein Bild-Vektor, kein zweiter Store,
  kein jina-clip/nomic-vision.
- **Proxy `/v1/embeddings`** (gebaut vom api_server-Agenten, `routers/embeddings.py`):
  **Chain DeepInfra → Fireworks** mit automatischem per-Request-Failover (beide
  ZDR), stabile Modell-Aliase (`qwen3-embedding-8b`, `nomic-embed-text-v1.5`) →
  Provider-ID, `dimensions`-Passthrough, `verify_token` + `check_billing`. 14
  Tests grün, noch nicht deployed. **Nötig** für Memory; best-effort bis live.
- **Baseten evaluiert + verworfen** (für Embeddings): bietet Embeddings nur als
  dedizierte GPU (Fixkosten pro Stunde), kein per-Token-Serverless — lohnt bei
  unserem Volumen nicht. Nur DeepInfra + Fireworks.
- **Writer-LLM (Fakten-Extraktion) = `google/gemma-4-26B-A4B-it`** (günstigster
  Input auf DeepInfra + multimodal → macht auch Bild→Text). Alternative reine
  Text: `deepseek-ai/DeepSeek-V4-Flash-0731`. **Offen:** braucht eine
  OpenAI-kompatible `/v1/chat/completions`-Route am Proxy (wie Embeddings) —
  fehlt noch.

Offen: Durability (Punkt 4 oben), Container-Entrypoint (Agent-Main → Relay +
Loop), und der Scheduler (§13).
