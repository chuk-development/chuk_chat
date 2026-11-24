# Goal judge, skill self-fix, run modes (CHAT-183)

Three server features of Agents. Sources of the ideas:
`docs/agents/COMPETITOR_IDEAS_2026-11-24.md` (ideas 7 and 10, Hermes) and
`docs/agents/GROKBOT_2026-11-02.md` (item 5).

## 1. Goal judge

Code: `agents/runtime/src/chuk_agents_runtime/goal_judge.py`, hooked into
`GoalController.update` in `goal.py`.

- When the agent calls `update_goal` with action `complete` on an active
  goal, a cheap model (the aux model of the run) reads the objective, the
  `evidence` argument and the tail of the newest task.
- The judge answers `done` or `continue` with a short reason.
- `done`: the goal completes as before.
- `continue`: the tool call fails with the reason. One user-side row
  `<goal_judge>` (source `goal`) tells the agent what is missing. The
  revision does not change, so the next `complete` is valid. The run goes on.
- Limits: 3 judge calls per goal, 12 000 characters per call, 40 000
  characters per goal. With fewer than 2 model steps left in the run, the
  judge does not refuse.
- Fail open: a model error or an answer that is not the expected JSON
  accepts the completion. The log has one line.
- The app sees the verdict in the `goal` frame: `goal.judge` =
  `{verdict, reason, round, max_rounds, at}`. Verdicts: `done`, `continue`,
  `error`, `skipped`.
- Off switch: `AGENTS_GOAL_JUDGE=0`.

## 2. Skill self-fix

Code: `agents/runtime/src/chuk_agents_runtime/skill_selffix.py`, started
from `Executor._start_learning` (`_run_skill_selffix`).

- Trigger A: the newest task loaded a skill and ended in `max_iterations`,
  `budget_exhausted` or `token_budget_exhausted`.
- Trigger B: the task before loaded a skill, and the user's new message reads
  like a correction ("no, ...", "that is wrong", "falsch", "stattdessen").
  This word filter only decides if the model is asked.
- No trigger: no model client, no cost.
- With a trigger, the aux model gets the current `SKILL.md` text (read from
  disk now) and the task. It proposes one patch or "no fix".
- The patch goes through the normal proposal flow: pinned to the hash of
  the text it read (`prepare_patch`), scrubbed, validated, stored as a
  card. The file changes only when the user accepts. A changed file makes the
  card `stale`.
- When the self-fix stores a proposal, the general background review of the
  same run is skipped (one card per run).
- Off switch: `AGENTS_SKILL_SELFFIX=0`. It is on by default, because it runs
  only after a failure or a correction.

## 3. Run modes

Code: `agents/runtime/src/chuk_agents_runtime/run_modes.py`, data in
`chuk_agents_runtime/data/modes/*.json`, executor `_apply_run_mode`.

- Built-in modes: `review`, `research`, `plan`, `quick`, `careful`.
- An agent can add a mode or replace a built-in one:
  `<agent workspace>/modes/<name>.json`.
- Fields of a mode file (all optional except the name, which can come from
  the file name):

  | Field | Effect |
  |---|---|
  | `title`, `description` | shown in the app |
  | `prompt` | extra block, one context row per task (source `mode`) |
  | `deny_groups`, `deny_tools` | these tools are refused |
  | `allow_groups`, `allow_tools` | only these (and the core tools) run |
  | `model`, `reasoning_effort` | the model of the run |
  | `approvals` | `strict`: every action class that would run without a card asks |
  | `plan` | `true`: the mode turns on plan mode |

- Tool groups: `files_read`, `files_write`, `shell`, `web`, `browser`,
  `mail`, `mail_send`, `messaging`, `automations`, `publish`, `subagents`,
  `memory_write`, `mcp`, `dashboard`. A name that ends in `*` is a prefix.
- The tool list does not change with the mode (prompt cache). A refused tool
  answers "X is not allowed in <mode> mode".
- A mode cannot make approvals weaker than the agent's policy.
- Switch on: task frame field `mode: "<name>"`, or the prompt prefix
  `/mode <name> <message>`. Switch off: `mode: ""` / `"off"`, or
  `/mode off`.
- The mode sticks: it is stored per chat (`session_features`, kind
  `run_mode`) and holds for every later task until the user changes it.
- Frames: `run_mode` `{session_key, mode: {name, title, description,
  builtin, model?, reasoning_effort?, approvals?, plan?} | null, error?}`.
  It is persisted when the mode changes, and sent live at the start of each
  run while a mode is on. `run_state` carries `run_mode` too.
- Plan mode: the `plan` mode turns plan mode on. When the user approves the
  plan (`exit_plan_mode`), plan mode ends and the `plan` run mode ends with
  it. The `plan` flag and the `/plan` prefix work as before.
- A mode's model and effort win over the task's model and the agent's stored
  model, for that run.

## Open points

- The app does not yet send `mode` or draw the `run_mode` frame and
  `goal.judge`.
- Subagents do not inherit the run mode or the strict approvals.
- The judge and the self-fix use the metered aux client: their calls are
  `aux` cost lines of the run, not lines of their own.
