# Fly.io Sprites: implementation reference

Read on 2026-11-03. We have no API key yet, so nothing here is tested
against the live API. Every fact has a source. Facts that come only from
SDK source code (not from the docs) carry the tag **[SDK only]**. Facts
that two sources state differently carry the tag **[CONFLICT]**.

Raw downloads: `_scratch/sprites/` (gitignored). The two OpenAPI files
differ. Use the live one:

- Docs copy: `https://docs.fly.io/sprites/api/openapi.json` (API 0.1.12,
  sprite-env 0.0.2).
- Live copy: `https://api.sprites.dev/openapi.json` (API 0.1.12, sprite-env
  0.0.4). Only the live copy has the usage endpoints and the `services`
  field on a Sprite.
- WebSocket spec: `https://docs.fly.io/sprites/api/asyncapi.json`
  (sprite-env schema `v0.0.1-rc48`).
- SDK versions read: `sprites-py` 0.7.2 (PyPI), `@fly/sprites` 0.2.4 (npm),
  `github.com/superfly/sprites-go` (main branch, shallow clone).

Doc base: `https://docs.fly.io/sprites/` (all pages are in
`https://docs.fly.io/llms-full.txt`). Old doc host `docs.sprites.dev` is
the same content.

---

## 0. Facts for our design (short form)

- A Sprite is a KVM microVM that runs on Fly Machines. User code runs
  in an inner container, not in the VM root namespace. There is no
  systemd. (Blog `https://fly.io/blog/design-and-implementation/`,
  Services page.)
- 8 vCPU fixed. Memory starts at 2 GB and autoscales to 16 GB. Disk is
  100 GB, sparse, billed on bytes written.
- Idle window about 30 s. Then **warm** (VM suspended, RAM kept, wake
  100-500 ms). Later **cold** (RAM dropped, wake 1-2 s).
- **All open TCP connections drop on any pause**, warm or cold. An
  outbound websocket dies on pause. Only a **Task** (a hold of max 1 h,
  renewable) stops the pause.
- Billing: CPU $0.0385/CPU-hour (cpu.stat), memory $0.021875/GB-hour, hot
  storage $0.000683/GB-hour while awake, cold storage $0.000027/GB-hour
  always. No egress charge today.
- Per-Sprite usage API exists: `GET /v1/usage/{sprite}` returns
  `cpu_time_sec` and `reserved_memory_byte_sec`. It does not return
  storage.
- Region: the docs say nothing. The SDKs send `config.region` (example
  `ord`) and read `primary_region`. Not verified.
- Docker in a Sprite: the docs say nothing.

---

## 1. Authentication

Sources: `https://docs.fly.io/sprites/cli/authentication`,
`https://fly.io/auth.md`, asyncapi `info.description`, release notes
`https://fly.io/sprites/release-notes/`, SDK `client.py` /
`client.go` / `client.js`.

### 1.1 Token type

- A Sprites token is separate from a Fly.io token. A Fly.io token does
  not work on the Sprites API. (`fly.io/auth.md`)
- Header on every REST and WebSocket call:
  `Authorization: Bearer <token>`.
- Token format, as the docs write it:
  - CLI and Claude Managed Agents page: `org-slug/org-id/token-id/token-value`.
  - CLI auth page example: `my-org/token-id/secret`.
  - AsyncAPI: `<org>/<id>/<secret>`.
  **[CONFLICT]** Store the token as one opaque string. Do not parse it.
- Wrong or missing token on the REST API: `401 {"error":"authentication failed"}`.
- A token is scoped to **one organization**. The org slug is part of the
  token.

### 1.2 How to create a token

- Dashboard: `https://sprites.dev/account` or
  `https://fly.io/dashboard/<org-slug>/sprites/tokens`.
- CLI: `sprite login` (browser), then `sprite org auth --org <org>` per org.
  `sprite auth setup --token "<token>"` stores a token without a browser.
- API **[SDK only]**: `POST https://api.sprites.dev/v1/organizations/{org_slug}/tokens`
  - Header: `Authorization: FlyV1 <fly macaroon>` (a Fly.io token, the
    full `fm2_...` value).
  - Body: `{"description": "Sprite SDK Token", "invite_code": "<optional>"}`.
  - Response 200 or 201: `{"token": "<sprites token>"}`.
  - The Go SDK forces HTTP/1.1 for this call. The Fly edge rejects HTTP/2
    headers over 16 KB.
  - The SDKs send no restriction fields here. We do not know if the
    endpoint accepts them.

### 1.3 Restrictions (scopes)

- Release note 2026-02-02: tokens can have a **maximum Sprite count**, a
  **required name prefix**, **label-based access control** and an
  **expiry date**.
- The MCP OAuth consent screen creates a restricted token: default name
  prefix `mcp-`, a capped Sprite count, or "full access".
  (`https://docs.fly.io/sprites/integrations/remote-mcp`)
- MCP OAuth scopes: `sprites:read`, `sprites:write`. PKCE `S256`. Refresh
  token grant supported. (`fly.io/auth.md`)
- Usage API needs `usage.read` or "full access without sprite
  restrictions" (live OpenAPI, 403 text).
- Managed connector balance and custom API connectors need an
  unrestricted / full-access token (live OpenAPI, 403 text).
- The docs do not document how to create a restricted token through the
  API.

### 1.4 Environment variables

