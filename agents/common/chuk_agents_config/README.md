# chuk_agents_config

The one typed configuration for every Agents process.

Before this package Agents had no configuration file. Each process read what it
needed straight from the environment, at the point of use, with its own
spelling of the precedence rule and its own default written inline — about
forty `AGENTS_*` variables spread over `host/`, `executor/`, `manager/`,
`agent/` and `sandbox/`. Nobody could list them, nothing validated them, a typo
was invisible, and the only way to learn what one did was to find the line that
read it.

This package is the source of truth instead: frozen dataclasses, one per
subject, each field carrying its own environment variable name and its own
prose.

```python
from chuk_agents_config import load_config, get_value, set_value, save_config

config = load_config()                         # $AGENTS_HOME/config.toml
config.sandbox.image                           # typed
get_value(config, "model.default")
config = set_value(config, "model.default", "claude-opus-5")
save_config(config)                            # $AGENTS_HOME/config.toml, 0600, atomic
```

## Precedence

    explicit argument  >  environment variable  >  config.toml  >  built-in default

Every field knows its own environment variable, so the rule is applied by
walking the schema, not by a chain of `if` statements. A new setting obeys it
the moment it is declared.

**The environment sits above the file on purpose.** A deployment that exports
`AGENTS_SANDBOX_IMAGE` today keeps winning after a `config.toml` appears, so
docker-compose, the systemd unit and the existing test suites are unaffected by
this package landing. Nothing that runs now changes behaviour.

The explicit-argument layer is a mapping of dotted paths, which is what a
command-line flag becomes:

```python
config = load_config(overrides={"model.default": "claude-opus-5"})
```

## The file

`$AGENTS_HOME/config.toml`, default `~/.local/share/chuk-agents/config.toml`
(`$XDG_DATA_HOME/chuk-agents`; not `~/.agents`, which other tools share). It is parsed with
the standard library's `tomllib`; this package has no third-party dependency.

```toml
version = 1

[sandbox]
kind = "docker"
image = "agents-browser:latest"

[model]
default = "claude-opus-5"
```

A missing file is not an error — a fresh install starts on the defaults. A file
that exists and is wrong **is** an error, and a loud one: an unknown key, a
wrong type or a value outside an enum raises a single `ConfigError` listing
every problem with its `section.key` path and the file line.

```
4 problems in the Agents configuration:
  - sandbox.kind: expected one of 'auto', 'local', 'docker', got 'podman' [/home/u/.agents/config.toml:3]
  - vnc.port: expected an integer, got the string '5900' [/home/u/.agents/config.toml:5]
  - vnc.prot: is not a known setting; the keys of [vnc] are allow_no_password, log_path, pass_file, port, xdamage [/home/u/.agents/config.toml:6]
  - nosuch: is not a known section; expected one of automation, browser, ... [/home/u/.agents/config.toml:7]
```

The loader never falls back to a default for a value it could not read. A typo
that silently becomes the default is how an agent runs all night on the wrong
model.

## Writing

`save_config(config, path)` writes the file with `os.open(..., 0o600)` into a
temporary file and then `os.replace` — the same atomic, private pattern the
account store uses. A reader never sees a half-written file, and the mode is
set at creation, so there is no window in which the file is world readable.

The round trip is lossless for every field: `load_config(save_config(c)) == c`.
Pass `include_defaults=False` to write only what differs from the built-in
defaults, so a later Agents whose defaults moved still reaches the install; the
trade is that the file no longer shows the full list.

## Back to the environment

Several parts of Agents are shell scripts inside a container image —
`vnc-up.sh`, `browser-mcp.sh`, `entrypoint.sh`, `emulator.sh` — and a shell
script cannot read TOML. `export_environ(config)` turns the configuration back
into the `AGENTS_*` variables those scripts already read, so the file stays the
source of truth even where the consumer is `${AGENTS_VNC_PORT:-5900}`.

```python
env = export_environ(config)          # only what differs from the defaults
subprocess.run(argv, env={**os.environ, **env})
```

## Secrets

**No secret is ever a field of this schema.** A key, a token or a password in a
TOML file is one in every backup, bug report and screenshot of that file.

A setting that needs a credential holds a **reference**: the field is named
`*_key_ref` (or `*_token_ref`) and its value is the *name* of an entry in the
encrypted vault the host already keeps. The process resolves that name at the
moment of use, never at load.

