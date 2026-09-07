# Project Instructions for AI Agents

This file provides instructions and context for AI coding agents working on this project.

## App inspection and screenshots (user instruction, 2026-09-05)

- Read this file first. `AGENTS.md` links to this file so all agents use the same instructions.
- Never capture the user's desktop, monitor, root window, or unrelated windows. Capture only the explicitly identified project app window; verify its PID/executable and window ID first. If no matching window is available, stop the capture rather than falling back to the desktop.
- Use `xdotool` and native Linux tools. Do not use Orca computer-use.
- Use the existing `flutter-hot` / Flutter Hot Reload workflow. Window-only capture already exists in `/home/user/.claude/tools/flutter-hotd`; prefer reusing that capability with verified project-window ownership.
- On Wayland, run the project app with `GDK_BACKEND=x11` when needed for window-specific capture. Record only a short note containing the project, PID/window ID and capture command; never assume IDs survive a restart.
- Keep this as a short operational note, not a screenshot tutorial.
- Local workflow: from `app/`, `GDK_BACKEND=x11 FLUTTER_HOT_EXTRA='' flutter-hot start linux`, then `flutter-hot reload`; capture with `bash scripts/capture_app_window.sh /tmp/cowork-window.png` from the repository root. The helper validates executable/PID/window ownership and prints the selected IDs; no desktop fallback.
- If GNOME reports `org.gnome.ScreenSaver.GetActive = true`, window pixels may be stale: defer visual acceptance until the user unlocks; never unlock the session automatically.

## Shell and task tracking

- Use non-interactive file operations (`cp -f`, `mv -f`, `rm -f`) and narrowly resolved targets.
- Use the project Beads skill at `.agents/skills/beads/SKILL.md`, then `bd prime` for current workflow context. Use `bd` for task tracking and `bd remember` for persistent project memory; never create ad hoc memory files.

<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:6cd5cc61 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Agent Context Profiles

The managed Beads block is task-tracking guidance, not permission to override repository, user, or orchestrator instructions.

- **Conservative (default)**: Use `bd` for task tracking. Do not run git commits, git pushes, or Dolt remote sync unless explicitly asked. At handoff, report changed files, validation, and suggested next commands.
- **Minimal**: Keep tool instruction files as pointers to `bd prime`; use the same conservative git policy unless active instructions say otherwise.
- **Team-maintainer**: Only when the repository explicitly opts in, agents may close beads, run quality gates, commit, and push as part of session close. A current "do not commit" or "do not push" instruction still wins.

## Session Completion

This protocol applies when ending a Beads implementation workflow. It is subordinate to explicit user, repository, and orchestrator instructions.

1. **File issues for remaining work** - Create beads for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **Handle git/sync by active profile**:
   ```bash
   # Conservative/minimal/default: report status and proposed commands; wait for approval.
   git status

   # Team-maintainer opt-in only, unless current instructions forbid it:
   git pull --rebase
   git push
   git status
   ```
5. **Hand off** - Summarize changes, validation, issue status, and any blocked sync/commit/push step

**Critical rules:**
- Explicit user or orchestrator instructions override this Beads block.
- Do not commit or push without clear authority from the active profile or the current user request.
- If a required sync or push is blocked, stop and report the exact command and error.
<!-- END BEADS INTEGRATION -->



## Commit-Regel (User-Anweisung 2026-09-05, gilt für ALLE Agent-Sessions in diesem Repo)

- **Commit ist immer freigegeben.** Jede Session committet **automatisch nach jedem abgeschlossenen Arbeitsschritt** (Feature, Fix, Test grün), ohne nachzufragen.
- Grund (wörtlich vom User): ohne Commits gibt es Kollisionen über immer mehr Dateien, weniger Commits, und am Ende kann man schlechter zurückgehen.
- Regeln bleiben: nur eigene Dateien bzw. abgestimmte Hunks, Tests vorher grün, keine Session-Links und keine Co-Authored-By-Trailer, als `chukfinley <77645077+chukfinley@users.noreply.github.com>` über die globale git config (keine `-c`-Overrides), Branch `cowork`, kein Worktree.
- **Der git-Index ist geteilt (ein Working-Tree, viele Sessions).** Deshalb IMMER in EINEM Befehl und nur mit expliziten Pfaden committen: `git commit -o -m "<msg>" -- <pfad1> <pfad2> ...` (`-o`/`--only` ignoriert den geteilten Index und nimmt genau diese Pfade). Nie `git commit -a`, nie `git add -A`/`git add .`, nie `git reset` (löscht fremdes Staging), nie getrenntes `git add` + `git commit`. Vorher `git log --oneline -1 -- <pfad>` prüfen, ob eine fremde Session die Datei schon mitcommittet hat. Commit-Fenster: der Koordinator vergibt sie nacheinander ("Commit-Fenster?").
- Vor jedem Commit `git diff --stat -- <pfade>` lesen: passt die Zeilenzahl nicht zur eigenen Arbeit, enthält die Datei fremde Working-Tree-Änderungen → nicht committen oder per `git add -p` (im selben Befehl mit dem Commit) aufteilen. `-o` schützt nur vor dem geteilten Index, nicht vor fremden Hunks in derselben Datei.
- Dieses Repo überschreibt damit das "Conservative"-Profil oben: Commits brauchen KEINE erneute Freigabe. Push weiterhin nur auf Anweisung.

## Build & Test

_Add your build and test commands here_

```bash
# Example:
# npm install
# npm test
```

## Architecture Overview

_Add a brief overview of your project architecture_

## Conventions & Patterns

_Add your project-specific conventions here_