| Variable | Where | Meaning |
| --- | --- | --- |
| `SPRITE_TOKEN` | CLI, SDK examples | API token (CLI calls it legacy) |
| `SPRITES_TOKEN`, `SPRITES_API_TOKEN`, `SPRITES_API_KEY` | various plugins | same token, name depends on the tool |
| `SPRITES_API_URL` | CLI | default `https://api.sprites.dev` |
| `SPRITE_ORG` | CLI | override the default org |
| `SPRITE_URL` | CLI | direct Sprite URL for local/dev |
| `SPRITES_CLIENT_SIGNALS` | all SDKs | set `0` to stop the SDK telemetry headers (see 8.4) |

---

## 2. REST and WebSocket API

Base URL: `https://api.sprites.dev`. WebSocket base: `wss://api.sprites.dev`.
Source for every endpoint in this section: live OpenAPI
`https://api.sprites.dev/openapi.json` and AsyncAPI, unless a tag says
otherwise.

### 2.1 Errors (all endpoints)

Source: OpenAPI responses, Go SDK `errors.go`.

- Status codes in the spec: 400 bad request, 401 auth, 403 restricted
  token, 404 not found, 409 conflict, 413 payload too large, 422 too many
  results / cannot store, 429 rate limit, 500, 502.
- Structured error body **[SDK only]**:
  ```json
  {
    "error": "sprite_creation_rate_limited",
    "message": "...",
    "errors": ["..."],
    "limit": 10,
    "window_seconds": 60,
    "retry_after_seconds": 12,
    "current_count": 100,
    "upgrade_available": true,
    "upgrade_url": "https://..."
  }
  ```
- Known `error` codes: `sprite_creation_rate_limited`,
  `concurrent_sprite_limit_exceeded`. Text at the limit:
  `max sprites per org exceeded`.
- Response headers read by the SDK: `Retry-After`, `X-RateLimit-Limit`,
  `X-RateLimit-Remaining`, `X-RateLimit-Reset` (Unix time),
  `Fly-Request-Id` (correlation id for support).
- NDJSON stream errors: `{"type":"error","error":"...","code":"...","time":"..."}`.
  `code` is empty when unclassified.

### 2.2 Sprites

#### `POST /v1/sprites` - create

Request body. Documented fields (OpenAPI):

| Field | Type | Notes |
| --- | --- | --- |
| `name` * | string | unique in the org |
| `url_settings.auth` | `sprite` \| `public` | default `sprite` |

Extra fields that the SDKs send **[SDK only]**:

| Field | Type | Notes |
| --- | --- | --- |
| `url_settings.private_access` | `admins` \| `org_users` | who may open a private URL. Default admin-only (release note 2026-04-21) |
| `labels` | string[] | used by connector policies and token restrictions |
| `wait_for_capacity` | bool | wait for capacity instead of failing. Used by the Fly docs example (Claude Managed Agents page) |
| `runtime` | `default` \| `dev` | runtime variant |
| `config.ram_mb` | int | JS README example: 512 |
| `config.cpus` | int | JS README example: 1 |
| `config.region` | string | JS README example: `ord` |
| `config.storage_gb` | int | |
| `environment` | map | Go and JS only |

The docs say "you don't set or resize these yourself" (Lifecycle page).
So `config` may be ignored. **[CONFLICT]**

Responses: `201` Sprite object, `400`, `401`. In practice also `409` when
the name exists (Claude Managed Agents example accepts 200/201/409) and
`429` at the rate limit. SDK timeout for create: 120 s.

Name rules: **not documented**. The Fly example builds names as
lowercase, `_` replaced with `-`, at most 40 chars after the prefix
("DNS-label-safe"). The name appears in the URL
`https://<name>-<org-id>.sprites.app`, so use `[a-z0-9-]`, start with a
letter, keep it short.

The marketing page and `agent-ready.md` show `PUT /v1/sprites/{name}` to
create. The OpenAPI has no such create route; `PUT /v1/sprites/{name}` is
"update". **[CONFLICT]** Use `POST /v1/sprites`.

Image / template choice: **none**. Every Sprite starts from one standard
image (blog: "they all run from a standard container"). No custom image.

#### Sprite object (`SpriteResponse`)

| Field | Type | Notes |
| --- | --- | --- |
| `id` * | string | `sprite-01234567-89ab-...` |
| `name` * | string | |
| `organization` * | string | org slug |
| `url` * | string | `https://<name>-<random>.sprites.app` |
| `status` * | `cold` \| `warm` \| `running` | |
| `created_at` *, `updated_at` * | ISO 8601 | |
| `last_running_at` | ISO 8601 \| null | last time seen running |
| `last_warming_at` | ISO 8601 \| null | last time seen warming |
| `labels` | string[] | omitted when empty |
| `url_settings` | `{auth}` \| null | |
| `version` | string \| null | runtime version, e.g. `v0.0.1-rc48` |
| `environment_version` | string \| null | base image version |
| `services` | object | live spec only, "compute-provider sprites only", see 2.7 |
| `primary_region`, `bucket_name`, `config`, `environment` | | **[SDK only]**, the SDK reads them "when returned" |

#### `GET /v1/sprites` - list

Query: `prefix`, `max_results` (1-500, default 50), `continuation_token`.
SDK also sends `bulk_load=true` **[SDK only]**.
With header `Accept: application/x-ndjson` the call streams live state
events **[SDK only, JS `watchSprites`]**.

Response:
```json
{
  "name": "my-org",
  "sprites": [ SpriteResponse ],
  "has_more": true,
  "next_continuation_token": "...",
  "running": 1, "warm": 2, "cold": 3,
  "running_limit": 10,
  "warm_limit": 10
}
```
`running_limit` and `warm_limit` are the org-wide limits. Read them here.

#### `GET /v1/sprites/{name}` - get

`200` Sprite object, `401`, `404`. A GET does not wake the Sprite (it only
reads the control plane; not stated, but the fields are control-plane
fields).

