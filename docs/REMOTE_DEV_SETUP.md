# Remote development: agent on `claudecode`, app on the laptop

Claude Code sessions used to run on the laptop and ate its RAM while the Flutter
app, the browser and the build all competed for the same 16 GB. The agent now
runs on the `claudecode` host (16 cores, 31 GB) and drives the Flutter app that
still runs on the laptop, where it can be watched and clicked.

```text
  claudecode (agent)                        laptop (thinkpad)
  ------------------                        -----------------
  claude / herdr                            flutter-hotd  (systemd --user)
  flutter-remote  ── HTTP over Tailscale ──▶   └─ flutter-hot
  ~/git/chuk_chat  (edit + commit + push)      └─ Xephyr :90  ← the app you see
                            │                          ▲
                            └── git push ──▶ GitHub ────┘  mirror pulls
```

The agent edits and commits in its own checkout on `claudecode`. The laptop keeps
a **mirror** at `~/git/_remote/<project>`, refreshed from GitHub. The mirror is
separate on purpose: `sync` hard-resets it, and your own checkout at
`~/git/chuk_chat` must never be touched by that.

## Daily loop

From a session on `claudecode`, inside `~/git/chuk_chat`:

```bash
git push                                   # the mirror pulls from the remote
flutter-remote sync                        # fetch + hard reset the laptop mirror
flutter-remote start linux                 # non-blocking, app opens on the laptop
flutter-remote wait 240                    # block until the app is up
flutter-remote reload                      # non-blocking hot reload
flutter-remote await 30 &                  # result, in the BACKGROUND
flutter-remote shot out.png                # PNG of the app window, saved locally
```

Every `flutter-hot` verb works: `start wait reload restart await result status
logs send stop kill pids test test-await test-result test-log analyze`. The
non-blocking contract is unchanged — `reload` returns instantly, `await` runs in
the background, `result` polls.

Remote-only verbs: `health`, `projects`, `sync [ref]`, `clone <git-url>`,
`shot [out.png]`.

Run `flutter analyze` and `flutter test` locally on `claudecode` — it has the
same pinned Flutter 3.47.0 and far more cores. Only the *running app* needs the
laptop.

## Screenshots are window-only, by construction

A remote agent must never receive a picture of the whole desktop. The app is
therefore started inside its own nested X server (`Xephyr :90`), which appears on
the laptop as one ordinary window. That display contains the app and nothing
else, so even a root-window grab of it cannot leak anything. There is no code
path in `flutter-hotd` that captures the real screen; if the app window cannot be
found, the request fails instead of falling back.

This also sidesteps Wayland: GNOME refuses per-window grabs to unsandboxed
callers, and XWayland's root holds no composited content, so a native grab comes
back black. A nested X server is a real X screen that `import` can read.

Pass `{"nested": false}` to `/run` to put the app on the real desktop instead;
screenshots then require an X11 session.

**What a screenshot still contains:** the app window itself, which after
client-side decryption shows real chat content in plaintext. The PNG is written
twice — `~/.config/flutter-hotd/shots/` on the laptop and whatever path you gave
on the agent host — so both are as sensitive as the chat on screen. The daemon
keeps only the newest 20 shots per project and deletes older ones; nothing stops
a copy you took yourself from lingering, and no screenshot belongs in a commit.
Take one from a scratch or empty chat when the run does not need real data.

## Pieces

| Where | What |
|-------|------|
| laptop | `~/.claude/tools/flutter-hotd` — HTTP daemon, bound to the laptop's Tailscale address only |
| laptop | `~/.config/systemd/user/flutter-hotd.service` — `KillMode=process`, so a daemon restart does not kill running apps |
| laptop | `~/.config/flutter-hotd/token` — bearer token, generated on first start |
| laptop | `~/git/_remote/<project>` — the mirrors |
| claudecode | `/usr/local/bin/flutter-remote` — the client |
| claudecode | `~/.config/flutter-remote/{config,token}` — host, port, and the same token |

Repo copies of all three files live in `scripts/remote-dev/`.

### Endpoints

`GET /health`, `GET /projects`, `POST /sync`, `POST /run`, `POST /shot`.
Everything except `/health` needs `Authorization: Bearer <token>`. Project names
are matched against the mirror root, so no path outside it can be reached.

## Setting it up again

On the laptop:

```bash
cp scripts/remote-dev/flutter-hotd ~/.claude/tools/
cp scripts/remote-dev/flutter-hotd.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now flutter-hotd
systemctl --user import-environment DISPLAY WAYLAND_DISPLAY XAUTHORITY DBUS_SESSION_BUS_ADDRESS
```

Needs `xserver-xephyr`, `xdotool` and ImageMagick's `import`.

On the agent host:

```bash
scp laptop:~/.config/flutter-hotd/token ~/.config/flutter-remote/token
printf 'HOST=<laptop tailscale ip>\nPORT=8787\n' > ~/.config/flutter-remote/config
chmod 600 ~/.config/flutter-remote/token
flutter-remote health
flutter-remote --project chuk_chat clone git@github.com:chuk-development/chuk_chat.git
```

Then copy `.env` into the mirror once — it is gitignored, and `sync` preserves it:

```bash
# on the laptop
cp ~/git/chuk_chat/.env ~/git/_remote/chuk_chat/.env
```

Without it the mirror shows "Supabase credentials are not configured".

## Traps

- **`start` must not be bare.** The daemon runs the project's `run-hot.sh` when
  it exists, so the dart-defines match `run.sh`. A bare `flutter-hot start` drops
  every define and silently changes the feature flags.
- **Do not sync the mirror from a dirty branch.** `sync` resets to `origin/<ref>`,
  so anything not pushed is simply not there.
- **`await` and `test-await` block.** Run them in the background, as with
  `flutter-hot`.
- **A daemon restart keeps the app alive** (`KillMode=process`), but a laptop
  reboot does not. `flutter-remote start` again after a reboot.
- **The mirror is not your checkout.** `~/git/_remote/chuk_chat` gets hard-reset
  without warning; never edit in it.
