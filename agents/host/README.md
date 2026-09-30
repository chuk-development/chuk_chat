# cowork-host

A runnable **host** for the whole Agents platform on one machine.

By default it reaches the app through the **cloud relay**
(`wss://api.chuk.chat/v2/relay/ws`): the host dials *out*, so a phone on mobile
data can reach it and neither end has to be addressable. The old blind loopback
relay is still here as the same-machine developer path, behind `--local-relay`.

It bundles four things into one process:

1. a **pipe to the app** — the cloud relay by default, or a **blind localhost
   relay** (a `websockets` server on `127.0.0.1:<port>`) with `--local-relay`,
   which routes JSON messages verbatim between two parties on the same channel;
2. an **agent roster** (`chuk_agents_manager`) with a persistent workspace per agent;
3. the **pairing initiator** (`chuk_agents_crypto`, §15) — it prints a short human code
   the Agents app types in to establish an E2E channel key + mutual device trust;
4. a **task server** that runs the real `chuk_agents_executor` Executor (agent loop +
   sandbox + encrypted frames) under the `chuk_agents_manager` supervisor.

The Dart app implements the *other* end of the same local relay protocol.

## Run it

```bash
cd host
uv run cowork-host            # cloud relay (the default)
uv run cowork-host --local-relay --port 8787   # same-machine development
```

You will see a QR code, the link it encodes, and the code to type:

```
  Scan this with the Agents app:

    <QR block>

  ...or paste this link into the app:  cowork://pair?c=<pairing channel>&k=<code>&r=wss%3A%2F%2Fapi.chuk.chat

  Open the Agents app, Connect to  wss://api.chuk.chat/v2/relay/ws  and enter code:  1a2b3c4d5e6f7a8b-428913
```

Scan it to pair, then drive the agent from your phone. The QR is the default
mobile path; the code is the fallback when the camera is not available.

Useful flags: `--relay-url` (a self-hosted backend — it rides in the QR, so no
rebuild), `--no-qr`, `--qr-light` (a light-background terminal), `--pair` (forget
the stored pairing and mint one fresh code).

### Pair with the install command (token)

The logged-in Chuk app makes a one-time install token and shows one command:

```bash
curl -fsSL https://api.chuk.chat/agents/install.sh | bash -s -- --token=<P>-<D>
```

The script behind it is `scripts/agents-bootstrap.sh`. It installs uv if it is
missing, gets `agents/` and `scripts/` into `$AGENTS_HOME/src`, runs
`scripts/install.sh`, and then becomes `agents-host connect` (`exec`) with the
token in `$AGENTS_INSTALL_TOKEN`. Other options go to `install.sh` (for example
`--no-runtime`, `--no-service`, `--dry-run`). `--ref`, `--source DIR` and
`--no-connect` are for the bootstrap.

Every local user can read a command line (`/proc/<pid>/cmdline`). A token in a
command line that lives for 30 minutes lets another local user with a Chuk
account claim the channel first and pair this computer to that account. So:

- `connect` reads the token from `$AGENTS_INSTALL_TOKEN` (only the same user
  can read an environment) and removes the variable at once, so no child
  process gets it. `--token` still works for manual use and wins over the
  variable, but it is visible to other local users while `connect` runs.
- The bootstrap starts itself again at once with the token in the environment
  and not on its command line. At the end it replaces itself with
  `agents-host connect` (`exec`). The installer and its children do not get
  the variable. The token is on a command line only for the first moment of
  `bash -s -- --token=...`, before the restart.

The token has a fixed shape: `P` is 64 lower-case hex characters, `D` is
8 digits. `P` is the relay pairing channel and also the §15 channel id, so the
pairing code is the token itself. The app claims channel `P` with its login and
joins with the code `P-D`. So only the app that made the token can pair this
host.

With `--token`, `connect`:

- replaces a stored pairing and the account token (the same as `--pair`);
- shows no code and no QR, only "Waiting for the Chuk app to confirm this
  computer...";
- parks on the same channel `P` again when the relay drops it after five
  minutes, until the wait ends;
- waits 30 minutes by default (`--timeout` changes this). Then it says "The
  install command expired" and exits with 1;
- exits with 2 on a malformed token. The token is never printed or logged.

Manual use without the command line: `AGENTS_INSTALL_TOKEN=<P>-<D> agents-host connect`.

### How the host authenticates to the relay

The relay wants a Supabase JWT, and a brand-new host has no account. So:

1. **First pairing:** the host presents no token at all, only a 256-bit
   CSPRNG pairing channel — the bearer capability in the QR. The relay *parks*
   that socket: until a logged-in app claims the channel it may send only
   `{"type":"ping"}`, so the host queues its hello instead of spending it. The
   claim arrives as `{"type":"cowork_pair_bound"}` and releases the queue; §15
   then runs E2E over that channel, so a malicious relay still cannot MITM. A
   channel nobody claims within five minutes dies
   (`{"type":"cowork_pair_expired"}` + `close(1008)`), and the host mints a fresh
   channel and a fresh code and prints them rather than retrying a dead one.
   With an install token the host parks on the same channel again instead,
   because the app waits on that channel.
2. **Ever after:** the app provisions the account token in the first sealed frame
   (§15 step 7). It is stored `0600` in `account.json` next to `paired.json`, and
   every later connect is the ordinary `{"type":"auth","token":...}` handshake.
   The unauthenticated path runs **once per host**.

## The party protocol (the same on both pipes)

- On connect a party sends `{"type":"join","channel":"<id>","role":"executor"|"controller"}`.
  The relay pairs the two roles on a channel and forwards everything after, blind.
- Pairing envelopes: `{"type":"pairing","step":"commit|pubkey|reveal|confirm-d|confirm-c|device-d|device-c","data":{...}}`.
- Sealed frames: `{"type":"frame","frame":"<base64 of a sealed Agents frame>"}`
  — token provisioning, tasks, and streamed results all ride sealed frames.

The host is the **executor** role and the pairing **initiator**; the app is the
**controller** role and the pairing **joiner**.

On the cloud relay these exact messages ride inside one `cowork_relay` frame
each — `{"req_id":"<hex>","type":"cowork_relay","payload":"<the JSON above>"}` —
and the relay never reads the payload. Nothing about the ceremony or the seal
changes with the pipe; see `docs/PLAN_2026-09-09_CLOUD_PAIRING_TRANSPORT.md`.
