# Proactive agent (CHAT-182)

The agent can act without a prompt from the user. Everything is off by
default. The user turns it on by words ("check my mail every hour but do not
bother me after 22:00"); the agent then calls the tools below.

Code: `agents/runtime/src/chuk_agents_runtime/proactive.py` (rules, prompts,
tools) and `agents/host/src/chuk_agents_host/proactive.py` (clock, pre-check,
push gate, queue). Ideas 6, 8 and 14 in `COMPETITOR_IDEAS_2026-11-24.md`.

## Tools

| Tool | What it does |
|---|---|
| `proactive_settings` | No arguments: read the settings. With arguments: change them. |
| `heartbeat_checklist` | `read`, `append` (one line) or `write` (replace) the checklist. |

Settings:

| Key | Owner | Default |
|---|---|---|
| `heartbeat_enabled`, `heartbeat_every_minutes` (15 to 1440) | chat | off, 30 |
| `full_check_hours` (a beat with no change still runs after this time) | chat | 4 |
| `brief_enabled`, `brief_time` (HH:MM), `brief_location` | chat | off, 07:30, none |
| `quiet_start`, `quiet_end` (HH:MM), `timezone` (IANA) | user | none, host time |
| `max_per_day`, `cooldown_hours` | user | 5, 12 |

"User" settings are shared by all chats of the host. The tools are deferred
(found by `search_tools`). A run that an automation started gets the tools
only when the user allowed chaining (same guard as `schedule_task`).

## Heartbeat

1. The heartbeat is a row in the `automations` table: kind `heartbeat`,
   spec `{"every": seconds}`, `notify = on_change`. The app lists it; the
   user can pause or cancel it there. The automation scheduler does not fire
   it; `ProactiveManager` does (one thread, tick 60 s).
2. The beat runs only when the chat is idle (`Executor.has_live_run`).
   Missed ticks merge into one beat.
3. No beat in the quiet hours. The next beat is set to the end of the quiet
   hours.
4. **Zero-token pre-check.** Before the model is called, the host makes one
   fingerprint per source: the checklist, each event automation of the chat
   (watcher, URL watch, mail, webhook: fire count and last result), the last
   result of each schedule, the open todo items, and extra providers
   (`signal_providers`). No change and the last model beat is younger than
   `full_check_hours`: the beat is skipped and `suppressed_count` goes up.
5. Else one turn starts in the chat. The prompt starts with
   `[automation <id> fired: Heartbeat]`, so the context ladder gives it the
   lean automation window. It holds the checklist, the list of changes and
   the rule "only speak if the user would want to know this now".
6. Nothing to tell: the agent calls `automation_result(changed=false)` and
   answers `HEARTBEAT_OK`. The app collapses the run. No toast, no push.

Checklist file: `<workspace>/memory/heartbeat/<chat>.md` (one per chat; `:`
becomes `_`). No file = a default checklist.

## Push gate

`ProactiveManager.filter_run(summary)` runs in `LocalHost._on_run_finished`
for every run with origin `automation`, before the toast and the push:

1. A heartbeat whose answer is only `HEARTBEAT_OK`, `[SILENT]` or
   `NO_REPLY`: silent.
2. A heartbeat nudge: its topic is the `automation_result` summary. The same
   topic (hash, case and spaces ignored) inside `cooldown_hours`: dropped.
   More than `max_per_day` nudges in the user's day: dropped. The run stays
   in the chat. A nudge is never repeated because the user did not reply.
3. Any automation run that ends in the quiet hours: queued in
   `<workspace>/.agents/proactive.json`. When the quiet hours end, the newest
   3 go out as normal pushes; older ones are dropped.

A run the user started (origin `app`) is never held.

## Morning brief

A row of kind `morning_brief`, spec `{"daily_at": "07:30", "timezone": ...}`.
At that time (user zone), when the chat is idle, the host first writes
yesterday's journal with `daily_summary.write_daily_summary` (zero tokens),
then starts one turn: calendar of today, important unread mail, due tasks,
new watcher results, weather when `brief_location` is set, and open points
from the journal. A source that is not connected is skipped in one line. A
brief that is more than 2 hours late (host away) waits for the next day.

## Open points

- The pre-check cannot see the user's own mailbox or calendar (they are MCP
  connectors; a look costs a model call). The beat still runs every
  `full_check_hours`. A cheap provider for agent mail or IMAP can be added
  through `signal_providers`.
- The app has no settings screen for this yet; it shows the two rows in the
  automation list with their raw kind.
