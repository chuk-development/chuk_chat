# Home: the dashboard the agents build

Status: 2026-11-02, first version. Owner request: the Agents app opens on a
Home dashboard. The agents build the dashboard from ready-made native
widgets. They never write HTML. Example: "track my push-ups, 100 a day" makes
a tracker widget, and the user presses +10 on it without a model call.

This file is the contract between the host (Python, `agents/`) and the app
(Flutter, `lib/`). When you change it, change both sides and the tests.

## 1. Where it lives

- **The host is the truth.** There is one dashboard per host, so one per user.
  It is not per agent. Every agent of the host reads it and writes to it. The
  store is a table in `<workspace>/executor-state.db`, under the fixed key
  `user`.
- **The app shows a copy and caches it** in `kv_cache` under
  `dashboard_v1_<host or user id>`, so Home draws at once and also when the
  host is offline.
- **A tap in the app** (log +10, tick an item, remove, reorder) is applied to
  the copy at once (optimistic). It is then sent as a `dashboard_op` frame.
  When the host is not attached, the op waits in the app's pending list
  (kv, same key + `_pending`) and is sent on the next attach. The host's
  answer replaces the copy.

## 2. The document

```json
{
  "version": 7,
  "widgets": [
    {
      "id": "pushups",
      "type": "tracker",
      "title": "Push-ups",
      "size": "half",
      "by": "Chuk",
      "updated_at": "2026-11-02T21:40:00+01:00",
      "unit": "reps",
      "goal": 100,
      "period": "day",
      "steps": [1, 10, 25],
      "icon": "dumbbell",
      "entries": [{"at": "2026-11-02T08:10:00+01:00", "value": 30}]
    }
  ]
}
```

- `version`: an integer that goes up by 1 on every stored change.
- `widgets`: an ordered list. The order is the order on screen. At most 40.
- Fields every widget has:
  - `id`: `[a-z0-9_-]{1,40}`, unique. The host makes one from the title when
    an `add` does not give it.
  - `type`: one of the types in §3. An unknown type is refused on write and
    skipped on draw.
  - `title`: 1–60 characters.
  - `size`: `half` (one column) or `full` (the whole row). Default: `half`
    for `tracker` and `metric`, `full` for the others.
  - `by`: the name of who changed it last (the agent's name, or `"You"` for a
    tap in the app). The host sets it; the app shows it in small text.
  - `updated_at`: ISO 8601 with an offset. The host sets it.
- A whole document is at most 128 KiB.

## 3. Widget types (catalogue v1)

| type | Own fields | Limits |
|---|---|---|
| `tracker` | `unit` (string), `goal` (number > 0), `period` (`day`\|`week`), `steps` (1–3 positive numbers, default `[1,10,25]`), `icon` (one of `dumbbell`, `run`, `water`, `book`, `sleep`, `heart`, `check`; default `check`), `entries` (list of `{at, value}`) | `entries` keeps the newest 2000; `value` may be negative (a correction) |
| `metric` | `value` (number or string), `unit`, `delta` (string such as `+4 %`), `tone` (`good`\|`warn`\|`bad`\|`neutral`), `trend` (up to 60 numbers, oldest first), `caption` | — |
| `checklist` | `items`: list of `{id, text, done}` | at most 50 items, `text` ≤ 200 |
| `note` | `text` (Markdown) | ≤ 4000 characters |
| `chart` | `spec`: the `ChukChart` JSON (`lib/widgets/charts/chart_spec.dart`, same as a `<chart>` tag) | ≤ 60 points |
| `agenda` | `date` (`YYYY-MM-DD`, optional), `items`: list of `{time, title, place}` (`time` `HH:MM`, `place` optional) | at most 30 items |
| `prompts` | `items`: list of `{label, prompt}` | at most 6 items, `label` ≤ 30 |
| `weather` | `place`, `current` `{temp, condition, code}` (`code` = WMO), `daily` list of `{date, code, max, min}`, `unit` (`C`\|`F`) | `daily` ≤ 7; the agent refreshes it |

Tracker maths (the app and the host compute the same thing):

- today = the sum of `value` of the entries whose `at` falls on the current
  local day of the device that computes it. For `period: week`: the current
  ISO week, Monday first.
- streak = the number of whole periods in a row, ending yesterday (or today
  when today already reaches `goal`), whose sum reached `goal`.

## 4. The agent tool `dashboard`

One tool, registered for every agent of the host.

| action | arguments | what it does |
|---|---|---|
| `get` | — | returns the whole document plus a short summary per tracker |
| `add` | `widget` (object without `by`/`updated_at`), `index` (optional) | adds a widget |
| `update` | `id`, `patch` (object, merged on the top level; `type` cannot change) | changes a widget |
| `remove` | `id` | removes it |
| `move` | `id`, `index` | moves it |
| `log` | `id`, `value`, `at` (optional, default now) | adds an entry to a tracker |
| `check` | `id`, `item` (item id), `done` (bool) | ticks a checklist item |

Every write may carry `expected_version`; when it is not the stored version,
nothing is stored and the tool says to `get` again. The result is short text
for the model: what changed, the new version, and for a tracker
"today 40/100 reps, streak 3".
A refused write explains why and lists the allowed types or fields.

## 5. Frames

All frames are sealed like every other frame (`docs/WIRE_CONTRACT.md`).

| frame | direction | payload |
|---|---|---|
| `dashboard_get` | app → host | `{"type":"dashboard_get"}` |
| `dashboard_state` | host → app | `{"type":"dashboard_state","dashboard":{…},"op_id":"…"}`. It is the answer to `dashboard_get` and to `dashboard_op` (then with that `op_id`). It is also pushed to every attached app after any change, also a change made by a tool. |
| `dashboard_op` | app → host | `{"type":"dashboard_op","op_id":"<uuid>","action":"log"\|"check"\|"remove"\|"move"\|"update","id":"…", …the tool's arguments}`. `add` is not offered from the app in v1. The host applies the op with `by: "You"`. It remembers the last 200 `op_id`s and does not apply one twice, but it answers again. |
| `dashboard_error` | host → app | `{"type":"dashboard_error","op_id":"…","message":"…"}` when an op is refused. The app drops that op from its pending list and takes the next `dashboard_state`. |

The app sends `dashboard_get` on every attach, after it has flushed its
pending ops.

## 6. The app

- The switch at the top is `Chats | Agents` (de: `Chats | Agenten`). Chats
  is chuk_chat's plain chats. Home is not a mode: it is the first page of the
  Agents half, before the main agent, the other agents and the rooms.
- Desktop: the "Home" row at the top of the agent roster opens Home in the
  centre pane. A pick of an agent or a room leaves Home.
- Phone (interim, until the swipe pager lands): Home is the page left of the
  conversation. Swipe right, or use the back chip of the conversation.
- State: `_agentsHomeShown` in `lib/pages/agents_shell_state.dart`.
- Code: `lib/services/dashboard/` (model, controller, cache) and
  `lib/widgets/dashboard/` (the page and one widget per type).
- Taps never call the model.
- A `prompts` item opens the main agent's thread with the prompt in the
  composer.
