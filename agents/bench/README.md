# agents-bench

A speed test for Agents turns. Use it to prove a speed change with numbers.

The tool has four modes:

- `snapshot` copies the live state database to `_scratch/bench/`.
- `report` reads the `runs` table of the copy. It shows where the time of each
  run went, with p50 and p95 per session and per provider and model.
- `offline` replays the prepare pipeline of one session. It does not call a
  model. It times each step.
- `live` sends real prompts to a scratch session. It costs credits. It runs
  only with an explicit flag.

## Safety rules

- The tool never reads the live database in place. It opens the live file
  read-only, copies it with the SQLite backup API, and closes it at once.
  All other work uses the copy.
- The copy goes to `<repo>/_scratch/bench/`. Git ignores this directory.
- The tool does not touch the running host (`agents-manager`).
- `offline --runtime-src` can import the runtime from another tree. The tool
  then writes no `.pyc` file into that tree.
- `live` runs only on a `bench:<random>` session in a scratch database.
  It reads credentials only from environment variables. It never reads a
  `.env` file or the app session file.

## Setup

```bash
cd agents/bench
uv sync
```

The runtime is an editable dependency. The bench imports
`agents/runtime/src` from this checkout. A change there shows in the next run.

## Commands

All commands run from `agents/bench`.

```bash
# Copy the live DB (report and offline do this when no copy exists).
uv run agents-bench snapshot

# All measured runs. --fresh takes a new copy first.
uv run agents-bench report --fresh

# Only the "hi" runs of one session, as JSON.
uv run agents-bench report --session local:brisk-heron:2:116636868 --prompt hi --json

# Add the backend "model call" log lines (connect, first frame, first token).
journalctl --user -u agents-manager --since today | uv run agents-bench report --log -

# Replay prepare for one session: 3 runs, one model request each.
uv run agents-bench offline --session local:brisk-heron:2:116636868

# Save a result, change the runtime, then compare.
uv run agents-bench offline --session KEY --out ../../_scratch/bench/before.json
uv run agents-bench offline --session KEY --baseline ../../_scratch/bench/before.json

# Profile the ladder of pass 1.
uv run agents-bench offline --session KEY --passes 1 --profile

# The same replay with the runtime the host runs (an older tree may need
# an extra package, for example websockets).
uv run --with websockets agents-bench offline --session KEY \
    --runtime-src /home/user/git/agents-merge/agents/runtime/src
```

## Report fields

- `wall` is `finished_at - started_at`.
- `prepare`, `model`, `tool`, `recall` are the `runs` columns `prepare_ms`,
  `model_wait_ms`, `tool_ms`, `recall_ms`.
- `other` is the part of `wall` that no column claims.
- Runs with `model_calls = 0` have no timings. The report skips them.
  Use `--all` to show them.
- `--prompt` compares the first 40 characters of the prompt.

## Offline steps

One pass is one new run. It has a fresh context ladder, as in production.
`--rounds` sets the model requests per run.

| Step | What it does |
|------|--------------|
| `open_store` | Opens the `StateStore` on a working copy |
| `skills_load` | Loads the agent skills (build time in production) |
| `history_load` | Reads the stored rows of the session |
| `prompt_upgrade` | Updates the stored system prompt |
| `(scrub_history)` | Removes old reasoning; also part of `ladder_prepare` |
| `ladder_prepare` | Runs the context ladder |
| `estimate_tokens` | Counts the outbound tokens |
| `convert_pai` | Converts the rows to Pydantic AI messages |
| `prepare_total` | `history_load + prompt_upgrade + ladder_prepare`, the same sum as `runs.prepare_ms` |

The aux model is a stub. The stub counts its calls and answers at once.
Each stub call is one real aux model call in a live turn. A live prepare is
about `prepare_total` plus the calls times the aux model latency.
Use `--aux-delay-ms` to add a fixed latency per call. Use
`--summarizer none` for tier 1 only. Use `--cold` to delete the cached
summary of the session in the working copy before pass 1.

## Live mode

Live mode calls the real model. It needs these environment variables:
`SUPABASE_URL`, `SUPABASE_ANON_KEY`, `AGENTS_LIVE_ACCESS_TOKEN`,
`AGENTS_LIVE_REFRESH_TOKEN`. Use a test account. A token refresh rotates the
token and signs out other clients that use it.

```bash
uv run agents-bench live --yes-spend-credits -n 3 --prompt hi
# Time a long history: copy the rows of a session into the scratch session.
uv run agents-bench live --yes-spend-credits -n 2 --seed-session KEY
```

Live mode does not run by default and the tests do not run it.

## Tests

```bash
uv run pytest
```

## Baseline (2026-10-05)

Session `local:brisk-heron:2:116636868`, 458 model rows (0.88 MB).

| Source | Measure | Value |
|--------|---------|-------|
| `runs` table, "hi" run `fdc9da0e` | `prepare_ms` / `model_wait_ms` | 105919 / 3448 |
| `runs` table, "hi" run `30000720` | `prepare_ms` / `model_wait_ms` | 177007 / 3400 |
| offline, host tree `fdcf6725` | `prepare_total` p50, aux calls per run | 122 ms, 1 call on 369084 chars, every run |
| offline, checkout `185eb689+dirty` | `prepare_total` pass 1 / pass 2 / pass 3 | 158 / 61 / 33 ms; 1 aux call in pass 1, 0 after |

The runtime itself needs about 0.1 s. The rest of the 100 to 180 s prepare
is the aux model summary of the middle of the history.
