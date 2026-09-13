# Renaming CoWork to Agents

`scripts/rename_to_agents.sh` performs the rename in `docs/NAMING.md` in one
deterministic pass over the working tree. It is a text and path rewrite plus
two anchored code migrations. It does not touch git history, does not open
`.beads/`, and produces a normal working-tree change that you commit once.

Read `docs/NAMING.md` first. This file is the operator's copy: what the tool
does, what it measured, what it refuses to touch, and how to undo it.

```bash
scripts/rename_to_agents.sh --dry-run     # print every change, write nothing
scripts/rename_to_agents.sh               # do it (clean tree required)
scripts/rename_to_agents.sh --force       # do it on a dirty tree anyway
bash scripts/tests/test_rename_to_agents.sh   # 53 assertions about the rules
```

The pass is idempotent. Running it twice reports `files changed 0`.

## What it changes

| Thing | Before | After |
| --- | --- | --- |
| Dart feature flag | `FEATURE_COWORK` | `FEATURE_AGENTS` |
| Dart package | `package:cowork/…`, `name: cowork` | `package:chuk_chat/…`, `name: chuk_chat` |
| Dart classes and files | `CoworkChatStore`, `cowork_chat_store.dart` | `AgentsChatStore`, `agents_chat_store.dart` |
| Dart service folder | `app/lib/services/cowork/` | `app/lib/services/agents/` |
| Python packages | `cowork_agent`, `cowork_executor`, `cowork_host`, `cowork_manager`, `cowork_sandbox`, `cowork_crypto`, `cowork_config` | `chuk_agents_runtime`, `chuk_agents_executor`, `chuk_agents_host`, `chuk_agents_manager`, `chuk_agents_sandbox`, `chuk_agents_crypto`, `chuk_agents_config` |
| Python distributions | `cowork-agent`, … | `chuk-agents-runtime`, … |
| Environment prefix | `COWORK_*` (105 variables) | `AGENTS_*`, with a `COWORK_*` fallback |
| State directory | `~/.cowork` | `~/.agents`, migrated on start |
| Workspace metadata | `<workspace>/.cowork/` | `<workspace>/.agents/` |
| Images | `cowork-base`, `cowork-browser` | `agents-base`, `agents-browser` |
| Container names | `cowork-<agent id>` | `agents-<agent id>` |
| Service unit | `cowork-manager.service` | `agents-manager.service` |
| In-image scripts | `cowork-vnc-up`, `cowork-entrypoint`, `cowork-browser-mcp` | `agents-vnc-up`, `agents-entrypoint`, `agents-browser-mcp` |
| Linux binary | `cowork` | `agents` |
| Prose | `CoWork`, `Cowork`, `COWORK`, `cowork` | `Agents`, `Agents`, `AGENTS`, `agents` |

Case is mapped, never folded: each of the four spellings has its own rule.

### The two migrations it writes

Neither is expressible as a substitution, so the script applies them as
anchored edits after the rename, and skips them when they are already present.

**The environment fallback.** `chuk_agents_config` stores each setting's
variable name as data, so the rename is one string per field. The script adds
`FieldSpec.legacy_env`, which derives `COWORK_<NAME>` from `AGENTS_<NAME>`, and
a `_read_env` helper that reads the new name first and the old one after it
with a `DeprecationWarning`. `config_home()` does the same for `AGENTS_HOME`
and `COWORK_HOME`. The systemd unit, the compose files and any shell the user
wrote keep working for one release.

**The state directory.** `migrate_state_home()` lands in the config loader and
is called from `config_home()` and from `LocalHost.__init__`, before anything
reads the device seed, the account token or the vault. If `~/.agents` exists it
does nothing. If it does not and `~/.cowork` does, it moves the directory with
`os.replace` (atomic, same filesystem) and leaves `~/.cowork` behind as a
symlink to it. Every failure is a warning, never an exception: a host that
cannot migrate still starts.

Because the host has to import that function, the script also adds
`chuk-agents-config` to `host/pyproject.toml` and to its `[tool.uv.sources]`.

