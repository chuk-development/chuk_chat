# CoWork — Self-Hosted Backend Pivot

**Status:** directional decision. Supersedes the server-hosted sandbox and the
server-side credential model for CoWork. Code removal is staged (see
"Migration"), not immediate. Read this before touching anything under
`sandbox_*`, `/v1/user/github/*`, or `routers/mcp_github.py`.

---

## The decision in one line

chuk's api-server becomes zero-knowledge for **both** credentials and
execution. The user hosts their own execution backend. Credentials flow from
the client straight to that user-hosted backend. They never pass through, and
are never stored on, chuk's server.

## Why

Three reasons, all money or liability.

1. A server that never holds a credential cannot leak one. This extends the
   CoWork relay claim (§5/§8 of `COWORK_BUILD_PLAN.md`) from "the relay can't
   read your commands" to "the server never holds your keys either". It is one
   more checkable claim that Claude Cowork and ChatGPT cannot make.
2. It removes chuk's cost and risk for running execution. No rented E2B/E2B-like
   VMs on our bill. No "remote code runs inside chuk infra" in a breach
   headline. The RCE blast radius moves onto the machine the user chose to run.
3. It generalises the product's differentiator. Today: "your real laptop".
   The pivot: "your own hosted fleet — many agents, each with its own VM or
   command line, on hardware you control". The execution surface scales on the
   user's side, not ours.

## The target model

```text
  ┌──────────────┐        E2E opaque blobs        ┌───────────────────────────┐
  │  CLIENT      │   ┌────────────────────────┐   │  USER-HOSTED BACKEND      │
  │  chuk_chat   │───┤  chuk relay (blind)    ├───│  (separate product, built │
  │  phone/desk  │   │  store-and-forward     │   │   elsewhere)              │
  │              │   │  sees ciphertext only  │   │                           │
  │  holds the   │   └────────────────────────┘   │  N agents, each with its  │
  │  credentials │                                │  own VM / command line    │
  │  (secure     │──────────────────────────────▶│  git / gh / MCP run here  │
  │   storage)   │   credentials, E2E to the      │  under the user's keys    │
  └──────────────┘   user's own backend           └───────────────────────────┘
```

- The client holds the credentials, in `FlutterSecureStorage`, exactly as the
  ordinary MCP OAuth connectors already do (`mcp_oauth.dart`, keyed
  `mcp_secrets_<id>`). This path already exists and is already zero-knowledge.
  The pivot makes it the only path.
- chuk's server relays opaque encrypted blobs. It is the same trust boundary
  the CoWork relay already defines. It parses nothing. It stores no key.
- The user-hosted backend runs the agents. Each agent gets its own VM or
  command line — the "sandbox" concept stays; who hosts it changes. That
  backend is a separate product, built in its own repo.
- Credentials reach that backend E2E from the client, not from chuk's server.
  The backend uses them to run `git` / `gh` / MCP under the user's identity.

## The key insight — one path already does this right

The app has two credential systems today. One is the model to keep; the other
is the exception to remove.

| System | Where the token lives | Server sees it? | Verdict |
|---|---|---|---|
| MCP OAuth connectors (`mcp_oauth.dart`) | `FlutterSecureStorage` on device | No | **Keep — this is the target model** |
| GitHub device flow (`/v1/user/github/*`, `mcp_github.py`) | Encrypted on api-server | Yes | **Remove — server-side credential** |
| Server-hosted sandbox (`sandbox_service.dart`, E2B) | n/a — execution on chuk infra | n/a | **Remove — replaced by user-hosted backend** |

"One token, two consumers" (the sandbox and the MCP GitHub relay, both fed by a
server-held token — see `MCP_CONNECTORS.md`) is exactly the pattern being
retired. Both consumers move to the client-held-credential path, forwarded to
the user's backend.

## What this changes vs. `COWORK_BUILD_PLAN.md`

The build plan already carries most of the pivot — it just still names chuk's
own infra in two tiers. Corrections:

- **Sandbox Tier-3 (E2B cloud microVM, §4/§7).** Was chuk-hosted escape hatch.
  Now: the user-hosted backend is the venue for cloud/remote execution. chuk
  does not rent VMs. The `ExecuteRequest`/`ExecuteResponse` contract can stay;
  the endpoint it talks to moves to the user's backend.
- **Credential handling (§5/§8).** The zero-knowledge claim now covers keys,
  not only commands. Add: credentials are forwarded client → user-backend E2E,
  never held server-side.
- **The relay (§1/§5) is unchanged.** It was already blind store-and-forward.
  The pivot fits it — the relay carries credential blobs the same way it carries
  command blobs.

## Migration — staged, not now

Keep the server-hosted sandbox and the server-side GitHub token working until
the user-hosted backend ships. Do not break today's shipped path first.

**When the user-hosted backend lands, remove:**

- `lib/services/sandbox_service.dart`, `lib/tool_handlers/sandbox_tools.dart`,
  `lib/pages/sandbox_management_page.dart` — the server-sandbox client.
- `lib/services/github_connection_service.dart`,
  `lib/pages/github_connection_page.dart` — the server-side device-flow client.
- The api-server side: `/v1/user/github/*`, `/v1/ai/sandbox/*`,
  `routers/mcp_github.py`, `mcp_proxy.py` (separate repo — track there).

**Keep and generalise:**

- `lib/services/mcp/*` — the client-side OAuth connector path. This becomes the
  template for how every credential is held and forwarded.
- The CoWork relay and envelope crypto — they carry the credential blobs too.
- `lib/services/github_oauth.dart` — the on-device loopback OAuth flow. Already
  client-held; fits the target model.

**Do not delete before the replacement is live.** The sandbox is still the only
execution surface CoWork has until the user-hosted backend exists. This doc
records the destination, not a delete order.

## Open questions

- Provisioning: how does a user register their self-hosted backend with the
  client? Pairing (QR/device-key, like the CoWork laptop) is the natural fit —
  the backend is just another paired executor.
- Credential forwarding shape: per-agent, or one credential set the backend
  fans out to its agents? Lean per-user held on the client, scoped per agent
  on the backend.
- The separate backend product's repo, contract, and hosting story — defined
  there, linked from here once it exists.