#### `PUT /v1/sprites/{name}` - update

Body: `{"url_settings": {"auth": "sprite"|"public", "private_access": "..."}}`.
SDKs also send `labels` (replace), Go sends `clear_labels: true`.
Partial update: omitted fields stay. `200` Sprite object, `400`, `401`, `404`.

#### `DELETE /v1/sprites/{name}` - delete

`204`, `401`, `404`. Deletes the disk and all checkpoints. No undo for
the customer (Fly admins can restore from the backup bucket, release
note 2026-04-16). Usage records stay readable after delete (usage API).

#### Other Sprite routes **[SDK only]**

| Route | Body / response |
| --- | --- |
| `POST /v1/sprites/{name}/upgrade` | body `{"allow_storage_migration": true, "version": "..."}` optional; streams progress; `upgrade_type: "all"` also updates the base image (release note 2026-02-02) |
| `POST /v1/sprites/{name}/restart` | response `{sprite_name, machine_id, message}` |
| `GET /v1/sprites/{name}/check` | response `{sprite_name, sprite_id, status, reason, checked_at, elapsed}` |

### 2.3 Exec

#### `POST /v1/sprites/{name}/exec` - HTTP exec (no TTY)

Query parameters:

| Param | Type | Notes |
| --- | --- | --- |
| `cmd` * | string, repeat | first value is the program, the rest are args |
| `path` | string | explicit executable, default first `cmd` or `bash` |
| `stdin` | bool | default false. True = request body is stdin |
| `env` | `KEY=VALUE`, repeat | |
| `dir` | string | working directory |

Body: `application/octet-stream`, stdin, max **10 MiB** (413 above).

Response 200: a byte stream of frames. Each read starts with a stream
byte: `0x01` stdout, `0x02` stderr. The body ends with `0x03 <exit code
byte>`. Frames have no length prefix. (Claude Managed Agents example, JS
`execFileHTTP`.)

Timeout: **not documented**. The Fly example uses a client timeout of
300 s for `pip install`. An exec that writes to stdout keeps the Sprite
active.

#### `wss://.../v1/sprites/{name}/exec` - WebSocket exec

Query parameters (AsyncAPI names only `max_run_after_disconnect`; the
rest come from the SDKs):

| Param | Notes |
| --- | --- |
| `cmd` (repeat), `path` | as HTTP exec |
| `env` (repeat), `dir` | as HTTP exec |
| `tty=true`, `rows`, `cols` | TTY mode |
| `stdin=true\|false` | expect input frames |
| `detachable=true` | create a detachable (tmux) session **[SDK only]** |
| `cc=true` | control mode, needs detachable or a session id **[SDK only]** |
| `output_offset=<n>` | resume output on attach **[Go SDK only]** |
| `max_run_after_disconnect=<duration>` | e.g. `30s`. How long the command runs after the client disconnects. Default not documented |
| `id=<session>` | legacy attach form **[Go SDK only]** |

Behaviour: "Commands continue running after disconnect" (AsyncAPI).
Upgrade returns `101`.

Binary frames, first byte = stream: `0x00` stdin, `0x01` stdout, `0x02`
stderr, `0x03` exit code (1 byte), `0x04` stdin EOF.

JSON messages:
- client to server: `{"type":"resize","cols":180,"rows":50}`
- server to client: `{"type":"session_info","session_id":"1847","command":"bash","created":1767609000,"cols":120,"rows":40,"is_owner":true,"tty":true}`
- server to client: `{"type":"exit","exit_code":0}`
- server to client: `{"type":"port_opened"|"port_closed","port":3000,"address":"https://...:3000","pid":1847}`

SDK keepalive: ping every 15 s, pong wait 45 s, max message 10 MB. The
server holds the socket about 5 s after the exit frame.

#### `wss://.../v1/sprites/{name}/exec/{session_id}` - attach

Messages: resize, session_info, exit.

#### `GET /v1/sprites/{name}/exec` - list sessions

```json
{"count": 2, "error": "only when session manager is down",
 "sessions": [{"id": 1847, "command": "bash", "created": "...", "workdir": "/home/sprite/x",
               "tty": true, "is_active": true, "bytes_per_second": 125.5, "last_activity": "..."}]}
```

#### `POST /v1/sprites/{name}/exec/{session_id}/kill`

Query: `signal` (default `SIGTERM`), `timeout` (default `10s`). NDJSON:
`{"type":"signal","pid":..,"signal":"SIGTERM","message":".."}`, then
`exited` / `killed` / `timeout` / `error`, then
`{"type":"complete","exit_code":0}`.

#### `wss://.../v1/sprites/{name}/control` - control channel

One socket, many operations in sequence (exec, proxy, fs). Text frame
`control:{"type":"op.start","op":"exec","args":{"cmd":[..],"env":["K=V"],"dir":"..","tty":"true","rows":"24","cols":"80","stdin":"true"}}`.
Server answers `control:{"type":"op.complete","args":{"exitCode":0}}` or
`control:{"type":"op.error","args":{"error":".."}}`. Data frames between
them use the exec framing. **[SDK only]** for the frame shape. Go SDK
also runs fs operations over this channel (`fs` ops with args `path`,
`workingDir`, `start`, `end`, `mode`, `mkdirParents`, `asRoot`,
`recursive`, `uid`, `gid`).

### 2.4 Filesystem

All take path `{name}`. `workingDir` is **required** on read, write and
list ("workingDir is required by the fs endpoints", Fly example).

