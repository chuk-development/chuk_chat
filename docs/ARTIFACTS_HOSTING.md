# Artifact Hosting

Lets the AI publish a self-contained HTML page and hand back a public URL —
like Claude Artifacts / grok.me, but on our own subdomain. The AI is the only
writer: there is no public write API, every page belongs to a signed-in user,
and the page is served locked-down and non-indexed.

Two moving parts:

- **`chuk-artifacts`** (separate repo `chuk-development/chuk-artifacts`) — a
  small FastAPI service that stores the HTML and serves it at
  `https://artifacts.chuk.chat/a/<id>`.
- **This app** — the `create_artifact` / `update_artifact` builtin tools that
  POST/PUT to that service and return the URL to the model.

## Why it is safe to host third-party HTML

The security model does **not** depend on the AI behaving. A jailbroken model
that emits hostile HTML changes nothing, because the browser enforces the
policy the service sets on the response. Two independent layers:

1. **CSP (authoritative).** Every hosted page (`/raw/<id>`) is served with a
   deny-by-default Content-Security-Policy. `img-src 'none'` blocks external
   **and** base64/data images (this is what closes the embedded-image / CSAM
   vector — visuals still work via inline SVG, CSS and `<canvas>`).
   `connect-src 'none'` blocks fetch/XHR/websocket, so a page cannot exfiltrate
   data or phone home. `frame-src 'none'` blocks nested iframes. The page runs
   inside `<iframe sandbox="allow-scripts">` (no `allow-same-origin`), so it
   lives in an opaque origin and cannot touch the wrapper, cookies or storage.
2. **Sanitizer (belt-and-suspenders).** On the way in the service strips
   `<iframe>/<object>/<embed>/<base>` and `<meta http-equiv=refresh>`. Inline
   JS/CSS/SVG are kept on purpose — this is an app platform.

The `skill`-style tool descriptions tell the model these limits up front, so it
does not waste output on an external `<img>` that would render broken. That is
UX only; the CSP is the wall.

URLs are `<= 40-char slug>-<uuid4 hex>` — 122 bits of entropy, not guessable or
enumerable. Every page sends `X-Robots-Tag: noindex` and `robots.txt` disallows
all, so nothing is indexed.

## Legal posture

The service is a host provider. That is the normal, privileged position (EU
DSA / German DDG safe harbour): not liable for user-generated content while it
acts on notice. What makes the privilege hold is already built in:

- A hardcoded footer on every page (outside the sandboxed iframe, so user CSS
  cannot hide it) carrying the abuse contact and a report link.
- `DELETE /v1/admin/artifacts/<id>` with an operator token — the takedown lever.
- Every artifact maps to one signed-in Supabase account, so there is always a
  responsible party to block.

Publishing is public by definition: a page served in plaintext to anyone with
the link cannot be end-to-end encrypted. Only the published blob leaves the
zero-knowledge zone; the rest of chat stays E2E. This is surfaced to the model
in the tool result ("PUBLIC to anyone with the link").

## Download

The wrapper footer offers `GET /download/<id>` — the raw stored HTML as a file
attachment (no wrapper, no footer). Self-contained, so it works offline. What
the user does with the downloaded file afterwards is theirs; the service just
stops hosting it.

## Client wiring (this repo)

Feature flag `kFeatureArtifactHosting` (`FEATURE_ARTIFACT_HOSTING`, default on)
gates two builtin tools registered like any other:

| Edit point | File |
|---|---|
| `builtinTools` (tool defs) | `lib/services/tool_registry.dart` |
| `toolCategoryMap` (`ToolCategory.basic`) | `lib/services/tool_registry.dart` |
| flag gate in `registerBuiltinTools()` | `lib/services/tool_registry.dart` |
| `_builtinExecutableToolNames` (assertion) | `lib/services/tool_executor.dart` |
| switch cases → handler | `lib/services/tool_executor.dart` |
| `_nonFactualToolNames` (skip `[VERIFY]`) | `lib/services/tool_call_handler.dart` |
| handler (POST/PUT) | `lib/tool_handlers/artifact_tools.dart` |
| base URL (`ARTIFACTS_BASE_URL`) | `lib/services/api_config_base.dart` |

They show as default-on toggles under Tool-Calling settings. The token is
threaded in via `_serverHeaders(accessToken:)`, same as the web/crawl tools.

## API contract

`POST /v1/artifacts` and `PUT /v1/artifacts/<id>` — Bearer Supabase token,
`{html, title?}` → `{public_id, url, download_url}`. See the `chuk-artifacts`
repo README for the full surface, CSP details and deploy steps.

## Deploy checklist

1. Apply `migrations/001_artifacts.sql` to the Supabase project (Management API
   query endpoint, not `supabase db push`).
2. Point DNS `artifacts.chuk.chat` at the Dokploy app for `chuk-artifacts`.
3. Set the service `.env` values in Dokploy (Supabase keys, `ABUSE_ADMIN_TOKEN`).
4. Push `chuk-artifacts` → Dokploy builds and rolls out.
