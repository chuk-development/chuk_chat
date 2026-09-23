# The relay must connect without the user, and the host must update itself

Two problems, one root: the host's link to the relay is the only way the user
reaches their machine, and today that link depends on things that expire or
need a terminal.

Status 2026-09-11: part A step 1 is done (commits 5b83445, a8ae14d). Steps 2
and 3, and all of part B, are open. Beads: cowork-fm8w (closed), and the issues
this file names.

## A. An executor that always gets on the relay

### What went wrong

The host authenticates to `wss://api.chuk.chat/v2/relay/ws` with the Supabase
access token of the account. That token lives one hour. Three defects turned
that into a host that was offline for a day:

1. The session was built with no `expires_at`, and a session with no deadline
   never refreshes.
2. A refused handshake and an unreachable relay were the same event: wait, dial
   again with the same credential.
3. A host that cannot authenticate cannot receive a controller — and a
   controller is the other source of a fresh token. The failure repairs nothing
   and locks itself in.

Steps 1 and 2 are fixed. The deadline is read from the JWT itself when the
caller does not pass one, and a `RelayAuthRejected` makes the host refresh that
exact token and redial at once. Defect 3 is structural and needs the relay.

### Step 2: the relay says WHY it refused

`auth_error` carries free text (`"Invalid token"`). The client cannot tell an
expired token from a revoked one, from a validator that is down. Add a `code`:

| code | meaning | what the host does |
|------|---------|--------------------|
| `token_expired` | the JWT is past `exp` | refresh, redial at once |
| `token_invalid` | signature or user gone | refresh once, then slow backoff, and raise `needs_reauth` for the app |
| `auth_unavailable` | the validator could not answer | backoff; the token is not the problem, do not spend a refresh |
| `device_invalid` | the `device_id` is not a uuid4 | log and stop; a redial cannot fix it |

Server: `routers/agents/agents_ws.py`, `_reject()` grows a `code` argument.
Client: `cloud_relay.py` reads `reply["code"]` and `RelayAuthRejected` carries
it. Old clients keep reading `detail`, so the change is additive.

### Step 3: the control channel stops depending on the account token

This is the part that makes the connection unconditional. The rule:

> The channel that carries control must not share a secret with the channel
> that carries billing.

The host already owns a long-lived Ed25519 identity (`host_device.key`,
`identity.py`) and the pairing ceremony already proves it to the app. Let the
relay learn the same public key, and let the executor handshake be a signature:

```
host -> {"type":"auth","role":"executor","device_id":"<uuid4>",
         "ts":<unix>,"nonce":"<hex>","sig":"<ed25519(device_id|ts|nonce)>"}
relay-> {"type":"auth_ok"}
```

* The relay looks up `(user_id, device_id) -> public_key` in a new Supabase
  table `agents_devices` (owner-only RLS: `user_id`, `device_id`,
  `public_key`, `created_at`, `last_seen_at`, `revoked_at`).
* `ts` inside ±60 s and a nonce cache of the same width stop replay.
* Nothing here expires. Revocation is a row update — which is exactly the
  remote logout that is already wanted (bead cowork-7wq).

Registration needs no user step. The first time a host is connected **and**
holds a valid account token, it sends `device_register` with its public key,
signed. The relay writes the row. From then on the signature is the credential
and the account token is only spent on model calls. When that token dies, the
control channel stays up, the app sees the host, and the existing
`reprovision_request` frame carries a fresh pair in. The deadlock cannot form.

Migration: the relay accepts both credentials for one release. The host sends a
signature when it has a registered key, else the token.

## B. Updating the host from the app

Goal: the user taps once in the Flutter app, the host replaces itself, and the
connection comes back on its own. No terminal, no ssh, no reinstall.

### The frames

| frame | direction | payload |
|-------|-----------|---------|
| `host_version` | host -> app | `version`, `git_sha`, `install_kind` (`uv`/`pipx`/`git`), `channel` |
| `host_update_available` | host -> app | `version`, `notes`, `size_bytes`, `mandatory` |
| `host_update_apply` | app -> host | `version` |
| `host_update_progress` | host -> app | `phase` (`download`/`verify`/`swap`/`restart`), `percent` |
| `host_update_starting` | host -> app | `expected_downtime_s` |
| `update_result` | host -> app | `ok`, `version`, `reason` |

The host, not the app, polls the feed: it has the network, the disk and the
install kind. `GET /v2/host/latest?channel=stable` answers `version`,
`wheel_url`, `sha256`, `notes_url`, `min_app_version`. GitHub Releases can host
the wheel; the endpoint only points at it.

### The sequence

1. Host checks the feed at start and every six hours.
2. A newer version -> `host_update_available` to every attached controller, and
   a push through the notification path that already exists, so the user sees
   it with the app closed.
3. The user taps "Update". The app sends `host_update_apply`. A settings switch
   ("install host updates by itself") lets the host skip this step and update
   while idle.
4. The host downloads the wheel into `<workspace>/updates/<version>/`, checks
   the sha256 and the release signature, and installs it into a **new** venv
   next to the running one. Nothing is touched yet.
5. The host waits for idle: no run in flight, the queue drained. A run in
   flight postpones the swap, it never kills it.
6. `host_update_starting{expected_downtime_s: 5}` goes out, the app shows
   "updating" instead of "host offline", and the host re-execs itself from the
   new venv with the same argv. The workspace, `paired.json`, `account.json`
   and the databases stay where they are, so the new process reconnects as the
   same device with the same pairing. The socket is down for about two seconds.
7. The new process sends `host_version` and `update_result{ok:true}`.

### When the new version is broken

The old venv stays on disk for one version. A watchdog written before the swap
gives the new process 60 s to reach a successful relay handshake. If it does
not, the watchdog starts the previous venv again and sends
`update_result{ok:false,reason}`. The app shows that the update was rolled
back. The failed version is not offered again until the feed names a newer one.

### Why not let the app push a binary

The app would have to carry a wheel for every host platform, and the transfer
would ride the relay's 1 MB frame cap. The host pulling from a signed URL is
smaller, resumable, and works when the app is closed.
