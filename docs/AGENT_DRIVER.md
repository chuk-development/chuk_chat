# Agent driver

The agent driver lets an AI agent use the real app. The agent starts the
Linux app against the local E2E stack, taps, types, reads the screen and
takes screenshots. The driver is an MCP server on stdin and stdout.

Bead: `chuk_chat-q7z0`. Policy: `docs/VERIFICATION.md`.

## Parts

| Path | Content |
|------|---------|
| `test_driver/main_agent.dart` | App entry point: `lib/main.dart` plus the Flutter Driver extension |
| `test_driver/agent_extensions.dart` | The `Agent` finder and the `ext.chuk.agent.*` service extensions (screenshot, state, focus, tapAt) |
| `tool/agent_driver/bin/agent_driver.dart` | The MCP server. With `--script`, it runs a walk file |
| `tool/agent_driver/src/` | App start and stop, safety rules, tools, MCP protocol |
| `tool/agent_driver/walks/smoke.json` | Default walk: sign in, send a message, read the answer |
| `scripts/verify_ui.sh` | Runs a walk and writes the screenshots to `_scratch/verify/` |
| `test/agent_driver/` | Tests of the driver |

The release app does not contain the driver. Only the debug entry point
`test_driver/main_agent.dart` imports it.

## Safety rules

The driver applies these rules on each start. The agent cannot turn them
off.

1. The app gets its own data folders: `XDG_DATA_HOME`, `XDG_CACHE_HOME` and
   `XDG_STATE_HOME` go to `_scratch/agent_home/`. Without this, the debug
   app uses `~/.local/share/dev.chuk.chat`, the folder of the installed app,
   and replaces its login and chat cache. The driver refuses a home folder
   that is not inside `_scratch/`.
2. `CHUK_MULTI_INSTANCE=1`, so the app starts when the installed app runs.
3. `API_BASE_URL` and `SUPABASE_URL` must be loopback addresses. The driver
   refuses to start against production.
4. By default the app runs under `xvfb-run`. No window opens on the desktop.
   Screenshots come from the app itself (the root `RepaintBoundary` of
   `lib/main.dart`). They show the app only, never the desktop.

These are the same rules as `docs/INTEGRATION_TESTS.md`.

## Before you start

Start the local stack, if it does not run. Do not stop a stack that another
agent uses.

```bash
E2E_EMULATOR_PORT=8797 scripts/e2e_stack.sh up
```

The driver reads `_scratch/e2e.defines.json`. The test user is in
`docs/E2E_STACK.md`.

## Run a walk

```bash
scripts/verify_ui.sh                       # tool/agent_driver/walks/smoke.json
scripts/verify_ui.sh my_walk.json          # your walk file
scripts/verify_ui.sh --headed              # window on the desktop
```

A walk file is a JSON list of tool calls:

```json
[
  {"tool": "wait_for", "args": {"by": "semantics_id", "value": "login_email_field", "timeout_ms": 120000}},
  {"tool": "enter_text", "args": {"by": "semantics_id", "value": "login_email_field", "text": "{{E2E_EMAIL}}"}},
  {"tool": "screenshot", "args": {"name": "01_sign_in", "inline": false}}
]
```

- The runner adds `app_start` at the start, if the file has none. It always
  stops the app at the end.
- `{{KEY}}` in a string becomes the value of `KEY` in the defines file, for
  example `{{E2E_EMAIL}}` and `{{E2E_PASSWORD}}`. The log shows the
  placeholder, not the value.
- The first failed call stops the walk. The script prints the last app log
  lines and exits with code 1.

After the walk, open each PNG and compare it with the task.

## Use it as an MCP server

Register the server once in Claude Code (local scope):

```bash
claude mcp add chuk-app -- dart run tool/agent_driver/bin/agent_driver.dart
```

Run the command from the repository root. The server finds the repository
root from its own path.

A typical session:

1. `app_start` (first build: some minutes; later: about 20 s).
2. `read_state` to see the texts, tooltips, Semantics identifiers, icons and
   text fields, each with its rectangle.
3. `tap`, `enter_text`, `wait_for`, `scroll` or `tap_at`.
4. `screenshot` after each step that changes the screen. The result has the
   image and the path `_scratch/agent_shots/<name>.png`.
5. `hot_reload` after a code change. `full_restart: true` for a hot restart.
6. `app_stop` at the end. When the MCP server stops, it also stops the app.

### Tools

| Tool | Arguments | Effect |
|------|-----------|--------|
| `app_start` | `headless` (true), `fresh` (true), `defines_file` | Builds and starts the app. `fresh: false` keeps the login of the last run |
| `app_stop` | | Stops the app and xvfb. Also stops an app that a crashed driver left |
| `app_status` | | Running or not, folders, log file |
| `read_state` | `include_hidden` (false) | Items on the screen with rectangles. By default only items that a tap at their centre reaches |
| `tap` | finder, `timeout_ms` | Waits until a match can receive a tap, then taps it |
| `tap_at` | `x`, `y` | Taps a point in logical pixels |
| `enter_text` | `text`, optional finder | Focuses the text field in or around the match, then sets its text |
| `wait_for` | finder, `absent`, `timeout_ms` (30000) | Waits until the widget is there (or gone) |
| `scroll` | finder, `dx`, `dy`, `duration_ms` | Drags from the centre of the widget |
| `screenshot` | `name`, `inline` (true) | PNG of the whole app, all routes and dialogs |
| `wait` | `ms` | Waits, for example for an animation |
| `hot_reload` | `full_restart` | Hot reload or hot restart |
| `logs` | `lines` (100) | Last lines of the app output |

A finder has three arguments:

| Argument | Values |
|----------|--------|
| `by` | `text`, `text_contains`, `tooltip`, `semantics_id`, `semantics_label`, `key`, `type`, `icon` |
| `value` | The text, Semantics identifier, `ValueKey<String>`, class name, or icon code point (`0xf57e`) |
| `index` | Which match, when more widgets match (default 0) |

Use `read_state` to find good values. Do not guess. Prefer Semantics
identifiers and tooltips to texts.

Screenshot pixels are logical pixels (pixel ratio 1). A point in a
screenshot is the same point for `tap_at`.

## Things to know

- The driver turns off frame sync. The app has animations that do not stop,
  so a driver command would wait for ever. Use `wait_for` instead.
- `screenshot` and `read_state` force a new frame first. Without this, a
  capture under xvfb can show the screen before the last command.
- The driver types with Flutter Driver text entry emulation. A real keyboard
  does not reach the app while the driver runs.
- `enter_text` replaces the value of the field. It does not press Enter.
  Tap the send button to send a message (the send button is the icon
  `0xf57e`).
- The app home stays in `_scratch/agent_home/` after a run. `fresh: true`
  (the default) deletes it at the next start.
- The driver and the integration tests use the same build folder
  (`build/linux/x64/debug`). Do not run them at the same time in the same
  worktree.
- Files: app log `_scratch/agent_driver/app.log`, process group id
  `_scratch/agent_driver/app.pgid`.

## Tests

```bash
flutter test test/agent_driver
```

The tests cover the safety rules, the tool layer and the MCP protocol with
a fake app, and the app side (finder, state, focus, capture, tap) in widget
tests. The end-to-end check is `scripts/verify_ui.sh` against the local
stack.
