# Cloud pairing + transport — everything through `api.chuk.chat`

Decision record and implementation contract. Written 2026-09-09 on the owner's
instruction. Read this before touching the relay, the host transport, or the
pairing UI.

## The decision (supersedes §14.1 of COWORK_AGENT_PLATFORM_PLAN.md)

**All controller↔host traffic goes through the API server relay. There is no
peer-to-peer data plane.** §14.1 ("P2P data plane — the server coordinates, it
does not carry", decided 2026-09-02) is **superseded**: WebRTC/ICE/TURN is not
built and not planned.

Why the reversal, in the owner's words: assume there is never a direct
connection. The only direct connection is each side to the API server. Assume an
API server is always running. On mobile a direct path fails in ~99% of cases
(carrier NAT), and the host may be a Linux box in some cloud — nothing on either
side is addressable. Chasing hole-punching is what stalled this for a week.

Consequences, accepted:

- The relay carries the bytes, including the VNC/browser stream. Bandwidth is
  ours to pay. The 1 MB relay frame cap therefore applies to every payload —
  large streams **must** be chunked client-side and reassembled after decrypt.
- `Handy/Desktop-App (controller) ⇄ api.chuk.chat ⇄ cowork-host (executor)`.
- The local `ws://127.0.0.1:8787` blind relay stays, but only as the
  same-machine developer path. It is never what a phone uses.

Unchanged and still load-bearing: the §15 pairing ceremony, the §15.1 persistent
trust and reconnect, and the `cowork_frame` E2E seal. **Only the pipe changes.**
The relay stays blind — it routes an opaque `payload` it can never read.

## What already exists (do not rebuild)

- **Relay endpoint** `/v2/relay/ws` on `main:app` — `routers/cowork/cowork_ws.py`,
  routing rules in `cowork_relay.py`, cross-replica presence in `cowork_peers.py`.
  Tested (`test_cowork_ws.py`, `test_cowork_relay.py`). Wire contract:

      client -> {"type":"auth","token":"<supabase jwt>",
                 "role":"controller"|"executor","device_id":"<uuid4>"}
      server -> {"type":"auth_ok"} | {"type":"auth_error","detail":...} +close(1008)
      controller -> {"req_id","type":"cowork_relay",
                     "target_device_id":"<uuid4>","payload":<opaque>}
      executor   -> {"req_id","type":"cowork_relay","payload":<opaque>}
      server     -> {"type":"executor_status","device_id","online"}
                    {"type":"cowork_error","code","target_device_id","req_id"?}
      control    -> {"type":"ping"} / {"type":"cowork_presence"}

  Frame cap `MAX_RELAY_FRAME_SIZE` = 1 MB, enforced after parse so the refusal
  carries `req_id`.
- **Auth boundary** `auth/ws_auth.py` — accepts a Supabase user JWT and nothing
  else; validated by an HTTPS call to GoTrue. No JWT secret anywhere.
- **App**: `cowork_frame*` seal, §15 joiner ceremony, `cowork_reconnect.dart`,
  the Supabase-mirrored trust record (`supabase_pairing_sync.dart`).
- **Host**: §15 initiator ceremony, executor, sandbox, `paired.json` trust.

## The gap

Neither client speaks the endpoint above. Both still speak the *local blind
relay* protocol (`{"type":"join","channel":"<id>","role":"controller"}`) against
`ws://127.0.0.1:8787`. That is the only reason a phone sees no coworker: the
synced trust record faithfully carries a loopback URL the phone cannot route.

And a bootstrap problem: the relay requires a Supabase JWT from **both** sides,
but the host has no account token before its first pairing — §15 step 7 is what
gives it one, and that step runs *over* the channel it cannot yet join.

## The bootstrap, resolved

The host's own single-use pairing code is the bootstrap credential, and the
backend confirms it against a logged-in account. Minimal server addition:

1. `POST /v1/cowork/pair/announce` — **unauthenticated, strictly rate-limited.**
   Host sends `{"channel_id", "commitment"}` (the §15 `H(A)`), gets back
   `{"pair_ticket", "expires_in"}`. The ticket is short-lived (~5 min),
   single-use, and authorizes **one** socket as `role=executor` **restricted to
   that pairing channel** — no account binding, no relay access beyond it.
2. Host connects `/v2/relay/ws` with `{"type":"auth","ticket":...,
   "role":"executor","device_id":...}` (new: `ticket` accepted *instead of*
   `token`, only for a pairing channel).
3. The app — logged in, real JWT — sends `{"type":"cowork_pair_claim",
   "code":"<the code the user typed or scanned>"}`. The server binds that
   pairing channel to the app's `user_id`. **This is the "confirm on the
   backend" step: without a claim from an authenticated account, nobody can
   reach a host sitting in pairing mode.**
4. §15 SAS + commitment then runs E2E over that channel. A malicious relay still
   cannot MITM — that is exactly what the commitment and the SAS/MAC confirm
   protect against, and it is why the backend is allowed to broker this at all.
5. On success the app provisions the account token to the host (§15 step 7). The
   host persists it and from then on authenticates the normal way, with a real
   JWT. **The ticket path is used exactly once per host, ever.**

Then §15.1 applies unchanged: reconnect by signed nonce, no code again. Log out
on every device, delete the app, reinstall, sign in — the trust record comes back
from Supabase and the host is there. Identity, not address.

## Pairing UX

- **Mobile (default): QR.** The host prints a QR code in the terminal encoding
  the pairing URI. The user scans it in the Flutter app. No typing. The scanner
  is what the mobile pairing screen opens with.
- **Mobile (fallback): the code.** The same screen offers "enter code instead"
  for when the camera is unavailable, the terminal is not in reach, or the scan
  fails. Same string, same result — the QR is a convenience, never the only way.
- **Desktop: the code.** Printed to copy and paste into the client. This is what
  §15 already describes.
- Pairing URI (one line, both paths carry the same payload):

      cowork://pair?c=<channel_id>&k=<code>&r=<relay base url>

  `r` lets a self-hosted backend be pointed at without a rebuild; it defaults to
  `wss://api.chuk.chat` when absent.

## Work breakdown

| # | Where | What |
|---|---|---|
| 1 | `api_server` | `/v1/cowork/pair/announce`, ticket minting + single use, `ticket` accepted on the relay handshake for a pairing channel only, `cowork_pair_claim` frame binding the channel to the caller's account. Rate limits. Tests. |
| 2 | `host` | Cloud executor client: dial `wss://api.chuk.chat/v2/relay/ws`, ticket bootstrap then account token, wrap/unwrap `cowork_relay` payloads onto the existing party. Persist the account token. Print code **and** QR. Keep the local relay as a dev flag. |
| 3 | `app` | Cloud transport as `controller` behind the existing `RelaySocket` seam; pairing screen takes a code **or** a scanned QR; reconnect dials the relay, not a loopback URL. |
| 4 | both clients | Chunk any payload over the 1 MB cap (VNC/browser stream first) and reassemble after decrypt. |

Order: 1 and 2 in parallel (separate repos), then 3, then 4. Basic chat over the
cloud relay is the acceptance test; the VNC stream follows.

## Acceptance

Phone with mobile data only (no shared network), host on this machine:
sign in, scan the QR once, chat works. Kill the app, reinstall it, sign in — the
coworker is still there and no code is asked for.
