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
- `scheduler` — `parse_schedule` + in-process ticker (§13). Interval / cron /
  timezone-anchored one-shot / one-shot-from-now. At-most-once firing
  (advance-before-exec). `no_agent` and hash-diff `monitor` cost modes.
- `relay` — the frame contract (§14): newline-delimited JSON frames, `requestId`
  correlation, capability-descriptor handshake, Bearer-on-upgrade auth. Pure
  (de)serialization over an injected `Transport`.

## Develop

```bash
uv run pytest
```