## Measured on a scratch clone

Cloned from `a8f3c9c` into `/home/user/git/cowork-rename-test`, run with
`--force`, then measured.

```
files scanned            1319
files in excluded paths     14   (.beads/, supabase/migrations/)
binary files skipped        50
files changed              841
spellings changed       10 273
paths changed              246   (each one a git mv)
migration edits applied     15
```

A second run on the committed result: `files changed 0`, `paths changed 0`,
`migration edits applied 0`.

### Test results in the scratch clone

`uv run --offline pytest -q` in each package, after `docker tag
cowork-base:latest agents-base:latest` (see "What you must do by hand").

| Package | Before | After |
| --- | --- | --- |
| `common/chuk_agents_crypto` | 65 passed | 65 passed |
| `common/chuk_agents_config` | 63 passed | 63 passed |
| `sandbox` | 107 passed | 106 passed, 1 failed |
| `manager` | 183 passed | 183 passed |
| `agent` | 960 passed, 4 skipped | 960 passed, 4 skipped |
| `executor` | 234 passed, 1 failed | 234 passed, 1 failed |
| `host` | 281 passed | 281 passed |

`executor/tests/test_regenerate.py::test_four_retries_replay_the_question_once`
fails identically before and after the rename. It is not caused by this pass.

`sandbox/tests/test_docker_environment.py::test_base_image_gives_the_agent_sudo_python_and_tmux`
is the one new failure, and it is the rename working as intended: the renamed
code expects the unix account inside the image to be `agents`, and the image
on this machine was built before the rename, so its account is still `cowork`.
Rebuilding the image from the renamed `sandbox/docker/Dockerfile` fixes it.

`cd app && flutter analyze`: **0 errors**, 40 infos and warnings, the same
lint noise the tree already had (`annotate_overrides`,
`curly_braces_in_flow_control_structures`, one `deprecated_member_use`).

`cd app && flutter test`: see "Flutter test results" below.

## What it deliberately leaves alone

Every one of these is printed, with its reason and a sample of files, at the
end of each run. The counts are from the measured pass.

