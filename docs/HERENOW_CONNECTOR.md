# here.now publishing connector

A first-class, approval-gated way for a coworker to put a file or a folder on the
public web and hand the user back a live URL. here.now (https://here.now) does
the hosting; Agents owns the tool, the two gates, and the consent round-trip.

This is the "publish this / host this / make a website" capability. It is built
the way an official connector is built: the model reaches it only through one
declared tool, and a public publish does not happen without the user's yes.

## Two gates

1. **Enablement gate — off by default.** The `herenow_publish` tool is
   registered only when the user turned the connector on in settings. The app
   forwards that setting on the task frame (`herenow: {enabled, approval}`),
   exactly like the UI-configured MCP servers (`mcp_servers`). A disabled or
   absent config registers no tool at all, so a run the user did not opt into
   has nothing about here.now in its prompt and no way to publish.

2. **Approval gate — a public publish needs a yes.** In the default `ask` mode,
   calling `herenow_publish` blocks the run: the executor emits an
   `approval_request` event, the app shows the user what would go out (path, file
   count, byte total, the URL is public), and the run does not publish until an
   `approval_decision` comes back. `auto` mode is the opt-in escape hatch for
   users who do not want to be asked each time. An unattended run (a cron job,
   no user present) in `ask` mode refuses — there is no one to approve.

## Free tier / 24h expiry

v1 uses the anonymous free tier: no API key, no account. An anonymous site is
**public** (anyone with the link can view) and **expires 24 hours** after it is
published. The tool states this in its own schema and in every result, and the
create response's `claimUrl` is passed back so the user can keep a site
permanently. The model is told to relay both facts to the user.

## Flow

```
model calls herenow_publish(path)
  -> [sandbox] scan the path: file count + byte total   (herenow.py PUBLISHER, MODE=scan)
  -> policy: auto? publish. ask? -> approval gate:
       executor emits  approval_request {approval_id, path, file_count, total_bytes, ...}
       worker thread BLOCKS on an Event (timeout 600s, cancelled by Stop/ESTOP)
       app shows Approve / Deny  -> approval_decision {approval_id, approved}
       serve thread resolves the Event
  -> approved -> [sandbox] publish: POST /api/v1/publish -> PUT each upload target
                 -> POST finalizeUrl {versionId}   (stdlib only, runs in the sandbox)
  -> return { url, public:true, anonymous:true, expires_at, claim_url, note }
```

The publisher is a small dependency-free Python program run **inside the
sandbox**, where the files and the network egress live. It speaks the public
three-step here.now flow directly (stdlib `urllib`), so it needs no `curl`/`jq`
and no here.now helper scripts baked into the image. Parameters cross as
environment variables, never interpolated into the script, and it prints exactly
one `HN_RESULT <json>` line.

## Layers touched

- **Agent** — `agent/src/chuk_agents_runtime/herenow.py`: `HereNowConfig`,
  `PublishRequest`, `ApprovalGate`, the embedded publisher, `herenow_publish`.
  `build_runtime(herenow_config=, herenow_gate=)` registers it only when enabled.
- **Executor** — `protocol.py`: `approval_request_payload` (executor→app event),
  `approval_decision` (inbound), `task_payload(herenow=)`.
  `executor.py`: a pending-approval registry (an `Event` per approval), a gate
  bound into `build_runtime` that emits the request and blocks the worker with a
  timeout and a kill-switch cancel, and `_resolve_approval` on the serve thread.
- **App (Flutter)** — a `HereNowStore` (enabled + approval mode), a settings
  screen to toggle it, the config forwarded on the task frame in
  `agents_relay_client`, and an inbound `approval_request` → Approve/Deny UI →
  `approval_decision` reply.
- **Host** — none. The host is a blind forwarder; `approval_decision` rides the
  same app→executor submit path as `stop` and `browser_*`.

## Wire format

Task frame (additive, sealed):

```json
{"type": "task", "prompt": "...", "session_key": "...",
 "herenow": {"enabled": true, "approval": "ask"}}
```

Approval round-trip (sealed, correlated by `approval_id`):

```json
// executor -> app
{"type": "approval_request", "approval_id": "ap-1", "action": "herenow_publish",
 "path": "site", "name": "My Page", "file_count": 2, "total_bytes": 1024,
 "base_url": "https://here.now", "public": true}
// app -> executor
{"type": "approval_decision", "approval_id": "ap-1", "approved": true}
```

## Honest boundary

The approval gate governs *this tool*. A sandbox has a shell and a network, so a
determined model could POST to here.now itself and skip the gate — true of any
connector in any agent product. The guarantee is product-level: the sanctioned,
always-present here.now capability is gated, and when the connector is off,
nothing about here.now is in the prompt. The tool text tells the model to
publish only through the tool. If we later want to make the bypass materially
harder, the sandbox egress allowlist is the lever, not the tool.

## Later

- Authenticated / permanent sites (an account + saved API key), private and
  password-protected access, custom domains, workspaces — all supported by the
  here.now API and the global `here-now` skill, out of scope for v1's free-tier
  focus.
- On-demand loading of the fuller here.now procedure as a config-gated skill
  (today the essential rules live in the tool schema, which is enough).
