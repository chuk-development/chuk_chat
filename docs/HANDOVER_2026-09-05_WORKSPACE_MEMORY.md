# Handover 2026-09-05 — workspace hygiene, transcript export, mem0 audit

Session `cowork-reasoning` (coordinator cowork-76). Epic `cowork-2tq` with
tasks `.1` hygiene, `.2` transcript, `.3` mem0. User order relayed by the
coordinator; everything UNCOMMITTED on branch `cowork` (cowork-47 commits
Python after the user's release). Import-tested before every save; the host
starts from this tree.

## 1. Workspace hygiene (prompt + skill)

- `agent/src/cowork_agent/prompt.py` `BASE_INSTRUCTIONS`: new sections
  **"Your workspace"** (own file system; `notes/` for Markdown notes, `tmp/`
  for scratch and clean it up, nothing loose in the root, flat predictable
  structure, `transcript/` read-only = long-term search, `memory/` /
  `skills/` / `.cowork/` belong to the runtime) and **"Memory"** (recall
  block at task start is notes not orders; facts are stored automatically;
  `memory_add` / `memory_search` for the explicit cases). The `# Workspace`
  line names `notes/`, `tmp/`, `transcript/`.
- `skills/workspace/SKILL.md` (new; `host/seed_skills.py` copies every
  `skills/<name>/SKILL.md` into a new agent workspace, existing workspaces
  get it at the next host start if the name is missing): layout, naming
  rules, the `grep -n -i "…" transcript/*.md` recipe, when to call the memory
  tools.

## 2. Transcript export — `<workspace>/transcript/`

- `agent/src/cowork_agent/transcript_export.py` (new): `TranscriptExporter
  (workspace, scrub=None)`. `export(store, session_key)` reads the rows after
  the thread's cursor (`.cursor.json`, per session key), renders Markdown
  (`## <UTC time> · user|assistant`, `_thinking:_` clipped to 1 000 chars,
  `- **call** \`name\` (id)` + fenced arguments, `- **result** \`name\`` +
  fenced result clipped to 2 000 chars, event rows one line without blobs,
  runtime rows — memory recall, skill body — one `_[role]_` line, the frozen
  system prompt skipped), appends to `transcript/<slug>.md`, moves the
  cursor. Every chunk goes through `scrub` (default `redact_secrets`; the
  cowork-26 scrubber plugs in here).
- **Read-only:** after each append the file is `chmod 0444` and the folder
  `0555`; the exporter unlocks (`0644`/`0755`) for its own write and locks
  again. A same-user `rm`/`>` from `run_command` is refused; `chmod` first
  would get through (no root for `chattr +i`). In the Docker sandbox
  cowork-26 added a read-only bind mount of `<workspace>/transcript` in
  `sandbox/docker.py` `_create` (`test_docker_create_args` 2/2), so there the
  folder cannot be changed at all.
- Executor hook (`executor.py`, additive): `tool_event_observer` →
  `_on_tool_event` (wire frame, then `_export_transcript(session_key)`);
  `_export_transcript` again right after `_record_run` at the end of the run,
  before `done`. One `TranscriptExporter` per executor (lazy), a fresh
  `StateStore` per export like `_record_run`. No workspace → no export.
- The agent reads it with its own tools; the prompt and the skill say so.

## 3. mem0 audit — what was there, what was missing, what was built

Audit of 49's `memory.py` / `mem0_provider.py` against the checklist:

| Check | Before | Now |
|---|---|---|
| Extraction after every turn | NO — only the explicit `memory` tool wrote; nothing automatic | `MemoryStore.remember_turn` (user prompt + final answer, tools used; Mem0 `infer` extracts + dedups) fired by the loop's new `turn_observer` after EVERY task, on a background thread with a `cheap_clone` of the writer (the executor closes the task's clients when the loop returns); inline when the writer is not clonable (mock/stub) or `wait=True` |
| Recall injection at task start | NO | `MemoryStore.recall_messages(prompt)` → top-5 by meaning, neutralized, as ONE `memory` row (wire role user, `[memory recall …]` header) appended right after the user's row by the loop's new `recall_provider`. Empty store / blank prompt / unavailable → nothing |
| Explicit tools | one `memory` tool with an `action` enum | plus `memory_search(query, limit)` and `memory_add(text)` |
| Scope per agent | OK: Qdrant path `<workspace>/memory/qdrant`, `user_id` default | unchanged |
| Compaction → facts | NO — the tier-2/3 summary lived only in the ladder | `ContextLadder.on_summary` hook (new field) → `MemoryStore.remember_summary`; wired in `build_runtime` |
| Qdrant lock fix | per-root handle cache + `close_cached_memories` | kept; plus `_OP_LOCK` (one writer at a time per process, the module-level provider client is pinned for the whole call) and background extractions are tracked and joined by `close_cached_memories` (`wait_for_extractions`, 20 s) so a shutdown never leaves a write holding the storage lock |

