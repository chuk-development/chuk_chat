---
name: terminal
description: Run commands in your own sandbox the right way. Short command -> run_command. Long command (build, download, install, training) -> run_command with background=true, you are woken when it ends. Program that asks questions, shows a menu or a TUI (apt, pip prompts, wizards, ssh, vim, a REPL) -> shell_start / shell_read / shell_send. Use whenever a command may take long, may ask "y/n", or must keep running while you work.
metadata:
  version: "1.0"
---

# Terminal: foreground, background, interactive

The sandbox is yours. You are user `agents` with passwordless `sudo`, so you
can install anything: `sudo apt-get install -y ...`, `pip install ...`,
`npm install -g ...`. If you break it, you fix it. Keep the workspace clean:
your files go in the workspace, scratch goes in `/tmp` or a folder you delete
when done.

Three ways to run a command. Pick the one that fits.

## 1. Short and blocking: `run_command`

Runs one command and returns exit code, stdout and stderr. Default timeout
120 s. Use it for anything that ends in seconds: `ls`, `git status`, a test
run, a script.

## 2. Long: `run_command` with `background: true`

For a build, a download, an install, a training run, a server you want to
keep up. It returns at once:

```json
{"ok": true, "job_id": "j3f9a12b0", "log_path": ".agents/jobs/j3f9a12b0.log", "pid": 4711, "state": "running"}
```

Then go on with other work, or end your turn. **You are woken when the job
ends**: the job's result arrives as a message
`[job j3f9a12b0 finished: exit 0]` with the command and the last 200 lines of
its log. If your turn is still running, it arrives in your turn. If your turn
is over, a new turn starts with it and the user is notified. You do not need
to poll.

- `job_status(job_id)` — state, exit code, clocks, log size. Without a
  `job_id`: every job of this workspace.
- `job_output(job_id, lines=200, offset=0)` — the last `lines` lines, or a
  window from line `offset`. `total_lines` tells you how much there is. The
  whole log is a file: `read_file(".agents/jobs/<job_id>.log")`.
- `job_cancel(job_id)` — stop it (SIGTERM, then SIGKILL).

A job has no timeout except a 24 h cap. Its output goes only to the log, so
redirect nothing yourself. It runs with the same environment as
`run_command`, including the user's secrets.

## 3. Interactive: `shell_start` / `shell_read` / `shell_send`

For a program that talks back: `Continue? [y/n]`, a menu, a wizard, a TUI, a
password prompt, `ssh`, `vim`, `python -i`, `git rebase -i`. The shell is a
tmux session in your sandbox that lives between your tool calls.

The loop is: start -> read -> send -> read.

```
shell_start(name="apt", command="sudo apt-get install ffmpeg")
  -> screen ends with "Do you want to continue? [Y/n]", running: true, foreground: "apt-get"
shell_send(name="apt", keys=["y", "Enter"])
  -> screen shows the install running
shell_read(name="apt")
  -> running: false, foreground: "bash": the program is done, the prompt is back
shell_kill(name="apt")
```

What a read gives you:

- `screen` — the last 200 lines including scrollback (ask for more with
  `lines`, up to 2000; the cap is 30 000 characters).
- `running` — `true` while a program other than the shell is in the
  foreground. `false` means the shell waits for a command.
- `foreground` — the name of that program (`apt-get`, `python3`, `vim`).
- `cursor_line` — the line the cursor is on: the prompt, or the question.

How to send:

- `keys` is a list. A key token is pressed, everything else is typed.
  Tokens: `Enter`, `Tab`, `Escape`, `Space`, `Up`, `Down`, `Left`, `Right`,
  `Home`, `End`, `PageUp`, `PageDown`, `BSpace`, `Delete`, `F1`..`F12`,
  `C-c` (Ctrl-C), `C-d`, `M-x` (Alt-x).
- `["y", "Enter"]` answers a yes/no prompt. `["C-c"]` interrupts.
  `["make -j4", "Enter"]` runs a command. `["Down", "Down", "Enter"]` picks
  the third menu entry.
- Tokens are case-sensitive: `Enter` is a key, `enter` is a word. To type a
  word that looks like a token, set `literal: true`.
- Text with a newline in it presses Enter at the newline.

Rules:

- One `shell_send` is one interaction. It returns the screen after the
  program reacted, so you rarely need a `shell_read` right after it. If the
  program is slow, `shell_read` again a moment later.
- A shell is named. Use two names to keep two programs apart. `shell_list()`
  shows them. `shell_start` on a name that is already running attaches to it
  and does not kill it.
- `shell_kill` when the interactive part is done. A leftover shell wastes
  nothing but is confusing next time.
- You may also drive `tmux` yourself through `run_command`
  (`tmux new-session -d -s x`, `tmux send-keys -t x 'cmd' Enter`,
  `tmux capture-pane -p -t x`). The `shell_*` tools are the short way for the
  same thing.
- Never paste a secret into a shell. Secrets are environment variables in
  your sandbox already; a script reads them from `os.environ`.

## Which one?

| the command... | use |
|---|---|
| ends in seconds, no questions | `run_command` |
| takes minutes or longer, no questions | `run_command(background=true)`, then wait to be woken |
| asks something, shows a menu or a TUI | `shell_start` -> `shell_read` -> `shell_send` |
| must keep running (a dev server) while you work | `run_command(background=true)`; stop it with `job_cancel` |
| may ask AND takes long (an installer) | `shell_start` with the command, answer the questions, then `shell_read` until `running` is false |

`apt-get` and `pip` accept `-y` / `--yes`; prefer that in `run_command` over
an interactive shell when you know the answer is yes.