| Method, path | Input | Output |
| --- | --- | --- |
| `GET /fs/read` | query `path`*, `workingDir`* | raw bytes |
| `PUT /fs/write` | query `path`*, `workingDir`*, `mode` (octal `0644`), `mkdir` (bool); body raw bytes, max **16 MiB** (413) | `{path, size, mode}` |
| `GET /fs/list` | query `path`*, `workingDir`* | `{path, count, entries:[{name,path,type,size,mode,modTime,isDir}]}` |
| `DELETE /fs/delete` | JSON `{path, workingDir, recursive, asRoot}` | `{count, deleted:[..]}` |
| `POST /fs/rename` | JSON `{source, dest, workingDir, asRoot}` | `{source, dest}` |
| `POST /fs/copy` | JSON `{source, dest, workingDir, recursive, preserveAttrs, asRoot}` | `{count, totalBytes, copied:[{source,dest}]}` |
| `POST /fs/chmod` | JSON `{path, mode, workingDir, recursive, asRoot}` | `{count, affected:[{path,mode}]}` |
| `POST /fs/chown` | JSON `{path, uid, gid, workingDir, recursive, asRoot}` | `{count, affected:[{path,uid,gid}]}` |
| `wss /fs/watch` | message `{type, paths[], recursive, workingDir}` | events `{type, path, event, timestamp, size, isDir, message}` |

All prefixes are `/v1/sprites/{name}`. Errors: 400, 404, 500.
CLI: `sprite exec --file <source:dest>` uploads before exec.

### 2.5 Services (process supervisor)

Path prefix `/v1/sprites/{name}/services`.

| Method, path | Notes |
| --- | --- |
| `GET /services` | array of service + state |
| `GET /services/{svc}` | one service |
| `PUT /services/{svc}?duration=5s` | create or update. Body `{cmd*, args*[], needs*[], dir, env:{K:V}, http_port}`. Streams NDJSON for `duration` (default 5 s) |
| `GET /services/{svc}/logs?lines=N&duration=0` | NDJSON log lines, `duration` = follow time |
| `POST /services/{svc}/start?duration=5s` | NDJSON |
| `POST /services/{svc}/stop?timeout=10s` | NDJSON. Stop is sticky |
| `POST /services/{svc}/restart?duration=5s` | NDJSON |
| `DELETE /services/{svc}` | **[SDK only]** |
| `POST /services/signal` body `{name, signal}` | **[SDK only]**. 409 if not running, 400 bad signal |

Service state: `{name, status: stopped|starting|running|stopping|failed, pid, started_at, error}`;
CLI `get` also shows `restart_count`.

NDJSON event types: `started`, `stdout`, `stderr`, `exit` (`exit_code`),
`error`, `stopping`, `stopped`, `complete` (`log_files`). Timestamps are
Unix ms.

Rules (Services page):
- Only one service can have `http_port`. A second one: `409: another
  service already has an HTTP port configured`.
- With `http_port`, the Sprite URL routes to that port, and a request
  starts the service if it is not running. Without it, the URL routes to
  port 8080 ("or first HTTP port opened", Working with Sprites).
- Crash or kill (TERM/KILL) = restart, `restart_count` goes up. `stop` =
  stays stopped. `delete` keeps the log file.
- Logs: `/.sprite/logs/services/<name>.log`.
- `needs` sets start order on cold boot.
- In the Sprite: `sprite-env services create web --cmd python3 --args "-m,http.server,3000" --http-port 3000 --env "K=v" --dir /x --needs db`.

### 2.6 Checkpoints

| Method, path | Notes |
| --- | --- |
| `POST /v1/sprites/{name}/checkpoint` | body `{"comment": ".."}`. NDJSON: `info` lines, then `{"type":"complete","data":"Checkpoint v8 created"}` |
| `GET /v1/sprites/{name}/checkpoints` | array `{id, create_time, comment, source_id, health}`. `health` empty = ok, `mount_failed` = bad. SDK sends `history=<filter>` |
| `GET /v1/sprites/{name}/checkpoints/{id}` | one checkpoint |
| `POST /v1/sprites/{name}/checkpoints/{id}/restore` | NDJSON; ends `{"type":"complete","data":"Restored to v5"}` |
| delete | **not in the REST spec**. CLI has `sprite checkpoint delete <id>` |

Facts (Checkpoints page):
- IDs `v0`, `v1`, ... Automatic ones have `auto-` ids, hidden unless
  `--include-auto`. Older auto ones are pruned.
- Captures the writable overlay (files, packages, on-disk DBs). Not
  processes, not RAM, not connections.
- Restore replaces the overlay, restarts the environment, ends sessions.
  The state you replace is lost. Services come back from their
  definitions.
- The last 5 checkpoints are mounted read-only at `/.sprite/checkpoints/vN/`.
- You cannot delete the checkpoint you are on.
- Copy-on-write, stored in object storage, you pay for blocks kept.
- Speed: "about a second" (marketing), "10-30 seconds" (Working with
  Sprites). The create stream example shows "Stopping services...".
  **[CONFLICT]**
- In the Sprite: `sprite-env checkpoints create|list|restore`, or
  `curl --unix-socket /.sprite/api.sock http://sprite/v1/checkpoints`.

### 2.7 URL, URL auth and service endpoints

Sources: Networking page, CLI `sprite url`, release notes, live OpenAPI.

- URL: `https://<sprite-name>-<org-id>.sprites.app/`. `<org-id>` is a
  short generated id, not the org name. Read it from `url` in the Sprite
  object.
- HTTPS only. One HTTP port per Sprite.
- `url_settings.auth`:
  - `sprite` (default): org members in a browser (Fly login), or
    `Authorization: Bearer <sprites org token>` from code.
  - `public`: no auth.
