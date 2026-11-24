# Where an agent's model lives

Owner question (2026-11-12, CHAT-36): "the mail agent must run on DeepSeek V4
Flash, for good" (since the model list cleanup: V4.1 Flash 1017). This page says where that setting is stored and who reads it.

## The one place: the host

An agent's own model is stored **on the host**, per thread (session key), in
the executor state database:

- file: `~/.local/share/chuk-agents/executor-state.db`
- table `session_features`, `kind = 'agent_model'`
- `data` = `{"id": "<model id>", "provider": "<slug>"?, "reasoning_effort": "<level>"?}`

No row means the agent has no own model. Then a task runs on the model the
task names, and a scheduled run uses the model of the thread's last run (the
old rule).

A row wins over everything else:

1. Every scheduled run of the thread (automations, mail wakes, goal rounds)
   runs on it (`Executor.submit_task`).
2. A task from the app runs on it, even when the task names another model
   (`Executor._accept_task`). A reinstalled app has no local record and sends
   its default; the host still runs the agent's model.
3. The status frame reports it as `model.source = "agent"`
   (`Executor._status_model`).

The row survives a host restart, an app reinstall and a new phone.

## How the app writes it

Every change of an agent's model goes through `AgentModel.setOwn` or
`AgentModel.useDefault` (`lib/services/agents/agent_model.dart`): the model
page, the composer's model picker, the reasoning level and the Fast /
Thinking switch. Each one saves the local record
(`ChatModelSelectionService`, SharedPreferences) and sends
`agent_model_set` to the host. `useDefault` sends `"model": null`, which
deletes the row.

When the app has no local record but the host's status says
`source: "agent"`, the app takes the host's model into its local record
(`AgentModel.adoptFromHost`, called from `RelayAgentControlSource`). So the
model page and the composer show what really runs.

## The frame

App to host:

```json
{"type": "agent_model_set", "session_key": "<thread key>",
 "model": "<model id>" | null, "provider": "<slug>"?, "reasoning_effort": "<level>"?}
```

Host to app (terminal): `{"type": "agent_model", "session_key": "<key>",
"model": {"id": ..., ...} | null}`, or the same with `"error"`.

## Set it by hand on the host

```bash
cd ~/git/chuk_chat/agents/executor
.venv/bin/python - <<'PY'
from chuk_agents_runtime import StateStore
s = StateStore("/home/user/.local/share/chuk-agents/executor-state.db")
s.save_feature("local:Mail:14:138509541", "agent_model",
               {"id": "deepseek/deepseek-v4.1-flash-1017"})
s.close()
PY
```

`None` instead of the dict deletes it. No restart is needed: the row is read
at the start of every run.

## The mail agent

The owner's mail agent is the thread `local:Mail:14:138509541` ("Mail"). Its
job is the automation "Fastmail-Check (stündlich)" (`executor-state.db`,
table `automations`, id `22d2ae8b`, notify `on_change`): read the owner's
Fastmail through the Fastmail MCP connector, sort mail into folders, never
send. Since 2026-11-12 its row says `deepseek/deepseek-v4.1-flash-1017`
(first set to `…-v4-flash-0731`, which the model list cleanup retired).

What broke it before (CHAT-37 to CHAT-40), and what to check first next time:

- `journalctl --user -u agents-manager | grep 'server=Fastmail'`: `kind=auth`
  means the Fastmail sign-in is dead. Only the owner can fix that: open the
  Mail thread in the app and connect Fastmail again.
- The agent's journal:
  `~/.local/share/chuk-agents/agents/local-Mail-14-*/.agents/journal.jsonl`.
  `mail_list` calls instead of `mcp__Fastmail__*` mean it read its own
  chukagents.com mailbox, not Fastmail.
- The run history: `sqlite3 executor-state.db "select datetime(started_at,'unixepoch'), model, final_answer from runs where session_key='local:Mail:14:138509541' order by started_at desc limit 5"`.

## The model layer (CHAT-181)

