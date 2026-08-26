# cowork-host

A runnable **local host** for the whole CoWork platform on one machine — no
production relay involved.

It bundles four things into one process:

1. a **blind localhost relay** (a `websockets` server on `127.0.0.1:<port>`) that
   just routes JSON messages verbatim between two parties on the same channel;
2. an **agent roster** (`cowork_manager`) with a persistent workspace per agent;
3. the **pairing initiator** (`cowork_crypto`, §15) — it prints a short human code
   the CoWork app types in to establish an E2E channel key + mutual device trust;
4. a **task server** that runs the real `cowork_executor` Executor (agent loop +
   sandbox + encrypted frames) under the `cowork_manager` supervisor.

The Dart app implements the *other* end of the same local relay protocol.

## Run it

```bash
cd host
uv run cowork-host --port 8787
```

You will see something like:

```
Open the CoWork app, Connect to  ws://127.0.0.1:8787  and enter code:  1a2b3c4d5e6f7a8b-428913
```

Enter that in the app to pair, then drive the agent from your phone.

## The local relay protocol

- On connect a party sends `{"type":"join","channel":"<id>","role":"executor"|"controller"}`.
  The relay pairs the two roles on a channel and forwards everything after, blind.
- Pairing envelopes: `{"type":"pairing","step":"commit|pubkey|reveal|confirm-d|confirm-c|device-d|device-c","data":{...}}`.
- Sealed frames: `{"type":"frame","frame":"<base64 of a sealed CoWork frame>"}`
  — token provisioning, tasks, and streamed results all ride sealed frames.

The host is the **executor** role and the pairing **initiator**; the app is the
**controller** role and the pairing **joiner**.