```toml
[model]
api_key_ref = "anthropic-work"    # a vault entry name, never a key
```

`tests/test_no_secrets.py` enforces the rule: a string field whose name
contains `token`, `password`, `passwd`, `api_key`, `secret` or `credential` and
does not end in `_ref` fails the build. The three secret-carrying environment
variables in the tree (`AGENTS_ACCOUNT_TOKEN`, `AGENTS_VNC_PASSWD`,
`AGENTS_MEM_EMBED_API_KEY`) are deliberately **not** settings; see the table
below.

## Version and the upgrade path

The file carries `version = 1` on its first line.

The number changes only when a file written by an older Agents can no longer be
read field-for-field: a key was renamed, a type changed, or a value's meaning
changed. **Adding a key does not need it** — an absent key takes its default,
which is exactly what the old file meant.

When it does change, add the migration to `_MIGRATIONS` in `loader.py`: a
function from the raw table of version *n* to the raw table of version *n* + 1.
The loader chains them, so a version 1 file still loads after version 4 ships,
and the next `save_config` writes the new number. A file whose version is
*higher* than this build's is refused with a named error rather than half-read:
a newer Agents wrote it, and guessing at a key this build has never seen is how
an agent ends up running with the wrong model.

## Behaviour notes

- **An empty environment variable counts as unset.** `AGENTS_BROWSER_DISPLAY=""`
  gives `:99`, not `""`. That is what the shell scripts already do
  (`${AGENTS_BROWSER_DISPLAY:-:99}`), and it is the only rule that keeps an
  exported-but-empty variable from silently blanking a setting. One small
  difference from the old code: `AGENTS_RUN_MAX_SECONDS=""` used to mean `0`
  (guard off) because of `float(... or 0)`; it now means the default. Write
  `AGENTS_RUN_MAX_SECONDS=0` to turn the guard off.
- **Booleans** accept `1/true/yes/on` and `0/false/no/off`, in any case.
- **An integer is accepted where a number is wanted**, so
  `run_max_seconds = 60` is not an error.
- **`paths.home` in the file moves the state directory, not the file.** The
  file's own location is settled before it is read. Move the file itself with
  `$AGENTS_HOME` or an explicit path.

## Migration guide: environment variable to config key

This table is the migration guide and the inventory at once. Every `AGENTS_*`
name in the tree is here — as a setting, or in "Not settings" with the reason.
`tests/test_env_coverage.py` greps the repository and fails when a name appears
that is in neither list, so this table cannot fall behind the code.