### Reasoning passback (DeepSeek)

DeepSeek in thinking mode needs the `reasoning_content` of all earlier
turns back when the request carries `tools`. If it is missing, the API can
answer 400. Before CHAT-181 we dropped it: the profile did not send thinking
back, and the history converter left the stored `reasoning` out.

Now `pai.model.needs_reasoning_passback(model_id)` is true for DeepSeek and
Kimi K2. For these models:

- `chuk_chat_model` sends thinking parts back in `reasoning_content`
  (`model.reasoning_passback`).
- The loop builds the history with `include_reasoning=True`
  (`AgentLoop._process_history`).
- The blocking client (`BackendModelClient.complete`: subagents, browser
  steps) does the same.

Other models get no reasoning back, as before.

### Prompt cache

DeepSeek caches only a byte-identical prefix. The audit found the order
correct: the system prompt is made once per session (`_prompt_factory`) and
has no time, counter or random id. The `[clock]` row, the memory recall and
the plan-mode rows come after the prompt of each task. Old recall and clock
rows are dropped only before the idle cut, where the cache is cold anyway.
The test `test_the_stable_prefix_is_byte_identical_across_tasks` keeps it so.

Cache hits are counted: DeepSeek's `prompt_cache_hit_tokens` (and the OpenAI
`prompt_tokens_details.cached_tokens`) go into `cached_tokens` of the run and
of each aux or browser cost line. The price book bills them at `cache_read`.

### Model per kind of work

`chuk_agents_runtime.model_routes`. Kinds: `main` (always the task's model),
`aux` (summaries, memory extraction, judges, skill review), `browser`,
`vision`, `coding`. Defaults: `aux` is the host aux model
(`AGENTS_MODEL_AUX`, DeepSeek V4.1 Flash, reasoning off), `browser` is the
host's default client, `vision` and `coding` follow the task's model.

Set a route on the host:

- for all agents: `AGENTS_MODEL_BROWSER`, `AGENTS_MODEL_VISION`,
  `AGENTS_MODEL_CODING` (plus `_PROVIDER` and `_REASONING_EFFORT`);
- for one agent: the `agent_model` row, key `routes`, or the frame
  `agent_model_set` with `"routes": {"browser": {"id": "..."}}`. A frame
  without `routes` keeps the stored routes. `"routes": null` clears them.
  The routes stay when the agent's own model is dropped.

Today the executor uses the `aux` and `browser` routes. `vision` and
`coding` are in the table, but no code reads them yet.

### Monthly spending cap

Next to the weekly budget, the host keeps a hard monthly cap in
`agent_permissions.json`, key `caps_monthly`: per agent (`cap_monthly` in the
permission frames) and for all agents on the host (key `*`,
`account_cap_monthly`). Euro per calendar month, 0 = no cap. At the cap the
executor refuses every new run with `reason: budget_exceeded` and a clear
sentence. `budget_override` does not lift it. No `budget_warning` is sent
for it (that frame names the weekly budget).

### Fallback chain

`chuk_agents_runtime.model_fallback`. The loop retries a transient failure
(5xx, 429, network, empty stream) on the same model two times. On the next
failure the run moves to the next model of the chain: the task's model,
then `TOOL_CALL_CAPABLE_MODELS`. HTTP 404/410 or `model_not_found` moves at
once. Other 4xx (400, 401, 402, 403) never fall back. A fallback model runs
without the first model's provider pin (`"provider": null`).
`AGENTS_MODEL_FALLBACK=0` turns it off. The run's cost is still priced on the
first model.

### Compressor fallback

When the blocking aux summary raises, or returns an empty or runaway reply
(`context.summary_is_junk`), the ladder does not stop the run. It trims:
the head (system prompt, first user message), one marker row (with the last
good summary, if there is one) and the newest turns. For 120 s after a
failure it trims without a new aux call. A background job never stores a
junk summary. `CompressionStats.summary_fallback` says why it trimmed.
