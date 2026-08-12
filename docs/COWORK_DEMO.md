# CoWork local demo

A self-contained way to see CoWork work on one machine: a phone-style web page
drives the **real agent loop** running on this laptop, and the agent runs
laptop-native tools (`run_command`, `read_file`, `write_file`,
`list_directory`) on this machine.

No relay server, no account pairing, no second device. Everything is on
`127.0.0.1`. This is the local proof of the CoWork idea (phone drives an agent
on your own laptop); the production phone/relay path is built out over the
milestones in `COWORK_EXECUTION_PLAN.md`.

## What it reuses (not a fork)

- The **real** tool loop: a fresh `ToolLoopSession` from the shared
  `ToolCallHandler`, the same `sendStreamingChat` transport over the already
  authenticated `MultiplexSession`, and the same `processAssistantResponse`
  round recursion the desktop send logic runs.
- The E2E crypto envelope (`cowork_frame*.dart`) is deliberately **off** this
  path: the transport is a loopback socket, so there is no untrusted hop to
  protect. Those frames belong on the production relay path.

## Run it

```bash
FEATURE_COWORK_DEMO=true ./run.sh linux
```

or a release bundle:

```bash
flutter build linux --release \
  --dart-define-from-file=.env \
  --dart-define=FEATURE_COWORK=true \
  --dart-define=FEATURE_COWORK_DEMO=true
# then: ./build/linux/x64/release/bundle/chuk_chat
```

1. Sign in as normal (the agent uses your account's model + connection).
2. Click the **CoWork** switch (top-left). The surface shows a
   `http://127.0.0.1:<port>` address.
3. Open that address in a browser (a second window, or your phone if you swap
   `127.0.0.1` for this laptop's LAN IP). You get a phone-style chat page.
4. Type a task, e.g. *"list the files in my home directory"* or *"run `uname
   -a` and tell me the kernel"*. It runs **here**, on this laptop, and the
   result streams back to the page.

## Safety

The laptop-native tools deny by default:

- **Working-directory jail** — every path and command `cwd` is normalised and
  symlink-resolved and must sit under `coworkJailRoot` (default `$HOME`).
- **Credential denylist** — reads of `.env`, `*.pem`/`*.key`, `id_rsa`,
  `.ssh/`, `.aws/`, keyrings, etc. are refused.
- **Command timeout** — `run_command` is killed after 60 s; it never hangs.

## Flags

| Flag | Default | Effect |
|------|---------|--------|
| `FEATURE_COWORK` | on in `run.sh` | shows the Chat↔CoWork switcher |
| `FEATURE_COWORK_DEMO` | off | turns the CoWork surface into this demo + registers the laptop-native tools |

With `FEATURE_COWORK_DEMO` off, the build is byte-unchanged: none of the four
tools register and the surface stays the "coming soon" placeholder.
