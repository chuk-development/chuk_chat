# CoWork

A team of persistent, sandboxed AI coworkers you message tasks to. See the full
plan in [`docs/COWORK_AGENT_PLATFORM_PLAN.md`](docs/COWORK_AGENT_PLATFORM_PLAN.md).

This is a new codebase, separate from `chuk_chat` (merged later). Layout:

| Dir | What |
|-----|------|
| `agent/` | The Python agent runtime — the loop, tools, state, model client. |
| `sandbox/` | Per-agent execution sandbox: `BaseEnvironment` ABC + backends. |
| `manager/` | The host control plane — roster, lifecycle, scheduler, relay bridge. |
| `common/` | Shared code — the E2E CoWork frame crypto (Python twin of the Dart). |
| `app/` | The Flutter controller app (messenger/roster UI). |
| `docs/` | The plan. |

Python: 3.12, managed with `uv`, tested with `pytest`. Flutter for `app/`.

Status: foundation build in progress.