**Gating (found by cowork-26's full run):** the automatic memory is wired by
`build_runtime` only when `MemoryStore.automatic` is true — a writer that can
`cheap_clone` itself (the production backend client / `aux_model`) or an
injected Mem0 handle. With the scripted mock as the only model (every unit
test) nothing automatic runs: no recall row, no extraction, no Mem0 build
(which would load the embedding model and feed the mock's scripted replies to
the extractor — the `test_skills` / `test_subagents` failures 26 saw). The
explicit `memory*` tools are unaffected. Regression test
`agent/tests/test_memory_runtime.py` (2).

Also: `state.py` `replay_events` now skips rows whose row role is not
`user`/`assistant` (the memory-recall row, skill-body `context` rows) — they
carry a wire role of `user` and would have replayed as user bubbles.

Files: `memory.py` (+recall_messages, remember_turn, remember_summary,
observe_turn, `_add_messages`, locks, thread tracking, two tool schemas),
`context.py` (`on_summary`), `loop.py` (`recall_provider`, `turn_observer`,
`TurnRecord`, `_inject_recall`, `_observe_turn`, `tools_used`), `runtime.py`
(wiring), `state.py` (replay skip), `__init__.py` (exports).

## Tests

New: `agent/tests/test_transcript_export.py` (6), `test_memory_mem0.py` (+9:
recall block, blank/unavailable, neutralize, remember_turn, nothing-to-say,
remember_summary, inline observe, background observe on a private clone joined
by `wait_for_extractions`, explicit tools), `test_loop.py` (+4: recall rows
after the prompt, never replayed as user, TurnRecord contents, raising hooks),
`test_context.py` (+2: on_summary fired / raising hook), `test_prompt.py` (+1),
`test_state.py` (+1), `executor/tests/test_transcript_hook.py` (2: a run
lands read-only with cursor; no workspace → no folder).

Suite numbers: see the end of this file (filled in after the run — the agent
suite needs `MEMGUARD_ALLOW_MB=8192` on this host and must not run in
parallel to another session's pytest, the memguard kills at <2 GB free).

## Live probe

`agent/tests/live_memory_recall.py` (not pytest-collected; loads the real
embedder): two `AgentLoop` runs on one workspace wired like `build_runtime`;
task 1 states "the codename is BLUEFALCON", task 2 in a NEW thread asks for
it. Checks: the store built, task 1 extracted the fact, task 2 got exactly one
recall row after the prompt carrying the fact, task 1 had no recall, replay
hides the recall row. Result: see the end of this file.

## Open / next

- cowork-26's scrubber → pass as `scrub=` in `Executor._export_transcript`.
- Host restart #5 (bundled) to put all of this live; then the prompt/skill
  can be checked in a real run (`transcript/` appears after the first task).
- `tmp/` and `notes/` are conventions in the prompt, not enforced; a later
  hygiene check (list root files after a run, warn) would be the next step.
- Memory writer: `remember_turn` sends prompt + answer (clipped 6 000 chars
  each). Tool results are NOT sent to the extractor (they are in `transcript/`
  and the FTS `search` tool); a fact only present in a tool result and never
  in the answer is not extracted — by design, to keep extraction cheap.