- `private_access`: default admin-only; can be set to all org members
  (release note 2026-04-21). Values in the JS SDK: `admins`, `org_users`.
- **How our server calls a private Sprite URL:**
  `curl -H "Authorization: Bearer $SPRITES_TOKEN" https://<name>-<org-id>.sprites.app/path`
  (CLI help). Not stated: whether the bearer header is passed on to the
  app, and whether a restricted token works here.
- A request to a stopped Sprite starts it and waits up to **10 s**
  before it answers (release note 2026-02-02).
- Live OpenAPI, undocumented feature: the Sprite object has `services`
  with per-service endpoints, `public_url`
  (`https://api--my-sprite--default--my-org.sprites.app`), `internal_url`
  (`http://api--my-sprite--default.sprite.internal`, Sprite to Sprite in
  the org), `exposure` (`public` / `authenticated` / `internal`) and
  `grants`. "Compute-provider sprites only". No docs.
- TCP to any port: `wss://.../v1/sprites/{name}/proxy`. First message
  `{"host":"localhost","port":5432}`, then raw bytes. Not on the public
  Internet.
- Port events: `wss://.../v1/sprites/{name}/ports/watch` sends
  `{"type":"port_list","ports":[..]}`, then `port_opened` / `port_closed`.

### 2.8 Policies

#### Network (egress)

- `GET /v1/sprites/{name}/policy/network` returns `{"rules":[..]}`.
- `POST /v1/sprites/{name}/policy/network` body `{"rules":[..]}`.
- Rule: `{"domain":"github.com","action":"allow"|"deny"}` or
  `{"include":"defaults"}`.
- `defaults` = common dev domains (GitHub, npm, PyPI, Docker Hub, major AI
  APIs). The full list is not published.
- Match: exact host beats `*.host` beats `*`.
- `{"rules": []}` = no enforcement. Default for a new Sprite = no
  restriction.
- When enforced: blocked names get DNS `REFUSED`; raw IPs are blocked
  unless resolved from an allowed name; private IP ranges are always
  blocked; changes load live and drop connections to newly blocked names.
- Read-only inside the Sprite at `/.sprite/policy/network.json`. Only the
  API can change it.

#### Privileges

- `GET|POST|DELETE /v1/sprites/{name}/policy/privileges`.
- Body `{"profile": "minimal"|"standard"|"privileged", "devices": ["..."], "noNewPrivileges": true}`.
- Empty profile = unrestricted. DELETE = back to unrestricted.
- No docs say what each profile allows.

#### Resources (memory cap)

- `GET|POST|DELETE /v1/sprites/{name}/policy/resources`.
- Body `{"memory": {"limit_mb": 2048, "autoscale": false}}` or
  `{"memory": null}`.
- `autoscale` "default: false" (schema text). The Lifecycle page says
  memory autoscales by default. **[CONFLICT]**
- This is the only per-Sprite resource cap in the API. There is no CPU
  cap.

### 2.9 Usage (live spec only)

| Route | Query |
| --- | --- |
| `GET /v1/usage` | `start`* ISO 8601, `end` (default now), `interval` (`1h`, `auto`, min `1s`; omit = one total), `group_by=sprite` |
| `GET /v1/usage/{sprite}` | `start`*, `end`, `interval`, `cluster_id` (default `default`) |
| `GET /v1/usage/filters/sprites` | `start`*, `end`; returns `{start, end, sprite_refs: ["default/demo", ..]}` incl. deleted Sprites |

Response:
```json
{
  "start": "...", "end": "...", "interval": "1h" ,
  "partial": false,
  "usage": [{
    "start": "...", "end": "...",
    "sprite_ref": "default/demo",
    "cpu_time_sec": 123.45,
    "reserved_memory_byte_sec": 3865470566400.0,
    "last_recorded_at": "..."
  }]
}
```
- `partial: true` = missing minute records; totals may be low.
- Errors: 403 (needs `usage.read` or full access), 404, 422 (too many
  buckets, choose a larger interval), 502.
- Includes deleted Sprites with retained usage.
- No storage field and no network field.

### 2.10 Connectors (credential gateway)

Source: `https://docs.fly.io/sprites/concepts/connectors`, OpenAPI.

- Gateway: `https://api.sprites.dev/v1/gateway/<provider>/<connection_id>/<path>`.
  The Sprite calls it with no `Authorization` header. The gateway knows
  the Sprite from Fly's request signature. Calls from outside a Sprite
  get 401.
- `GET https://api.sprites.dev/v1/gateway/list` (from inside a Sprite)
  lists connected and available providers.
- Policy (deny by default): `{allow_all, name_prefix, sprite_labels[] (all
  required), allowed_endpoints[], blocked_endpoints[]}`. Block wins.
  Patterns: exact path or trailing `*`.
- Management: `GET /v1/oauth/connections?provider=`,
  `GET|PUT|PATCH|DELETE /v1/oauth/connections/{id}`,
  `POST /v1/oauth/connections/api_key` `{provider, api_key, base_api_url, access_policy}`,
  `POST /v1/oauth/connections/provision` `{provider}` (managed, e.g.
  `openrouter`, billed on the Sprites bill),
  `GET /v1/oauth/{provider}/authorize?scopes=&add_scopes=&redirect_uri=&state=`
  returns `{authorize_url, state}`,
  `POST /v1/oauth/{provider}/callback`,
  live only: `POST /v1/oauth/connections/custom_api` (any token API:
  `name`*, `base_api_url`*, `access_token`*, `auth_method`
  `header|url_path|query_param|custom_header`, ...),
  `PUT /v1/oauth/connections/custom_api/{id}`,
  `POST /v1/oauth/connections/custom_api/test`,
  `GET /v1/oauth/connections/{id}/usage`,
  `GET /v1/oauth/connections/{id}/balance` (managed OpenRouter:
  `{usage_usd, limit_usd, remaining_usd, disabled, key_hash}`).
