# The product is called Agents

Decided 2026-09-13. "Agents" was the working title while the platform lived in
its own repository. The platform is now a mode of the chuk_chat app, gated by a
build flag, so it needs a name a user can read in a tab without a footnote.

**Agents.** Plain, self-explanatory, and free of trademark weight. Nobody has to
be told what it is.

The rename is deliberately scheduled for the merge into `master`, not before.
That pass rewrites every path anyway (`app/lib/…` -> `lib/…`, the Dart package
prefix back to `chuk_chat`), so one `git filter-repo` run carries the rename with
it. Renaming at any other time means a second walk through 305 commits, the
container names, the shell scripts and the service unit for nothing.

## What changes

| Thing | Today | After |
| --- | --- | --- |
| Dart feature flag | `FEATURE_AGENTS` | `FEATURE_AGENTS` |
| Dart package prefix | `package:agents` | `package:chuk_chat` (the app absorbs it) |
| Python namespace | `chuk_agents_runtime`, `chuk_agents_executor`, `chuk_agents_host`, `chuk_agents_manager`, `chuk_agents_sandbox`, `chuk_agents_crypto`, `chuk_agents_config` | `chuk_agents.runtime`, `.executor`, `.host`, `.manager`, `.sandbox`, `.crypto`, `.config` |
| Environment prefix | `AGENTS_*` | `AGENTS_*` |
| State directory | `~/.agents` | `~/.agents` |
| Config file | `~/.agents/config.toml` | `~/.agents/config.toml` |
| Images | `agents-base`, `agents-browser` | `ghcr.io/chuk-development/agents-base`, `…/agents-browser` |
| Service unit | `agents-manager.service` | `agents-manager.service` |
| Container prefix | `agents-<agent id>` | `agents-<agent id>` |

## Why `chuk_agents` and not `agents` for the Python side

A top-level `agents` package already exists in the wild — the OpenAI Agents SDK
installs exactly that name. The sandbox lets an agent `pip install` whatever a
task needs, so a bare `agents` namespace would one day be shadowed by a
dependency, and the failure would look like a broken import in unrelated code.
`chuk_agents` costs six characters and cannot collide.

## What does NOT change

Beads issue ids stay `agents-*`. They are identifiers, not names: they are
quoted in commit messages, in code comments and in the Dolt history, and
rewriting them would break every one of those references to buy nothing.

## Migration, so a running host does not break

- **Environment variables**: `chuk_agents_config` already carries each field's
  environment name as data, so the rename is one string per field. Read
  `AGENTS_*` first and fall back to `AGENTS_*` with a deprecation note for one
  release, because the systemd unit, the compose files and any shell a user
  wrote still say `AGENTS_*`.
- **State directory**: on start, if `~/.agents` is absent and `~/.agents` exists,
  move it and leave a symlink behind. The directory holds the device seed, the
  account token and the secret vault; losing track of it means re-pairing every
  device.
- **Images**: the old local tags keep working because the image is resolved by
  configuration, not by a constant.
