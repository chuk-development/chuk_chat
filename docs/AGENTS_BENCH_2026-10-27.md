# Agents bench, 2026-10-27

Snapshot of `~/.local/share/chuk-agents/executor-state.db` (221 runs, 147 with
timings). Tool: `agents/bench` (`uv run agents-bench report --fresh`,
`offline --session KEY`). Copies live in `_scratch/bench/`.

## State found

- `agents-manager.service` was **disabled and stopped**. The last run in the DB
  is 2026-10-23 10:00. `~/.local/share/chuk-agents/host.log` ends with "the
  account session is dead (GoTrue refused the refresh token)": the host waits
  on its heal channel until a paired app renews the session. Opening the app
  signed in is enough; no new pairing. On 2026-10-27 17:07 the restarted
  host refreshed its own session ("the host refreshed its own account
  session") and the relay accepted it at once, so a plain restart was enough.
- The host logs to the journal: `journalctl --user -u agents-manager`.
  `~/.local/share/chuk-agents/host.log` is an old file and is not written
  any more; do not read the host state from it (2026-10-29).
- Launcher `~/.local/bin/agents-host` runs
  `agents/host/.venv/bin/agents-host` from this checkout. Rolling out = run the
  Python tests, `uv sync` in `agents/host`, `systemctl --user enable --now
  agents-manager`.

## Timings (all runs)

| | p50 | p95 |
|---|---|---|
| wall | 12.2 s | 163 s |
| prepare | 43 ms | 1.7 s |
| model wait | 8.8 s | 67 s |
| tool | 0.6 s | 26 s |
| per model call: model wait | 3.8 s | 6.5 s |

Offline replay of prepare (no model): about 25 ms per run for the two largest
sessions. The context ladder works: `Mail` 158k -> 42.7k tokens (tier 3),
`brisk-heron` 163k -> 14.7k tokens. Prepare is not the bottleneck; model wait
is.

## Findings

1. **Hourly mail automation is the biggest token sink.** Session
   `local:Mail:14`, prompt "check inbox", 87 runs in one week, 5.2 M prompt
   tokens, EUR 0.49, every answer "nothing relevant, inbox empty". Each run
   adds about 270 tokens to the session, so each run costs more than the last.
2. **Runs with one model call answered without a tool call.** 10 of the last
   12 runs had `model_calls = 1` and `tool_ms = 0`: the model repeated the
   previous answer from the history instead of checking the inbox. A fired
   automation must not be answerable from history alone.
3. **No cache hits between automation runs.** Single-call runs show
   `cached_tokens = 0`. The provider cache does not live one hour. Inside a
   run the second call reads about 50 % from cache.
4. **Base prompt is about 7k tokens, not 20k.** `agents-bench
   prompt-breakdown` measures system prompt plus tool definitions at about
   7k (Mail: 3.0k tools + 4.1k system). The rest of the ~24k of a one-call run
   is history. Between two turns of one session, 99.4 % of the request is
   an identical prefix. The cache misses on hourly runs come from the
   provider cache TTL, not from a changing prefix. One known break: the ladder
   drops the old task's tool rows (bead chuk_chat-74ey).
5. Cache hit share over all runs since 2026-10-15: 34.5 % of prompt tokens.

## Done the same day

- Fired automation runs get a short history window (`context.py`,
  `automation_history_tokens = 6000`, see docs/WIRE_CONTRACT.md "The fired
  task") and `FRESH_RUN_NOTE` in the fired prompt. Mail replay: 42 685 ->
  5 362 outbound tokens (-87 %); the window no longer grows with the number of
  earlier runs. Bench: `agents-bench offline --session KEY --fire
  --automation-window on|off`.
- `agents-bench prompt-breakdown --session KEY`: tokens per system-prompt
  section and per tool, and the identical prefix between two turns.
- System prompt order: stable parts first, persona last; duplicate sentences
  removed from tool descriptions (-140 tokens).
- Still open: a live run must show that the model now calls a tool before it
  answers (bead chuk_chat-n69s).

- 2026-10-29: the Mail agent's "Fastmail-Check (stündlich)" (`22d2ae8b`)
  had `notify=always`: one push per hour, also for "nothing new" (108
  runs). Set to `on_change` in the DB. `schedule_task` now defaults to
  `on_change` for cron and `every`; `at`/`in` reminders and mail triggers
  stay `always`.

## Levers

- Fired automation runs: short history window (summary + last few turns), not
  the whole chat. Measure with `agents-bench offline`.
- Inbox checks belong on the mail trigger (`watch_mail`, zero tokens until a
  mail arrives) or on `on_change`, not on an hourly schedule.
- Keep the system prompt prefix stable (no timestamps or changing summary in
  front of the tools) so the provider cache hits across turns.
- Trim tool definitions per agent; load rare tools on demand.