| environment variable | config key | type | default | meaning |
| --- | --- | --- | --- | --- |
| `AGENTS_HOME` | `paths.home` | string | `~/.local/share/chuk-agents` | The host state directory (`COWORK_HOME` is still read after it): the agent workspaces, the logs, the account store, the encrypted vault and this configuration file itself. |
| `AGENTS_SANDBOX_KIND` | `sandbox.kind` | `auto`, `local`, `docker` | `auto` | Which backend runs the agent's commands. |
| `AGENTS_SANDBOX_IMAGE` | `sandbox.image` | string | *(empty)* | The container image every sandbox starts from. |
| `AGENTS_SANDBOX_IMAGE_DIGEST` | `sandbox.image_digest` | string | *(empty)* | A `sha256:...` digest the image must have. |
| `AGENTS_RUNTIME` | `sandbox.runtime` | string | *(empty)* | The container runtime binary: `docker`, `podman` or a path. |
| `AGENTS_WORKSPACE` | `sandbox.workspace` | string | `/workspace` | Where the agent's working directory is mounted **inside** the container. |
| `AGENTS_USER` | `sandbox.user` | string | `agents` | The unprivileged account inside the image that commands run as. |
| `AGENTS_UID` | `sandbox.uid` | integer | `0` | The host user id the container's account is remapped to, so a file the agent writes in the workspace belongs to the person who started Agents and not to root. |
| `AGENTS_GID` | `sandbox.gid` | integer | `0` | The host group id, with the same rule as `uid`. |
| `AGENTS_TEST_IMAGE` | `sandbox.test_image` | string | `debian:stable-slim` | The image the container tests pull. |
| `AGENTS_BROWSER_TARGET` | `browser.target` | `sandbox`, `user_browser` | `sandbox` | Which browser a task drives: the Chromium inside the sandbox, or the browser the user already has open, through the add-on. |
| `AGENTS_BROWSER_HEADLESS` | `browser.headless` | boolean | `false` | Run the browser with no display. |
| `AGENTS_BROWSER_AUTO_OPEN` | `browser.auto_open` | boolean | `true` | Open the browser window as soon as a browser server is connected, instead of waiting for the agent's first navigation. |
| `AGENTS_BROWSER_HOME` | `browser.home_url` | string | `about:blank` | Where the forced first navigation goes on a browser server that has no tab-listing call. |
| `AGENTS_BROWSER_CDP_URL` | `browser.cdp_url` | string | *(empty)* | Attach to a browser somebody else runs, over the Chrome DevTools Protocol: the published port of the browser image, or the user's own Chrome started with `--remote-debugging-port`. |
| `AGENTS_BROWSER_EXECUTABLE` | `browser.executable` | string | *(empty)* | A specific Chromium or Chrome binary. |
| `AGENTS_BROWSER_PROFILE` | `browser.profile` | string | `/workspace/.agents/chrome-profile` | The persistent Chromium profile directory. |
| `AGENTS_BROWSER_DISPLAY` | `browser.display` | string | `:99` | The X display the browser paints on and the live view reads. |
| `AGENTS_BROWSER_SCREEN` | `browser.screen` | string | `1280x800x24` | Geometry of the virtual display, as `WIDTHxHEIGHTxDEPTH`. |
| `AGENTS_BROWSER_VIEWPORT` | `browser.viewport` | string | `1280x800` | The browser window size, as `WIDTHxHEIGHT`. |
| `AGENTS_BROWSER_CURSOR_THEME` | `browser.cursor_theme` | string | `DMZ-White` | The X cursor theme. |
| `AGENTS_BROWSER_CURSOR_SIZE` | `browser.cursor_size` | integer | `64` | The cursor size in pixels. |
| `AGENTS_BROWSER_RETIRED_HOSTNAME` | `browser.retired_hostname` | string | *(empty)* | The hostname of the container that last owned the browser profile. |
| `AGENTS_EXTENSION_MCP` | `browser.extension_mcp` | string | *(empty)* | Path to the `agents-extension-mcp` server that drives the user's own browser. |
| `AGENTS_VNC_PORT` | `vnc.port` | integer | `5900` | The RFB port x11vnc binds **inside** the container. |
| `AGENTS_VNC_PASS_FILE` | `vnc.pass_file` | string | `/run/agents-vnc.pass` | The root-only file x11vnc re-reads on every client connect. |
| `AGENTS_VNC_ALLOW_NOPW` | `vnc.allow_no_password` | boolean | `false` | Let x11vnc start with no password. |
| `AGENTS_VNC_LOG` | `vnc.log_path` | string | `/tmp/x11vnc.log` | Where x11vnc's output goes inside the container. |
| `AGENTS_VNC_XDAMAGE` | `vnc.xdamage` | boolean | `true` | Use the X DAMAGE extension to find changed screen regions. |
| `AGENTS_DOC_MAX_BYTES` | `documents.max_bytes` | integer | `20971520` | The largest file `read_document` will pull out of the sandbox. |
| `AGENTS_DOC_MARKDOWN_CAP` | `documents.markdown_cap` | integer | `60000` | How much of the converted Markdown reaches the model. |
| `AGENTS_DOC_VISION_MODEL` | `documents.vision_model` | string | `qwen/qwen3.6-35b-a3b` | The model that reads a scan or a photograph. |
| `AGENTS_DOC_VISION_TIMEOUT_SECONDS` | `documents.vision_timeout_seconds` | number | `180.0` | How long one vision read may take before it is given up. |
| `AGENTS_DOC_VISION_MAX_IMAGE_BYTES` | `documents.vision_max_image_bytes` | integer | `20971520` | The per-image ceiling the backend enforces. |
| `AGENTS_MODEL_DEFAULT` | `model.default` | string | `deepseek/deepseek-v4-flash` | The model a new session uses when the app names none. |
| `AGENTS_MODEL_PROVIDER` | `model.provider` | string | *(empty)* | The provider slug new autonomous sessions route through. |
| `AGENTS_MODEL_REASONING_EFFORT` | `model.reasoning_effort` | string | *(empty)* | The default reasoning effort for new autonomous sessions. |
| `AGENTS_MODEL_API_KEY_REF` | `model.api_key_ref` | string | *(empty)* | The **name** of the vault entry holding the model API key, never a key. |
| `AGENTS_MEM_COLLECTION` | `memory.collection` | string | `cowork_memory` | The vector collection memories are written to and read from. |
| `AGENTS_MEM_USER_ID` | `memory.user_id` | string | `default` | The owner a memory is filed under. |
| `AGENTS_MEM_QDRANT_DIRNAME` | `memory.qdrant_dirname` | string | `qdrant` | The directory inside the workspace that holds the embedded vector store. |
| `AGENTS_MEM_LLM_MODEL` | `memory.llm_model` | string | `agents-memory-writer` | The model that decides what is worth remembering. |
| `AGENTS_MEM_EMBED_PROVIDER` | `memory.embed_provider` | `proxy`, `fastembed` | `proxy` | Where embeddings come from: `proxy` is the hosted embedding route, `fastembed` is a local model with no network at all. |
| `AGENTS_MEM_EMBED_BASE_URL` | `memory.embed_base_url` | string | `https://api.chuk.chat/v1` | The base URL of the hosted embedding route. |
| `AGENTS_MEM_EMBED_MODEL` | `memory.embed_model` | string | `qwen3-embedding-8b` | The hosted embedding model. |
| `AGENTS_MEM_EMBED_DIMS` | `memory.embed_dims` | integer | `1024` | The output dimension of the embedding model. |
| `AGENTS_MEM_EMBED_API_KEY_REF` | `memory.embed_api_key_ref` | string | *(empty)* | The **name** of the vault entry holding the embedding API key, never a key. |
| `AGENTS_MEM_FASTEMBED_MODEL` | `memory.fastembed_model` | string | `nomic-ai/nomic-embed-text-v1.5` | The local embedding model used when `embed_provider` is `fastembed`. |
| `AGENTS_MEM_FASTEMBED_DIMS` | `memory.fastembed_dims` | integer | `768` | The output dimension of the local model. |
| `AGENTS_DESKTOP_NOTIFY` | `notify.desktop` | boolean | `true` | Show a desktop notification on the machine Agents runs on. |
| `AGENTS_NOTIFY_ICON` | `notify.icon` | string | *(empty)* | The icon name or path the desktop notification shows. |
| `AGENTS_NTFY_TOPIC` | `notify.ntfy_topic` | string | *(empty)* | An ntfy.sh topic to publish completions to. |
| `AGENTS_WEBHOOK_URL` | `notify.webhook_url` | string | *(empty)* | A URL that receives the same keyless completion notice as a POST. |
| `AGENTS_SEED_SKILLS` | `skills.seed_dir` | string | *(empty)* | The directory the shipped seed skills are copied from. |
| `AGENTS_RELAY_URL` | `relay.url` | string | `wss://api.chuk.chat` | The cloud relay base URL. |
| `AGENTS_RELAY_LOCAL` | `relay.local` | boolean | `false` | Run the blind relay on this machine's loopback instead of dialling the cloud. |
| `AGENTS_RELAY_PORT` | `relay.local_port` | integer | `8787` | The TCP port the loopback relay binds. |
| `AGENTS_RUN_MAX_SECONDS` | `limits.run_max_seconds` | number | `7200.0` | Wall clock guard on one run. |
| `AGENTS_RUN_ACK_TIMEOUT_SECONDS` | `limits.run_ack_timeout_seconds` | number | `15.0` | How long a run that ended with an app attached may go without the app's acknowledgement before it is announced as finished while away. |
| `AGENTS_APPROVAL_WAIT_SECONDS` | `limits.approval_wait_seconds` | number | `600.0` | How long an approval prompt waits for the user before it gives up and denies. |
| `AGENTS_SECRET_REQUEST_TIMEOUT_SECONDS` | `limits.secret_request_timeout_seconds` | number | `600.0` | How long a request for a credential waits before every open name is reported missing. |
| `AGENTS_JOB_TIMEOUT_SECONDS` | `limits.job_timeout_seconds` | number | `86400.0` | The fallback cap on one background job started from the shell tools. |
| `AGENTS_HEARTBEAT_SECONDS` | `limits.heartbeat_seconds` | number | `10.0` | How often a running turn sends a `heartbeat` event to the app. `0` turns it off. |
| `AGENTS_TRACE` | `trace.enabled` | boolean | `false` | Developer switch: write a JSONL run trace (structure only). Same as `agents-host run --trace`. |
| `AGENTS_TRACE_CONTENT` | `trace.content` | boolean | `false` | Developer switch: also trace message content, scrubbed. Implies `trace.enabled`. |
| `AGENTS_TRACE_DIR` | `trace.directory` | string | *(empty)* | Where the trace goes; empty means `<state directory>/trace`. |
| `AGENTS_TRACE_MAX_BYTES` | `trace.max_bytes` | integer | `16777216` | The size at which the trace file rolls over. |
| `AGENTS_TRACE_BACKUPS` | `trace.backups` | integer | `3` | How many rolled-over trace files are kept. |
| `AGENTS_TRIGGERS_PATH` | `automation.triggers_path` | string | `.agents/automations/triggers.jsonl` | The file a watcher appends a trigger line to. |
| `AGENTS_AVD` | `emulator.avd` | string | `cowork_x64` | The name of the virtual device, created on first start. |
| `AGENTS_AVD_IMAGE` | `emulator.image` | string | `system-images;android-36;google_apis;x86_64` | The system image the device is created from. |
| `AGENTS_AVD_DEVICE` | `emulator.device` | string | `pixel_7_pro` | The hardware profile, matching the physical phone. |
| `AGENTS_AVD_RAM` | `emulator.ram_mb` | integer | `4096` | Memory given to the virtual device, in megabytes. |
| `AGENTS_AVD_DATA` | `emulator.data_gb` | integer | `8` | Size of the device's data partition, in gigabytes. |
| `AGENTS_AVD_GPU` | `emulator.gpu` | string | `host` | The rendering mode. |
| `AGENTS_AVD_LOG` | `emulator.log_path` | string | `/tmp/agents-emulator.log` | Where the emulator's own output goes. |
| `AGENTS_AVD_EXTRA` | `emulator.extra_args` | string | *(empty)* | Extra arguments appended to the emulator command line, unquoted. |
| `AGENTS_AVD_SOFT_KEYBOARD` | `emulator.soft_keyboard` | boolean | `false` | Show the on-screen keyboard. |