| Kept | Count | Why |
| --- | --- | --- |
| Beads issue ids (`cowork-4z14`, `cowork-sha`, …) | 1 155 | They are identifiers, quoted in commit messages, code comments and the Dolt history. Renaming them breaks every cross-reference and buys nothing. `.beads/` is never opened. |
| The English word `coworker` | 895 | The product's own word for an agent. It is user-facing copy, not the product name. |
| `cowork-host` outside packaging files | 190 | Two things share this spelling: `HOST_DEVICE_ID`, which is stored as `peerDeviceId` in every paired app and rides in the `cw_device` parameter of a pairing URI, and the console script that `scripts/install.sh`, the service unit and the docs invoke. The distribution name **is** renamed to `chuk-agents-host`; the command and the device id are not. |
| Database identifiers (`cowork_chats`, `cowork_secrets`, `cowork_skill_settings`, `cowork_device_tokens`, `cowork_run_notifications`, plus the SQLite index and tokenizer names) | 152 | They name tables that already exist in Supabase and in the local SQLite files. Renaming the code would make it miss the real tables. A rename needs its own SQL migration. |
| Client storage keys (`cowork_agent_roster_v1`, `cowork.last_agent_id`, `cowork_pairing`, …) | 109 | SharedPreferences and secure-storage keys a shipped build already wrote. Renaming one silently loses that state on the user's phone. |
| Key-derivation labels (`chuk.cowork.channel-key.v1`, `cowork/pairing/sas`, `cowork/reconnect/proof-i`, …) | 60 | They are HKDF `info` strings and confirmation-transcript labels. Both ends feed them into the same derivation. A one-sided change breaks pairing; a two-sided change breaks every device already paired. |
| The URL scheme `cowork://` and the constant that builds it | 54 | `cowork://blob/<id>` and `cowork://document/<id>` are stored inside chat rows, locally and in Supabase. The scheme is data. |
| Wire message types (`cowork_pair_claim`, `cowork_answer_ready`, …) | 41 | Values a shipped build already sends. |
| The checkout path `git/cowork` | 31 | The directory this repository lives in. The script does not move it. |
| Relay topics (`cowork/controller/device/`, …) | 25 | Wire paths shared with the relay. |
| Docker labels (`cowork.managed`, `cowork.agent`, `cowork.session`, …) | 25 | The lifecycle reaper finds and stops containers by these labels. Rename them and every container an older build started becomes unreapable. |
| The application id `dev.chuk.cowork` | 20 | The Android `applicationId`, the Linux `APPLICATION_ID` (so `~/.local/share/dev.chuk.cowork` is the app's own data directory), and the native-messaging host name the browser extension connects to. Changing it ends update continuity and orphans the local data. `docs/MERGE_INTO_CHUK_CHAT.md` already tracks this decision. |
| The cross-language test vector `cowork00deadbeef` | 17 | A fixed channel id in the pairing and reconnect vectors that Python and Dart both check. |
| The document media type `application/vnd.cowork.document+json` | 7 | Stored on rows that already exist. |
| The webview bridge object (`cowork.screenshot()`, `cowork.pasteText()`, …) | 5 | Dart calls it by name and the VNC page defines it. Renaming needs both sides plus a rebuilt image. |
| The AVD name `cowork_x64` | 4 | Renaming it strands an 8 GB virtual device and makes `scripts/emulator.sh` build a new one. |
| The `github.com/chukfinley/cowork` slug | 2 | A real URL. |
| The sandbox git identity `agent@cowork.local` | 1 | The author of every commit an agent already made in a workspace. |
| `supabase/migrations/**` | 14 files | Applied migrations are immutable. The tables they create are renamed by a new migration, never by editing an old one. |
| `scripts/rename_to_agents.sh`, `scripts/tests/`, `docs/RENAME_RUNBOOK.md` | 3 files | They quote the old spellings on purpose. |

Unclassified `cowork-<word>` spellings — workstream names in German and
English prose (`cowork-only`, `cowork-Dateien`, `cowork-mobile`), and the
handover filenames that carry a beads id (`HANDOVER_…_cowork-47.md`) — fall
into the beads-id rule and stay. That is the safe default: the tool renames
what a rule names and keeps what no rule names.

## What you must do by hand afterwards

1. **Rebuild the sandbox images.** The renamed code expects `agents-base` and
   `agents-browser`, and expects the unix account inside them to be `agents`.
   ```bash
   docker build -t agents-base:latest   -f sandbox/docker/Dockerfile         sandbox/docker
   docker build -t agents-browser:latest -f sandbox/docker/Dockerfile.browser sandbox/docker
   ```
   `docker tag cowork-base:latest agents-base:latest` is enough to make most
   tests run, but not enough for the one that checks the account name.
2. **Refresh the lock files.** `uv.lock` carries the distribution names, which
   the pass rewrote, but `host/pyproject.toml` gained one dependency.
   ```bash
   for p in agent executor host manager sandbox common/chuk_agents_config common/chuk_agents_crypto; do (cd "$p" && uv lock); done
   ```
3. **Reinstall the service unit.** `scripts/install.sh` writes
   `~/.config/systemd/user/agents-manager.service` now. The old
   `cowork-manager.service` stays behind and must be stopped and removed:
   ```bash
   systemctl --user disable --now cowork-manager.service
   rm -f ~/.config/systemd/user/cowork-manager.service
   scripts/install.sh
   ```
4. **Check the state directory once.** Start the host and confirm that
   `~/.agents` holds the device seed, the account token and the vault, and that
   `~/.cowork` is a symlink to it. The app must not ask to pair again.
5. **Re-run the Flutter goldens if they were green before.** The previews in
   `docs/screenshots/c6/` are compared pixel by pixel.
6. **Read the `AgentsAgent` / `agents_agent.dart` names.** The mechanical rule
   produces a few doubled names on the Dart side (`CoworkAgent` becomes
   `AgentsAgent`, `app/lib/models/cowork_agent.dart` becomes
   `agents_agent.dart`). They compile and the analyzer is clean, but the merge
   into `chuk_chat` is the moment to give them better names.
7. **Decide about `cowork-host` and `dev.chuk.cowork`.** Both stayed on
   purpose. Renaming the console script is a one-line change plus the docs;
   renaming the device id and the application id are data migrations with their
   own risk, and belong in their own change.

## Rolling back

The pass is one commit, so:

```bash
git revert <the rename commit>
```

That is complete for the repository. It is **not** complete for the machine:

* **The state directory has already moved.** After the renamed host has run
  once, the device seed, the account token and the vault live in `~/.agents`,
  and `~/.cowork` is a symlink to it. The reverted code reads `~/.cowork`,
  follows the symlink, and finds everything — so a revert works, but only while
  the symlink is there. Do not delete it. If it is already gone, move the
  directory back before starting the old code:
  ```bash
  mv ~/.agents ~/.cowork
  ```
  Getting this wrong means the host mints a new device identity and every
  paired device has to pair again.
* **The images and the unit were renamed by hand** (steps 1 and 3 above), so
  undo those by hand too.
* **`COWORK_*` still works** in the renamed code, so a half-rolled-back
  environment is not a failure mode; `AGENTS_*` in a reverted tree is.

## How the rules work, if you need to change one

The rule table is at the top of the Python block inside
`scripts/rename_to_agents.sh`. It is an ordered list of
`(name, pattern, replacement, scope)`; the first rule that matches at a
position wins, and a replacement of `KEEP` pins the match so no later rule can
touch it. `scope` restricts a rule to packaging files (`pyproject.toml`,
`uv.lock`), to non-packaging files, to `app/`, to everything outside `app/`, or
to `app/pubspec.yaml`.

Three consequences worth knowing:

* **Longer spellings go first.** `cowork-manager.service` is above
  `cowork-manager`, `cowork-host-party` is above `cowork-host`.
* **The beads catch-all is last.** `cowork-[0-9A-Za-z][0-9A-Za-z-]*` pins
  everything that no earlier rule claimed, so a spelling nobody named is kept,
  not renamed. Adding a name means adding a rule above that line.
* **A line ending in `# rename: keep` is exempt.** The migration code uses it
  for the three constants that have to spell the pre-rename names in order to
  read them.

Add a case to `scripts/tests/test_rename_to_agents.sh` whenever you add a rule.
It builds throwaway git repositories, so it is fast and touches nothing real.

## Flutter test results

`cd app && flutter test`, in the scratch clone and in a second clone of the
same baseline commit.

| | Before | After |
| --- | --- | --- |
| Passed | 1441 | 1441 |
| Skipped | 3 | 3 |
| Failed | 8 | 8 |

The same eight, both times: four golden comparisons in
`platform_specific/mobile/mobile_preview_test.dart` against
`docs/screenshots/c6/`, and four in `widgets/charts/document_chart_golden_test.dart`.
They fail before the rename as well. The rename adds none.

Getting there took three rules the first pass did not have, and each is worth
knowing about because the same shape will come up again:

* **A constant's value can be the thing you must not rename.**
  `kCoworkPairingUriScheme = 'cowork'` builds and parses `cowork://`. The
  identifier had to move and the value had to stay. Two dozen Flutter tests
  failed until the value was pinned separately from the identifier.
* **An interpolated name must move with the literals that assert on it.**
  `'cowork-chat-${threadKey}-…'` looked like a beads id to the catch-all rule
  and stayed, while the test literal `cowork-chat-busy-thread-0-0` moved.
  Rule 13b now claims any `cowork-` that is finished by `$`, `{` or `%`.
* **A backreference inside a combined regex points at the wrong group.** The
  rules are compiled into one alternation, so `\1` in a replacement counted
  groups across every rule, not inside the one that matched, and
  `cowork-pairing-use-code` became `agents-pairing-`. Each rule now keeps a
  standalone copy of its own pattern and expands against that.
