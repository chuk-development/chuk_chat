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