### Not settings

| name | why not |
| --- | --- |
| `AGENTS_ACCOUNT_TOKEN` | A secret. The paired account's bearer token; it belongs to the account store and the encrypted vault, never to a file a person edits. A setting that needs it uses a `*_key_ref` name instead. |
| `AGENTS_VNC_PASSWD` | A secret, and a per-view one: the executor generates a fresh value for every live view and passes it to the container on that one call. It has no default and no persistent value to configure. |
| `AGENTS_MEM_EMBED_API_KEY` | A secret. Replaced by the setting `memory.embed_api_key_ref`, which names a vault entry instead of holding a key. |
| `AGENTS_AUTOMATION_ID` | A per-process handle, not a setting. The host sets it on a watcher process so the process can name the watcher it is; there is no machine-wide value to configure. |
| `AGENTS_AGENT_PLATFORM_PLAN` | Not a variable. It is part of the filename `docs/AGENTS_AGENT_PLATFORM_PLAN.md` in a docstring. |
| `AGENTS_CWD` | Not a variable. It is part of the random shell marker `__AGENTS_CWD_<hex>__:` the local sandbox prints to find the working directory after a command. |
| `AGENTS_CWD_` | Not a variable. The same shell marker, matched one character longer. |
| `AGENTS_RELAY` | Not a variable. It is the Python constant `TYPE_AGENTS_RELAY`, the name of a frame type on the wire. |
| `AGENTS_ERROR` | Not a variable. It is the Python constant `TYPE_AGENTS_ERROR`, the name of a frame type on the wire. |
| `AGENTS_VNC_REVISION` | Not a variable. `vnc-up.sh` assigns it itself as a cache buster in the VNC desktop name; it is never read from the environment. |

## Develop

```bash
uv run pytest -q
```