- Custom API connectors need a full-access token (403 otherwise).

### 2.11 Tasks API (inside the Sprite only)

Source: `https://docs.fly.io/sprites/keeping-sprites-running`.
HTTP/JSON on the Unix socket `/.sprite/api.sock`, virtual host `sprite`.
Shorthand: `sprite-env curl -X POST /v1/tasks -d '...'`.

| Call | Body | Result |
| --- | --- | --- |
| `GET /v1/tasks` | | `{"tasks":[{"name","started_at","expires_at"}]}` |
| `GET /v1/tasks/:name` | | 200 / 404 |
| `POST /v1/tasks` | `{"name":"agent","expire":"1h"}` | 201, 409 if the name exists |
| `PUT /v1/tasks/:name` | `{"expire":"5m"}` | 200, create or refresh |
| `PUT /v1/tasks` | `{"name":"..","expire":".."}` | 200 |
| `DELETE /v1/tasks/:name` | | 204 / 404 |

- `expire`: integer seconds or `"30m"`, `"1h"`. **Max 1 hour** per call.
- While one task is live, the Sprite does not pause.
- Recommended heartbeat: `expire` 5 m, refresh every 60 s, delete on exit.
- The REST API outside the Sprite has no tasks endpoint.

Other socket routes: `GET /v1/checkpoints`, `POST /v1/checkpoint`.
Agent reference inside the Sprite: `/.sprite/llm.txt`.

### 2.12 Remote MCP

`https://sprites.dev/mcp` (not the API host). OAuth only. Tools:
`list_sprites`, `create_sprite`, `destroy_sprite`, plus generated
Sprite tools (exec, checkpoints, network policy, services, logs).

---

## 3. Lifecycle

Sources: `https://docs.fly.io/sprites/concepts/lifecycle`,
`https://docs.fly.io/sprites/working-with-sprites`,
`https://docs.fly.io/sprites/keeping-sprites-running`, FAQ on
`https://fly.io/sprites`.

### 3.1 States

| State | Compute billed | RAM | Processes | Wake time |
| --- | --- | --- | --- | --- |
| `running` | yes | live | live | - |
| `warm` | no | frozen in place | frozen, resume mid-run | 100-500 ms |
| `cold` | no | dropped | gone; services start fresh | 1-2 s |

- Idle window before pause: "about 30 seconds today". The FAQ says
  "within seconds".
- Running to warm is automatic. Warm to cold "if it stays idle long
  enough". **The warm-to-cold time is not published.** We cannot choose
  the state and cannot see the transition (only `status` and
  `last_warming_at`).

### 3.2 What counts as activity

FAQ list (four things reset the idle timer):
1. An in-flight HTTP or API request.
2. Output to stdout of a session or exec'd process. Output redirected to
   a file does not count. A detached tmux does not count.
3. An open TCP connection.
4. An active task.

Working with Sprites list: active exec/console commands, open TCP
connections ("like your app's URL"), running TTY sessions, active
services with open connections.

- A quiet service does **not** keep the Sprite up.
- It is not clear if an **outbound** TCP connection counts as activity.
  The Tasks page says outbound websockets need a task. Plan for: it does
  not count.

### 3.3 What survives

- Disk: everything (ext4, files, packages, SQLite, git). `/tmp` "treat as
  scratch".
- Config: URL settings, services, network policy.
- RAM and processes: survive **warm** only.
- Open TCP connections: **drop on every pause**, warm and cold. "The
  remote end can't be held across the suspension." Clients must
  reconnect.
- TTY sessions and `sprite exec` processes stop when the Sprite sleeps
  (Working with Sprites). On a warm pause they are frozen, not ended
  (Lifecycle). **[CONFLICT]** in wording; plan for "gone".

### 3.4 Services on wake

- Warm wake: the service process resumes; no restart.
- Cold boot: the runtime starts all services in `needs` order.
- Crash: restart. Stop: stays stopped.
- A request to the URL starts the `http_port` service if it is down.

### 3.5 Waking a Sprite from our server

- Any exec, fs, service, checkpoint or proxy call wakes it. The CLI docs:
  "Each check starts the Sprite if it isn't already running, so this
  takes a few seconds per Sprite."
- An HTTP request to the Sprite URL wakes it; a stopped Sprite gets up to
  10 s to answer.
- There is no explicit "start" or "wake" REST call in the spec.
  `POST /v1/sprites/{name}/restart` exists in the JS SDK only.
- MCP note: "Cold Sprites can take a moment to wake. If the client
  receives a retry message, wait a few seconds and run the same tool
  again." So: retry with back-off on the first call.

---

## 4. Resources

Sources: Lifecycle page, release notes 2026-01-06 and 2026-03-25,
Working with Sprites, Sprite Maintenance, blog.

