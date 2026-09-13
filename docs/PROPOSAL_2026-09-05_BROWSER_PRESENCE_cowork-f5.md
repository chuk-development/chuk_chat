# Proposal: browser presence on the wire (Bead cowork-vzm, phase d)

Author: cowork-f5. Status: draft, to be built after b5's R4 Python commit, in
agreement with b5 (executor.py owner at that time).

## Why

The user wants the "Agent's browser" button only while the agent has a
browser open, "synchronised between client and server". Phase a (shipped by
f5, Dart only) derives that state in the app from the `tool` frames of the
Playwright MCP server (`mcp__playwright__browser_*`, `browser_close`) and from
the executor's `browser_view` verdicts. That works live and in replay, but the
host holds the real truth: it sees the same tool events, it counts the windows
on the Xvfb display (`agents-vnc-up` prints `WINDOWS=<n>`), and it knows when
the sandbox goes away. Phase d puts that truth on the wire, additively.

## Wire changes (docs/WIRE_CONTRACT.md, additive)

### `run_state` gains `browser_open`

```json
{"type": "run_state", "session_key": "<key>", "state": "running" | "idle",
 "browser_open": true | false, ...}
```

Always present on a current host. An old app ignores it; a new app on an old
host falls back to phase a (tool frames).

### `browser_view` gains two unsolicited statuses

```json
{"type": "browser_view", "status": "opened" | "closed", "message": ""}
```

Sent on the run's stream (the `request_id` of the task whose tool call flipped
the state), or on the live VNC stream id when the flip comes from the VNC path
(`WINDOWS=0` on start, bridge teardown because the container is gone). Only
sent on a change, never repeated. `started`/`stopped`/`error` keep their
meaning (they are about the VNC stream, not the browser).

## Executor (executor/src/chuk_agents_executor/executor.py)

* `self._browser_open: bool = False` (one sandbox, one browser per executor).
* `_on_tool_event(request_id, session_key, fields)`: derive the new state from
  `fields["name"]` (or, for `tool_call`, `fields["arguments"]["name"]`) and
  `fields["status"] == "completed"`: a `browser_*` tool that is not
  `browser_close` → open; `browser_close` → closed. On change: set the flag
  and `self._event(request_id, browser_view_payload("opened" | "closed"))`.
  The check happens BEFORE the `tool` frame goes out so the app sees the
  state flip first (ordering is deterministic on the FIFO transport).
* `_vnc_start`: `WINDOWS=0` → closed, `WINDOWS>0` → open (same change-only
  emit, on the view's `request_id`).
* `stop()` / sandbox teardown → closed (no frame needed when the transport
  is going down; the next replay's `run_state` carries it).
* `_run_state_for(...)`: pass `browser_open=self._browser_open` into
  `run_state_payload`.

Shared helper (pure, testable): `browser_state_from_tool(name, arguments,
status) -> bool | None` in `protocol.py` next to `browser_view_payload`, and
`run_state_payload(..., browser_open: bool | None = None)`.

## Tests (executor/tests)

* `test_protocol.py`: `run_state_payload` carries `browser_open` only when
  given; `browser_state_from_tool` for navigate / close / tool_call wrapper /
  error status / non-browser tool.
* `test_executor.py`: a completed `mcp__playwright__browser_navigate` tool
  event emits exactly one `browser_view opened` before the `tool` frame; a
  second one emits nothing; `browser_close` emits `closed`; replay after that
  reports `run_state.browser_open` accordingly.

## App (Dart, f5)

* `AgentsRelayRunState.browserOpen` (`bool?`, parsed from `browser_open`) —
  relay_client is 47's file: three additive lines, announced.
* `BrowserPresence`: `run_state` with `browserOpen != null` sets the value;
  `browser_view` `opened`/`closed` set it. Tool-frame derivation stays as
  the fallback for an old host.
* Tests in `browser_presence_test.dart`.

## Not in scope

No polling of the display, no new frame type, no change to `browser_start` /
`browser_stop` / `browser_data`.
