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
| `agents/host/` | `agents-host` (old name `cowork-host`, still works): the local relay + pairing + CLI (`connect`, `run`, `status`). |
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
agents-host connect           # one-time pairing with the phone; then it runs by itself
loginctl enable-linger "$USER"   # once: start the service at boot, not at the first login
```

`install.sh` is idempotent — run it again after `git pull` and nothing breaks.
`--dry-run` prints the plan without touching anything; `--help` lists the flags
(`--no-service`, `--no-env`, `--prefix`, `--bin-dir`, `--enable-linger`, …). It
refuses to install a container runtime behind your back: without
`--install-runtime` it prints the one command to run and stops **before**
changing anything.

**Survives a reboot.** The unit is a systemd *user* service with
`Restart=always` and `WantedBy=default.target`. A user manager only runs at boot
when lingering is on, so run `loginctl enable-linger "$USER"` once (or pass
`--enable-linger`); otherwise the host starts at your first login. The unit
holds no secret: the Supabase URL and anon key come from the account token the
app provisions. Optional overrides (for example `AGENTS_RELAY_URL`) go into
`~/.config/chuk-agents/host.env`.

**Where the state is.** `$XDG_DATA_HOME/chuk-agents`, i.e.
`~/.local/share/chuk-agents`: the pairing, the device key, the account token,
the vault, the databases and the agent workspaces. `$AGENTS_HOME` (or the old
`$COWORK_HOME`) or `--workspace` moves it. It is **not** `~/.agents`: other
tools (the `skills` CLI) keep `~/.agents/skills` there. On its first start, the
host moves a legacy state into the new place once: `~/.cowork` (left behind as
a symlink), or host files at the top of `~/.agents` (a note is left; `skills/`
is never touched). If both hold a state, the one with `paired.json` wins, and
an existing pairing in the new place is never overwritten. The launchers go to
`~/.local/bin`.

After the install:

| Command | What |
|---------|------|
| `agents-host connect` | pair once (safe to re-run: an already paired host is left alone) |
| `agents-host connect --pair` | pair a **different** device; the current one stops working |
| `agents-host status` | paired? where is the state? what is the service doing? |
| `agents-host run` | run in the foreground (this is what the systemd unit executes) |
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