| Item | Value |
| --- | --- |
| vCPU | 8, fixed ("you don't set or resize") |
| RAM | start 2 GB, autoscale to 16 GB (release note 2026-03-25). Older docs: 8 GB max. The figure inside the VM is "adjusted", not a hard limit |
| RAM cap per Sprite | `POST /policy/resources` `{"memory":{"limit_mb":N,"autoscale":bool}}` |
| CPU cap per Sprite | none in the API |
| Disk | 100 GB, sparse, TRIM-friendly, no autoscale. NVMe cache in front of object storage (JuiceFS-like, Litestream metadata). Newer `sbd` backend ("S3 Block Device", ext4 on an object-store block device), check with `echo $SPRITE_STORAGE_DRIVER` |
| OS | Ubuntu 26.04 for new Sprites (Maintenance page). Working with Sprites still says 25.10. **[CONFLICT]** |
| Preinstalled | Node.js, Python, Go, Ruby, Rust, Elixir, Java, Bun, Deno, Git, curl, vim; Claude CLI, Gemini CLI, Codex, Cursor; `sprite-env`; skill `sprite-api-gateway` |
| Home | `/home/sprite` (user `sprite`), root via `sudo` |
| Init | no systemd, no `journalctl`. Use services |
| Custom image | **no**. One standard base image for all |
| Docker / podman | **not documented** |
| Nested containers | not documented. User code already runs in an inner container |
| `/dev/kvm` | not documented |
| GPU | not documented; nothing suggests GPUs |
| Desktop | possible: the Cursor integration installs Xfce and Chrome for computer use |

---

## 5. Regions

- Docs: **no mention** of regions for Sprites.
- SDKs: `config.region` on create (JS README example `ord`), and
  `primary_region` on the Sprite object. **[SDK only]**, not in OpenAPI.
- Fly regions in Europe (Machines): `ams`, `arn`, `cdg`, `lhr`, `fra`
  (`https://fly.io/pricing.md`). Not confirmed for Sprites.
- Storage root is object storage. Its location is not stated.
- Sprite pricing has no region multiplier (Machines have one).
- Usage API `sprite_ref` is `<cluster>/<name>`, e.g. `default/demo`;
  `cluster_id` defaults to `default`. The meaning of "cluster" is not
  documented.

---

## 6. Limits and quotas

Sources: FAQ on `https://fly.io/sprites`, list response fields, release
notes 2026-01-22 and 2026-02-24, `https://fly.io/pricing.md`.

| Limit | Value |
| --- | --- |
| Concurrent running, warm | per org, by plan. Hero: 100 running, 100 warm. Read `running_limit`, `warm_limit` from `GET /v1/sprites` |
| Cold Sprites | unlimited |
| Creation rate | pay-as-you-go 10/min; Adventurer 60/min; up to Mythic 240/min |
| Error at limit | `max sprites per org exceeded`, codes `concurrent_sprite_limit_exceeded`, `sprite_creation_rate_limited`, HTTP 429 with `Retry-After` |
| HTTP exec stdin | 10 MiB |
| fs write | 16 MiB per call |
| Task | 1 h max per create/refresh |
| List page | 1-500, default 50 |

Plans **[CONFLICT]**: `pricing.md` says "No plans and no tiers" for
Sprites. The Sprites FAQ and release notes describe plans:

| Plan | Price | Known content |
| --- | --- | --- |
| Pay-as-you-go | $0 | 10 creates/min, community support |
| Recruit (Level 1) | free | (2026-01-22 note) |
| Adventurer (Level 20) | $20/mo | 60 creates/min |
| Veteran | ? | |
| Hero | $100/mo | 1,200 CPU-h, 4,800 RAM GB-h, 150 GB storage, 100 running + 100 warm, Standard email support |
| Champion | ? | Standard support |
| Legend (Level 200) | $200/mo | Standard support |
| Epic | ? | Premium support |
| Mythic (Level 2000) | $2,000/mo | 28,000 RAM GB-h, 240 creates/min, Premium support |

- Usage above the plan allowance bills at the standard rates.
- Plans are "seat-based"; upgrade now, downgrade at next period
  (2026-02-24).
