# cowork-manager

The CoWork **Manager** control plane (§5 of `docs/COWORK_AGENT_PLATFORM_PLAN.md`).
One host, many agents. This package is the control-plane skeleton; the real
container lifecycle wires to `../sandbox` later, and the real network relay wires
in behind the injected transport.

## Modules

- `roster` — SQLite agent registry (§5). CRUD + list, auto-assigned unique names.
- `names` — adjective-noun random-name generator.
- `supervisor` — `AgentSupervisor` interface + `StubSupervisor` (§5, §6). Per-agent
  sandbox lifecycle: `start` / `stop` / `status`.
- `scheduler` — `parse_schedule` + `Scheduler` + the 60s `Ticker` (§13).
  Interval / cron / timezone-anchored one-shot / one-shot-from-now. At-most-once
  firing on two axes: advance-before-exec under the scheduler lock, plus a
  claim/heartbeat lease so a long run is never dispatched twice and a crashed
  one is taken back. Hash-diff `monitor` mode produces a bounded unified diff.
- `autonomy` — unattended runs (§13). `UnattendedRunner` builds a fresh agent per
  fired job (`skip_memory` + `skip_background_review`, nobody is watching), kills
  a run on **inactivity** rather than wall-clock time, delivers the final answer
  to the origin chat and pushes a `Notification` — unless the answer is empty or
  marked `[SILENT]`. `JobDispatcher` carries the two cost levers: `script_action`
  (`no_agent`, zero tokens) and `monitor_action` (wake the model only on a byte
  change, with the diff in the prompt). `load_roster_schedules` turns roster rows
  into live jobs.
- `relay` — the frame contract (§14): newline-delimited JSON frames, `requestId`
  correlation, capability-descriptor handshake, Bearer-on-upgrade auth. Pure
  (de)serialization over an injected `Transport`.

## Develop

```bash
uv run pytest
```
