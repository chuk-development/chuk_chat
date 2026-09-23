# Agents

A team of persistent, sandboxed AI coworkers you message tasks to. See the full
plan in [`docs/AGENTS_AGENT_PLATFORM_PLAN.md`](docs/AGENTS_AGENT_PLATFORM_PLAN.md).

The Flutter app is the repository root. The Python platform is `agents/`.

| Dir | What |
|-----|------|
| `agents/runtime/` | The Python agent runtime — the loop, tools, state, model client. |
| `agents/sandbox/` | Per-agent execution sandbox: `BaseEnvironment` ABC + backends, container lifecycle, base image. |
| `agents/manager/` | The host control plane — roster, lifecycle, scheduler, relay bridge. |
| `agents/executor/` | The task server the app talks to over the relay. |
| `agents/host/` | `cowork-host`: the local relay + pairing + CLI (`connect`, `run`, `status`). |
| `agents/common/` | Shared code — the E2E Agents frame crypto (Python twin of the Dart). |
| `agents/skills/` | The skills seeded into a new agent workspace. |
| `lib/`, `android/`, `linux/`, `test/` | The Flutter controller app (messenger/roster UI). |
| `scripts/` | `install.sh` and the systemd user unit. |
| `docs/` | The plan. |

Python: 3.12, managed with `uv`, tested with `pytest`. Flutter at the root.

Status: foundation build in progress.

## Install on your own machine

```bash
./scripts/install.sh          # checks docker, builds the base image, installs the service
cowork-host connect           # one-time pairing with the phone; then it runs by itself
```

`install.sh` is idempotent — run it again after `git pull` and nothing breaks.
`--dry-run` prints the plan without touching anything; `--help` lists the flags
(`--no-service`, `--no-env`, `--prefix`, …). It refuses to install a container
runtime behind your back: without `--install-runtime` it prints the one command
to run and stops **before** changing anything.

After the install:

| Command | What |
|---------|------|
| `cowork-host connect` | pair once (safe to re-run: an already paired host is left alone) |
| `cowork-host connect --pair` | pair a **different** device; the current one stops working |
| `cowork-host status` | paired? where is the state? what is the service doing? |
| `cowork-host run` | run in the foreground (this is what the systemd unit executes) |
| `systemctl --user status agents-manager` | the installed user service |

## The agent's container

Each agent gets one Debian container (`agents/sandbox/docker/Dockerfile`): passwordless
sudo, Python 3.12 + `uv`, git, tmux, and its host workspace bind-mounted at
`/workspace`. Containers are found by label, so they are reused across turns and
across Manager restarts, and an orphan reaper clears whatever a killed run left
behind. Build it by hand with:

```bash
docker build -t agents-base:latest agents/sandbox/docker
```