- Fly account credits pay usage, not the plan fee.
- Trial: $30 credit per user, once per org ("Create, like, 500 Sprites
  free"). `pricing.md` says $1 trial and invoices under $5 are waived.
  **[CONFLICT]**
- How to raise limits: higher plan, or "Talk to us" (hello@fly.io,
  `https://fly.io/contact/`).

---

## 7. Billing

Sources: `https://fly.io/pricing.md`, FAQ on `https://fly.io/sprites`,
live OpenAPI usage endpoints.

| Item | Measure | Rate |
| --- | --- | --- |
| CPU | cumulative CPU time from cgroup `cpu.stat` | $0.0385 / CPU-hour |
| Memory | "actual memory usage" | $0.021875 / GB-hour |
| Hot storage | GB written, only while awake | $0.000683 / GB-hour (~$0.50 / GB-month) |
| Cold storage | GB kept, always | $0.000027 / GB-hour (~$0.02 / GB-month) |
| Checkpoints | changed blocks kept in object storage | storage rate (tier not stated) |
| Network / egress | not metered today | $0 |
| Per Sprite fee | none | $0 |

- All billed hourly on actual use. Warm and cold have no compute charge.
- The dashboard meter can differ from the invoice. The invoice wins.
  Bills finalise at month end.
- Older prices (2026-01-01): $0.07/vCPU-h, $0.011/GB-h RAM, $0.10/GB-month.
  Prices change.

### 7.1 Per-Sprite metering for our users

- Use `GET /v1/usage/{sprite}?start=..&end=..&interval=1h` or
  `GET /v1/usage?group_by=sprite`.
- CPU cost = `cpu_time_sec / 3600 * 0.0385`.
- Memory cost = `reserved_memory_byte_sec / 3600 / 1e9 * 0.021875` (GB or
  GiB not stated).
- **[CONFLICT]**: price list says "actual memory", usage API says
  "reserved memory". We do not know which one the invoice uses.
- Storage per Sprite: **no API field**. We must measure it ourselves
  (for example `df` in the Sprite) and estimate. Hot hours can be
  estimated from `cpu_time_sec` buckets > 0 or from our own wake log.
- Always check `partial`. A `true` value means the totals are too low.

### 7.2 Worked estimate: a daemon that holds a Task all month

Assumption: one Sprite, held `running` 730 h by a task heartbeat, idle
daemon uses 0.02 CPU average, 5 GB on disk.

| Line | Calculation | USD/month |
| --- | --- | --- |
| CPU | 0.02 x 730 x 0.0385 | 0.56 |
| Memory if billed at reserved 2 GB | 2 x 730 x 0.021875 | 31.94 |
| Memory if billed at actual 300 MB | 0.3 x 730 x 0.021875 | 4.79 |
| Hot storage | 5 x 730 x 0.000683 | 2.49 |
| Cold storage | 5 x 730 x 0.000027 | 0.10 |

Business risk: if memory bills at the reserved 2 GB floor, an always-on
Sprite costs about $35/month, more than our planned EUR 5-10 add-on.
Measure this on the first real Sprite before we set a price.

---

## 8. Multi-tenant use (Sprites for our end users)

Sources: `https://fly.io/legal/terms-of-service/`,
`https://fly.io/legal/acceptable-use-policy/`, `https://fly.io/sprites`,
Claude Managed Agents page.

### 8.1 Product fit

- Fly markets this use: "Untrusted code ... A clean baseline per request,
  so no two users ever share state", "Personal agents ... Give it a
  Sprite".
- Fly's own guide creates one Sprite per Claude session from a worker
  (`https://docs.fly.io/sprites/integrations/claude-managed-agents`). That
  is the same pattern as one Sprite per user.
- Isolation: each Sprite is its own hardware-isolated microVM.

### 8.2 Isolation controls we can use

- One Sprite per user, name prefix per user or per tier, labels.
- Network policy per Sprite (egress allowlist; private IPs always
  blocked).
- Privileges policy (`minimal`/`standard`/`privileged`, devices,
  `noNewPrivileges`).
- Resources policy (memory cap).
- URL auth `sprite` (default). Our server holds the org token; the user
  never gets it.
- Connectors keep shared secrets out of the Sprite. A connector policy
  can match one user by name prefix or labels.

### 8.3 Money risks

- ToS section "Subscription": access is "non-sublicensable,
  non-transferable ... solely for Customer's internal use". Reselling VMs
  to end users is not explicitly allowed. Ask Fly (sales) before launch
  to avoid an account stop.
- AUP: Fly may "suspend or terminate your account, with or without
  notice". Prohibited: spam, cryptomining, network or penetration
  scanning, copyright bots/torrents, abuse-generating URL shorteners,
  bypassing trial limits. One abusive user can stop the **whole org**,
  so all users' Sprites. Use a strict default egress policy and per-user
  quotas to lower that risk.
- Abuse contact: abuse@fly.io.
- Compliance: SOC 2 Type II, DPA available (`pricing.md`). Data location
  for Sprites is not stated (GDPR question for EU users).

### 8.4 Identity in outbound requests

- All three SDKs add `Fly-Client-*` headers and a User-Agent suffix that
  try to tell "human" from "AI agent" (package `client-signals`). Set
  `SPRITES_CLIENT_SIGNALS=0` on our server. The SDK version stays in the
  User-Agent (`sprites-py/<ver>`, `sprites-go-sdk/1.0`).
- If we call the REST API directly with httpx, we control all headers.

---

## 9. Gaps: questions the docs do not answer

1. Can we choose the region on create? Does `config.region` work? Is
   there an EU region, and where does the object storage live?
2. Does the server honour `config.ram_mb`, `config.cpus`,
   `config.storage_gb`? The Lifecycle page says no.
3. Name rules for a Sprite: characters, max length, reuse after delete.
4. Warm-to-cold time. Can we keep a Sprite warm without paying compute?
5. Does an outbound TCP connection (our websocket) count as activity?
6. Default and max of `max_run_after_disconnect`. Timeout of HTTP exec.
7. Is memory billed on actual use or on the reserved amount (usage API
   says reserved)? What is the minimum reserved memory? GB or GiB?
8. No per-Sprite storage figure in the usage API. How is checkpoint
   storage billed (hot or cold tier)?
9. REST call to delete a checkpoint. REST call to wake/start a Sprite.
10. How to create a restricted token (prefix, max count, labels, expiry)
    by API. Does a restricted token work for the Sprite URL bearer auth?
11. Does the Sprite URL proxy forward our `Authorization` header to the
    app, or strip it?
12. What the `minimal`, `standard`, `privileged` profiles allow. Is
    `privileged` needed for Docker?
13. Docker, podman, nested containers, `/dev/kvm`, FUSE, GPU.
14. The full `defaults` list of the network policy.
15. The Sprite `services` object (`public_url`, `internal_url`, `grants`,
    "compute-provider sprites"): how to create a service grant.
16. Plan table: price and limits of every plan (Veteran, Champion, Epic
    missing), and how `pricing.md` "no plans" fits with them.
17. Trial: $1 (`pricing.md`) or $30 (Sprites FAQ).
18. Terms for reselling Sprites to end users; SLA for Sprites; data
    retention after delete (Fly admins can restore deleted Sprites from
    the backup bucket).
19. Checkpoint speed and whether it stops services (1 s vs 10-30 s).
20. Ubuntu version of a new Sprite (25.10 vs 26.04).
21. Token format (3 parts vs 4 parts).
22. Rate limits of the REST API other than create.
23. Meaning of `cluster_id` / `sprite_ref` cluster in the usage API.
24. Whether `GET /v1/sprites/{name}` wakes the Sprite.
