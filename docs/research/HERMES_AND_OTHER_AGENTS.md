# Ideas from Hermes Agent and other agent harnesses (2026-11-04)

This file lists ideas from other open-source agent harnesses that we can use.
It also lists problems that we have and that they solved. It does not repeat
the items in `DEEPSEEK_HARNESS_IDEAS.md` and `DEEPSEEK_HARNESS_AUDIT.md`. When
a source does a DeepSeek item better, the note says so and gives the DeepSeek
item number (`DS #n`).

Sources (shallow clones in `_scratch/ext/<name>`, gitignored, read only, no
code from them was run):

| Name | Repository | Note |
|------|------------|------|
| hermes-agent | NousResearch/hermes-agent | Main source. MIT, Python. |
| codex | openai/codex | Rust CLI. |
| opencode | sst/opencode | TypeScript. |
| goose | block/goose | Rust. |
| openhands-sdk | OpenHands/software-agent-sdk | The old `All-Hands-AI/OpenHands` clone has only the web frontend now. |
| letta-code | letta-ai/letta-code | The old `letta-ai/letta` clone has no source now. |

Legend.

- Status: **HAVE** (we have it), **PART** (we have some of it), **MISS** (we do not have it).
- Fits: **C** = Flutter client (`lib/`), **API** = `/home/user/git/api_server`, **AG** = Agents (`agents/`).
- Effort: **S** (hours to 1 day), **M** (days), **L** (a week or more).
- Our paths: `RT` = `agents/runtime/src/chuk_agents_runtime`,
  `EX` = `agents/executor/src/chuk_agents_executor`,
  `HOST` = `agents/host/src/chuk_agents_host`,
  `SB` = `agents/sandbox/src/chuk_agents_sandbox`.

Context: our plan (`docs/AGENTS_AGENT_PLATFORM_PLAN.md`) already ported many
Hermes parts: the sandbox abstraction, the iteration budget, the tool registry,
tool search, the FTS5 session search, cron grammar, subagent lifecycle and the
frozen prompt snapshot. The plan also names the Hermes background review as
"the crown jewel" (§11), but nobody built it. The tables below show what is
still open.

---

## 1. Hermes Agent (NousResearch)

### 1.1 Learning loop: memory and skills

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| H1 | **Background review fork.** After a turn, a daemon thread forks the agent with the parent's model and cached prompt. The fork replays the turn and asks "save a memory or update a skill?". It has a tool whitelist (memory + skill tools only). It never touches the live chat. A different (cheaper) review model gets a digest, not the full transcript. | `agent/background_review.py` | **MISS.** `RT/skill_proposals.py` creates a skill only when the model calls `propose_skill` itself. Nothing reviews a turn after it ends. The plan (§11) asks for this. | AG | M |
| H2 | **Review prompts with a "do not capture" list.** Do not save environment failures, "tool X is broken" claims (they become refusals), transient errors, one-off narratives, or dead ends as best practice. Save only facts grounded in a user message or tool result. Never infer traits from tone. | `agent/background_review.py:365-580` (`_MEMORY_ROUTING_BLOCK`, `_DO_NOT_CAPTURE_BLOCK`) | **MISS.** Copy the text into the H1 prompt and into the `propose_skill` tool description (`RT/skill_proposals.py`). | AG | S |
| H3 | **Agent edits skills (`skill_manage`): patch, edit, write support file, delete.** Read-before-write is enforced: a patch is refused unless the agent loaded that skill in this review. | `tools/skill_manager_tool.py`, `tools/skill_manager_guards.py` | **MISS.** We can only create (`propose_skill`). A wrong skill stays wrong. | AG | M |
| H4 | **Skill support files:** `references/<topic>.md`, `templates/`, `scripts/`, loaded on demand with `skill_view(name, file_path)`. | `tools/skills_tool.py`, docs `user-guide/features/skills.md` "Skill Directory Structure" | **MISS.** `RT/skills.py` reads one `SKILL.md` per skill. No support files. | AG + C | S-M |
| H5 | **Curator.** Usage counters per skill (`use_count`, `view_count`, `patch_count`). Unused agent-made skills go `active -> stale (14 d) -> archived (30 d)`. Pinned skills and skills that a cron job uses are skipped. Optional LLM pass merges overlapping skills into class-level skills. Never deletes; archive is restorable. | `agent/curator.py`, `tools/skill_usage.py`, docs `curator.md` | **MISS.** No usage data in `RT/skills.py`. Proposed skills will pile up. | AG | M |
| H6 | **Write approval for memory and skills.** One switch. When on, background writes are staged; the user approves or rejects them. A staged patch pins the exact entry text; if the entry changed, the approve fails. | docs `memory.md` "Controlling memory writes", `tools/memory_tool_store.py` | **PART.** Skill proposals already go through an app card (`RT/skill_proposals.py`, `skill_proposal` frame). Memory writes (Mem0 / Hindsight) never ask. Reuse the card for H1 output. | AG + C | S |
| H7 | **Memory notifications.** A short line "Memory updated" / "Skill 'x' patched" after a background write, with a verbose mode that shows the change. | docs `memory.md` "Background review notifications" | **MISS.** Hindsight retains every turn silently (`RT/memory_hindsight.py`). The user cannot see what the agent learned. | C + AG | S |
| H8 | **`/learn <url, folder or "what I just did">`.** The agent reads the source with its own tools and writes a skill. A large source (book, docs set) becomes a knowledge-base skill: lean `SKILL.md` plus one `references/` file per chapter. | `agent/learn_prompt.py`, docs `skills.md` "/learn" | **MISS.** Depends on H4. | AG + C | M |
| H9 | **Skill marker after compaction.** When compaction removes a loaded skill body, the stub says `[SKILL_PRUNED ... reload with skill_view]`, and the summary lists pruned skills with a "reload before use" rule. | docs `developer-guide/context-compression-and-caching.md` "Loaded skills across a compaction" | **MISS.** `RT/skills.py` puts the skill body in a user-role message. `RT/context.py` has no skill handling, so tier 2 can fold the body into the summary and the model does not know. | AG | S |
| H10 | **Conditional skills:** `requires_tools`, `fallback_for_tools` in the frontmatter hide or show a skill by the tools that exist. | docs `skills.md` "Conditional Activation" | **MISS.** `RT/skills.py`, `lib/services/skills/`. | AG + C | S |
| H11 | **Skill-declared env vars.** A skill lists `required_environment_variables`; only those pass into the sandbox when the skill loads. | docs `security.md` "Environment Variable Passthrough" | **PART.** `EX/secrets.py` gives all user secrets or none (per-agent toggle `secrets_env` in `SB/policy.py`). | AG | S-M |
| H12 | **Learning journey.** A timeline of every skill and memory entry the agent learned, with delete and edit. | `agent/learning_graph.py`, docs `memory.md` "/journey" | **MISS.** Good fit for the phone: "What my agent learned". | C + AG | M |
| H13 | Curated `USER.md` profile (1,375 chars) next to agent notes, frozen per session. | `tools/memory_tool.py` | **PART (by decision).** We use Mem0 / Hindsight semantic memory plus static `soul.md` (`RT/memory.py:1-30`, owner decision 2026-08-28). No change needed; take the H2 grounding rules for fact extraction. | AG | - |
| H14 | FTS5 session search, ±5 messages + bookends, no LLM. | `hermes_state_search.py` | **HAVE.** `RT/search.py` (ported). | - | - |

### 1.2 Context, cache and model

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| H15 | **Cache TTL by pace.** `auto` = 1 h TTL for human-paced sessions, 5 min for machine-paced (subagent, cron, webhook). | `agent/prompt_caching.py` (`auto_cache_ttl_for_source`) | **MISS.** `api_server/chat/prompt_cache.py:86` always sets `{"type":"ephemeral"}` (5 min). A phone user who reads for 6 minutes pays the full prefix again. | API | S |
| H16 | **Compaction failure cooldown.** A failed summary arms a cooldown 60 s -> 300 s -> 900 s, stored in the DB. A second stall commits a deterministic fallback summary. | docs `context-compression-and-caching.md` "Failure cooldown" | **PART.** `RT/context.py:458` has anti-thrash (savings under 10 %), but no cooldown after an aux-model failure. | AG | S |
| H17 | **Micro-compaction (opt-in).** After each turn, fold the oldest exchange into one rolling summary. Defrag the summary over 2,000 tokens. Skip an exchange after 3 failures. | `agent/micro_compaction.py`, docs `micro-compaction.md` | **PART.** Our tier 3 updates the summary in the background (`RT/context.py:36-62`). Hermes says micro-compaction breaks the cache every turn. Do not copy; our ladder is the better default. | - | - |
| H18 | **No context-pressure warnings to the model.** Hermes removed them: "they caused models to give up early". | docs `context-compression-and-caching.md` "Context Pressure Warnings" | **HAVE (by omission).** Note: this conflicts with goose G3 below. Test before we add a budget hint. | AG | - |
| H19 | **Mixture of Agents preset as a model.** Reference models answer once per user turn (no tools, user/assistant text only). Their answers go to the acting model as a trailing private user message, so the cache prefix stays. HermesBench: Opus + GPT reference 0.82 vs 0.76 alone. | `agent/moa_loop.py`, docs `mixture-of-agents.md` | **MISS.** No "council" model in `api_server/model_info/`. Could be a premium model entry for chat and Agents. | API + C | M |
| H20 | **Side question `/btw`.** A cache-parity fork answers a question about the chat. It adds no turn to the chat and no cache miss. | `agent/side_question.py` | **MISS.** | C + API, AG | M |
| H21 | **Empty-reply guard.** Two empties in a row with `output_tokens == 0` from the same model = deterministic. Skip the other retries and go to the fallback model. | `agent/empty_response_guard.py` | **PART.** `RT/loop.py:404` nudges once; client retries 3x (`lib/services/tool_call_handler.dart:559`). Both re-bill the full input on a deterministic refusal. | AG + C | S |
| H22 | **Repetition guard.** A long verbatim fragment (60+ chars) that fills most of the output = degenerate loop. Abort instead of "continue". | `agent/repetition_guard.py` | **MISS** in `RT/loop.py` and `lib/services/`. | AG + C | S |

### 1.3 Tools, files and safety

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| H23 | **Hardline floor.** `rm -rf /`, fork bomb, `mkfs`, `dd` to a disk, pipe-URL-to-sh: always blocked, also in yolo mode. Unparsable shell quoting fails closed. | `tools/approval.py` (`UNRECOVERABLE_BLOCKLIST`, `_floor_block`) | **MISS.** No match for such rules in `RT/`, `EX/`, `SB/`. Our local backend runs on the user's real PC. | AG | S |
| H24 | **Protected paths.** Writes to `~/.ssh/`, `~/.aws/`, `~/.kube/`, `/etc/sudoers`, `.netrc` always fail. Project `.env` files are read-denied but writable. | `agent/file_safety.py`, docs `security.md` "File Write Safety" | **MISS.** Same grep, nothing. | AG | S |
| H25 | **Runtime self-protection.** The agent cannot delete or overwrite the interpreter and venv it runs from. | `agent/runtime_self_protection.py` | **MISS.** On the local backend a `rm -rf ~/.local/...` can delete our host install; the agent then cannot fix it. | AG | S |
| H26 | **User deny rules.** Glob list (`git push --force*`) that blocks commands before any approval mode. Matches after quote and launcher normalisation (`sudo`, `env`, `bash -c`). | docs `security.md` "User-Defined Deny Rules" | **MISS.** See codex C1 for the stronger allow/ask/deny form. | AG + C | M |
| H27 | **Approval history mining.** `approvals suggest` ranks commands the user approved often and proposes allow rules. Destructive classes are never proposed. | `hermes_cli/approvals_suggest.py` | **MISS.** Needs C1 first. Phone card: "You allowed `git push` 14 times. Always allow?" | AG + C | S |
| H28 | **Content-level command checks.** Flag `curl -d "$API_KEY"`, `-F file=@.env`, upload of `~/.ssh/id_rsa`; flag invisible / bidi Unicode in a command. | docs `security.md` "Content-Level Command Checks" | **MISS.** `RT/action_policy.py:15-24` has no shell class. | AG | S |
| H29 | **Failed-edit footer.** If a write or patch failed this turn and the file did not change later, append "N file edits FAILED this turn despite any wording above". | `agent/turn_finalizer.py` (`file_mutation_verifier`) | **MISS.** Generalise for us: any failed side-effect tool (mail, publish, write) gets a footer in the app. | AG + C | S |
| H30 | **Shadow checkpoint store.** One shared git store outside the project (`refs/hermes/<project-hash>`). One checkpoint per directory per turn, before writes and destructive shell commands. The user's `.git` is never touched. | `tools/checkpoint_manager.py`, docs `checkpoints-and-rollback.md` | **PART.** `RT/workspace_git.py:356` commits into the user's own repo (DS audit B14). Hermes shows the fix. | AG | M |
| H31 | **Rollback keeps hand-edits.** An agent-write ledger stores the hash of each file the agent wrote. Rollback skips files the user changed after that, unless `--all`. | docs `checkpoints-and-rollback.md` "User hand-edits are preserved" | **MISS.** `RT/workspace_tools.py:111` `workspace_undo` reverts by action count. | AG + C | S |
| H32 | **Browser credential vault.** At a login page the agent asks once (masked card). The password is stored encrypted, bound to the origin, and filled into the page. The model sees only `{filled_fields: 1}`. The value goes to the redactor. 2FA codes work the same way. | `tools/browser_vault_tool.py`, docs `credential-vault.md` | **PART.** `RT/browser.py:81-108` and `RT/takeover.py` hand the page to the user every time. Fine for one login, bad for a daily automation. | AG + C | M |
| H33 | **Project context files.** `AGENTS.md` / `CLAUDE.md` / `.cursorrules` at the start (scanned for injection). When the agent enters a subdirectory, its context file is appended to the **tool result**, not the system prompt, so the cache stays. | `agent/subdirectory_hints.py`, docs `developer-guide/prompt-assembly.md` "AGENTS.md" | **MISS.** `RT/memory.py:66` reads only `soul.md` / `agents.md` (persona and roster). See also codex C6. | AG | S |
| H34 | **`execute_code` with tool RPC.** The model writes one Python script that calls `web_search`, `read_file`, ... over a Unix socket. Only `print()` output returns, so middle results never enter the context. | `tools/code_execution_tool.py`, `tools/code_execution_rpc.py` | **MISS.** Our `python` tool cannot call agent tools. Goose G6 does the same in JS. | AG | L |
| H35 | Emergency stop sentinel that pauses new work only. | `agent/estop.py` | **HAVE.** `HOST/automations.py:803` (`_estop_engaged`). | - | - |
| H36 | Docker egress proxy as a credential firewall. | `tools/environments/docker_egress.py` | **MISS.** Same idea as codex C5. | AG | L |

### 1.4 Scheduling and events

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| H37 | **No recursion.** A run that a cron job started cannot create cron jobs. | docs `cron.md` (warning box), `tools/cronjob_tools.py` | **MISS.** `RT/runtime.py:491` registers the automation tools for every run, also `origin == "automation"`. No cap on the number of automations (no `MAX_*` in `HOST/automations.py`). A runaway "every 1m" job costs money. | AG | S |
| H38 | **Catch-up window.** A missed occurrence runs late only inside half its period (2 min to 2 h), per-job override. | `cron/missed_runs.py`, docs `cron.md` "Catch-up window" | **PART.** `HOST/automations.py:274` (`due`) fires any overdue row once, at any delay. A "09:00 market open" job fires at 18:00 when the PC wakes. | AG | S |
| H39 | **Unreachable retry ladder.** A run that fails before the first model call (Wi-Fi not back after wake) re-runs after 5, 15, 30 min. It is spend-neutral. | `cron/unreachable_retry.py` | **MISS.** `HOST/automations.py:985` only retries "host not provisioned". | AG | S |
| H40 | **Failure incidents.** Same error = one alert, then one reminder after 6 h. A new error alerts at once. A success resolves it. A streak of 3 failures adds "fix, pause or remove?". | `cron/incidents.py`, docs `cron.md` "Failure incidents" | **MISS.** No failure streak in `HOST/automations.py`. | AG + C | S-M |
| H41 | **Declared failure marker.** First line `[CRON_FAILURE]` marks a run failed when the agent finished but the work did not. | docs `cron.md` "Declaring a failed run" | **PART.** `automation_result` reports change or no change (`RT/automations.py:45-55`), not failure. Add `status: failed` to that tool, not a text marker. | AG | S |
| H42 | Per-job model pin and per-job reasoning effort. The agent cannot change the pin; the user owns it. | `cron/jobs_model_pin.py` | **MISS.** | AG + C | S |
| H43 | Skills attached to a job (loaded at fire time); curator never archives them. | docs `cron.md` "Skill-backed cron jobs" | **MISS.** | AG | S |
| H44 | **Inbound webhooks** with payload filters (`equals`, `contains`, `in_file`, `regex`, `any/all/not`), HMAC secret, and **coalescing** by key (30 s quiet window, 300 s cap, "N earlier events superseded"). | `gateway/platforms/webhook_filters.py`, `webhook_coalesce.py`, docs `messaging/webhooks.md` | **MISS.** We have mail and URL-watch triggers (`RT/automations.py:40-46`), outbound webhook only (`HOST/notify.py:25`). Inbound fits the relay: `api.chuk.chat/v2/hooks/<token>` forwards to the host. Coalescing also helps our mail trigger. | API + AG | M |
| H45 | Script-only job: no model, stdout = message, empty stdout = silent. | docs `cron.md` "No-agent mode" | **HAVE.** Watchers (`RT/automations.py:39`, `KIND_WATCHER`). | - | - |
| H46 | Heartbeat in the same session, missed ticks coalesce. | docs `heartbeat.md` | **HAVE.** A schedule fires into its own `session_key` (`HOST/automations.py:966-980`); `next_fire` after now coalesces. | - | - |

### 1.5 Subagents

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| H47 | **`output_schema` per task.** The parent validates the child's JSON, sends one correction turn with the errors, and keeps raw text plus `schema_valid: false` if it still fails. | `tools/delegation_output_schema.py`, docs `delegation.md` | **MISS.** `RT/subagents.py:995` (`DELEGATE_SCHEMA`) has no schema field. | AG | S |
| H48 | **Progress-based stall monitor.** Never touch a child that makes progress. Idle 450 s (1,200 s in a tool) = interrupt, 120 s grace, then a `stalled` result with metadata. | docs `delegation.md` "Stall Detection" | **PART.** `RT/subagents.py:277` has an inactivity timeout seam and a parent heartbeat, but no `stalled` outcome with partial result. | AG | S |
| H49 | **`/review`.** A full-tool reviewer subagent checks the last 10 messages of work (opens the PR, runs code). Its findings come back into the same chat. | docs `delegation.md` "The /review Command" | **MISS.** Also codex C11. Good phone button: "Check this work". | AG + C | M |

### 1.6 Channels and sessions

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| H50 | 30+ messaging adapters (Telegram, Matrix, Signal, Slack ...) with a DM pairing code for unknown users. | `gateway/platforms/`, `gateway/pairing.py` | **MISS (on purpose).** Already listed in `AGENT_COMPETITORS_2026-10.md`. The owner's Hermes notes (`/home/user/git/hermes-ops/MATRIX.md`) show the cost: a new device id on every restart broke E2EE, an old ignore list hid invites, cross-signing needed a manual reset. Our own app with automatic pairing avoids all of this. If we add a channel later: stable device id and fail-closed E2EE from day one. | - | L |
| H51 | **Resume recap.** On resume, show the last 10 exchanges, tool calls collapsed to a count. | docs `sessions.md` "Conversation Recap on Resume" | **PART.** See codex C9 (better: a 40-60 word recap + next action). | C | S |
| H52 | **Trajectory export** (ShareGPT JSONL, `completed` flag, tool stats per tool) for evals and fine-tuning. | `agent/trajectory.py`, `trajectory_compressor.py`, docs `developer-guide/trajectory-format.md` | **PART.** `RT/transcript_export.py` writes Markdown for the agent to grep. No training format. Opt-in only, local only (E2E product). Feeds `agents/bench`. | AG | M |

---

## 2. codex (openai/codex)

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| C1 | **Command rule language.** `prefix_rule(pattern=[argv tokens], decision=allow/prompt/forbidden, justification)`. Examples in the rule file are tested at load. A forbidden rule tells the model what to use instead. Matches argv tokens, not text. | `codex-rs/execpolicy/README.md`, `execpolicy/src/rule.rs` | **MISS.** `RT/action_policy.py:15-24` has 4 classes, no shell class. Shell and python never ask (DS audit). | AG | M |
| C2 | **"Approve and remember"** writes a new prefix rule. Scope "for this session". | `execpolicy/src/amend.rs`, `core/src/exec_policy.rs` | **MISS.** Scopes are `once / always_this_agent / always_this_site / deny` (`RT/action_policy.py:72-76`). | AG + C | S-M |
| C3 | Approval key from the normalised command (`/bin/bash -lc` = `bash -lc`). | `core/src/command_canonicalization.rs` | **MISS** (part of C1). | AG | S |
| C4 | **Network proxy** with per-domain allow/deny. Blocks private and loopback IPs after DNS. A "limited" read-only mode. | `codex-rs/network-proxy/README.md`, `network-proxy/src/connect_policy.rs` | **PART.** On or off only: `SB/policy.py:146` (`--network none`). Docker can reach the LAN and 169.254.169.254 (DS audit). | AG | L |
| C5 | **Credential broker.** The child gets a dummy token. The proxy inserts the real secret only for the allowed host. | `network-proxy/src/credential_broker.rs` | **MISS.** `EX/secrets.py` puts real values in the env; the scrubber only masks output later. | AG | L |
| C6 | **Hierarchical `AGENTS.md`:** walk up to the project root, join files from root down to cwd, with a size cap. | `codex-rs/core/src/agents_md.rs` | **MISS.** Same as H33. Take Hermes' cache-safe delivery (tool result) for subdirectories. | AG | S |
| C7 | **User hooks:** PreToolUse, PostToolUse, PermissionRequest, UserPromptSubmit, SessionStart/End, Stop, Compact. Scripts can block. Large output spills to a file. | `codex-rs/hooks/src/events/`, `hooks/src/output_spill.rs` | **MISS.** `RT/agents_hooks.py` only sends automation triggers. | AG | M |
| C8 | Shell snapshot: capture the user's login shell state (zsh aliases, PATH, nvm) once, strip credentials, restore before each command, delete after 3 days. | `core/src/shell_snapshot.rs` | **PART.** `SB/local.py:71-77` can run `bash -l` each time; zsh state is lost. | AG | M |
| C9 | **Recap prompt:** 40-60 words plus a nullable `next_action`. It keeps proposed / done / tested / deployed apart and reads only user-visible text. | `codex-rs/context-fragments/src/recap_prompt.rs` | **PART.** `agents/manager/src/chuk_agents_manager/daily_summary.py` is a daily journal, not a per-thread catch-up. Fits the inbox row on the phone. | C + AG | S |
| C10 | **Memory with usage feedback.** Background extraction from idle sessions; merge ranked by `usage_count` and `last_usage`; drop memories unused for N days; citations in replies count as use. | `codex-rs/memories/README.md`, `memories/read/src/citations.rs` | **PART.** Hindsight retains every turn (`RT/memory_hindsight.py`); no usage count, no decay. | AG | M |
| C11 | Review mode: separate run returns JSON findings (priority, confidence, file, line). | `core/src/tasks/review.rs` | **MISS.** Same need as H49; take the JSON shape from here. | AG | M |
| C12 | Rollback markers: "drop the last N user turns" is an appended row; fork cuts before the n-th user message. | `core/src/thread_rollout_truncation.rs` | **PART.** Only "regenerate last" (`EX/protocol.py:219-245`, `RT/loop.py:861`). | AG + C | M |

## 3. opencode (sst/opencode)

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| O1 | **Revert to message N.** Restore only files that later turns changed, from content snapshots. "Unrevert" works until the next prompt. | `packages/core/src/session/revert.ts`, `packages/core/src/snapshot.ts` | **PART.** `RT/workspace_tools.py:111` undoes by action count. Combine with H30 + H31. | AG + C | M |
| O2 | **Fork at a message** (`fork_session_id`, `fork_boundary`); the fork keeps the parent's cache-affinity key. | `packages/core/src/session/info.ts`, `session/affinity.ts` | **MISS.** No fork in `docs/WIRE_CONTRACT.md`. | AG + C | M |
| O3 | Permission rules as `tool -> {glob: action}`, last match wins (`bash: {"*": ask, "git *": allow, "rm *": deny}`); `external_directory` rule; `*.env` asks. | `packages/web/src/content/docs/permissions.mdx` | **MISS.** Simpler than C1; good for the phone settings UI. | AG + C | M |
| O4 | LSP diagnostics after an edit go back to the model. | `packages/web/src/content/docs/lsp.mdx` | **MISS.** Hermes has the same (`agent/lsp/`, `agent/turn_stop_gates.py`). | AG | L |
| O5 | Formatter runs after each write, picked by extension and project config. | `packages/web/src/content/docs/formatters.mdx` | **MISS.** | AG | S-M |
| O6 | Named reference folders or repos, each with a "use for ..." line. | `packages/web/src/content/docs/references.mdx` | **PART.** One workspace mount (`SB/policy.py:33`). | AG | S-M |

## 4. goose (block/goose)

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| G1 | **OSV malware check** before an `npx` / `uvx` MCP server starts. Any `MAL-*` advisory = refuse. | `crates/goose/src/agents/extension_malware_check.rs` | **MISS.** `RT/mcp_client.py:26,163` starts stdio servers with no check. | AG (+ C for desktop) | S |
| G2 | **Recipes:** YAML with parameters, a `response` JSON schema enforced by a `final_output` tool, sub-recipes and `retry {checks, on_failure}`. Shareable by deeplink. | `crates/goose/src/recipe/mod.rs`, `agents/final_output_tool.rs` | **PART.** Templates hold a persona only (`HOST/coworker_templates.py`); automations have no output schema or success check. | AG + C | M |
| G3 | Turn budget block for the model ("N rounds left, batch your calls"). | `crates/goose/src/agents/moim.rs` | **MISS** (`RT/loop.py:84-103` keeps it hidden). Hermes H18 says such warnings made models give up. Test on `agents/bench` before shipping. | AG | S |
| G4 | Dangerous-pattern list (exfil of `~/.ssh`, reverse shell, cron/systemd persistence) raises "allow" to "ask". | `crates/goose/src/security/patterns.rs` | **MISS.** Take the rule list, apply it on argv (C1), not raw text. | AG | S |
| G5 | Egress inspector: show outbound hosts of a shell command on the approval card. | `crates/goose/src/security/egress_inspector.rs` | **MISS.** | AG + C | S |
| G6 | Code mode: one JS `run()` that calls tools with `await` and `Promise.all`, no FS, no network. | `crates/goose/src/agents/platform_extensions/code_execution.rs` | **MISS.** Same as H34. | AG | L |
| G7 | Remembered approvals keyed by tool + argument hash, with expiry. | `crates/goose/src/permission/permission_store.rs` | **MISS.** "Always" is permanent and has no argument key (`RT/action_policy.py:269`). | AG | S |
| G8 | **Import Claude Code / Codex sessions** as native sessions. | `crates/goose/src/session/import_formats/mod.rs` | **MISS.** The agent runs on the user's PC; the user could continue a Claude Code session from the phone. | AG + C | M |
| G9 | Absolute token cap for auto-compaction (225k) under the provider's long-context price tier. | `crates/goose/src/context_mgmt/mod.rs` | **PART.** `RT/context.py:428-505` uses fractions only. A 1M model fills to 500k before tier 2. | AG + API | S |

## 5. OpenHands software-agent-sdk

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| OH1 | **Stuck detector** over the last 20 events: same action+observation 4x, same action+error 3x, monologue (agent messages with no user input), A-B-A-B alternation, context errors. Nudges once per error event. | `openhands-sdk/openhands/sdk/conversation/stuck_detector.py` | **MISS** in `RT/loop.py`. Better than DS #23 (identical calls only): it also catches alternation and error cycles. | AG + C | S |
| OH2 | The acting model adds `security_risk` LOW/MEDIUM/HIGH to each tool call; a confirmation policy asks above a threshold. | `openhands-sdk/openhands/sdk/security/risk.py`, `security/confirmation_policy.py` | **MISS.** Cheaper than DS #31 (second reviewer model). | AG | S |
| OH3 | Analyzer ensemble: pattern rules + policy rails ("fetch then exec") fused into the worst-case risk. Local, no model. | `openhands-sdk/openhands/sdk/security/ensemble.py`, `security/defense_in_depth/policy_rails.py` | **MISS.** Put G4 + H28 rules behind one ensemble. | AG | M |
| OH4 | Condensation event with `forgotten_event_ids`; the log keeps them, the UI shows a marker. | `openhands-sdk/openhands/sdk/event/condenser.py` | **PART.** The ladder rebuilds each round (`RT/context.py`); the app shows no compaction marker. | C | S |
| OH5 | Critic: after a run, a success score plus flags ("insufficient testing", "loop behaviour"). | `openhands-sdk/openhands/sdk/critic/` | **MISS.** | AG + C | M |

## 6. Letta Code

| # | Idea | Their path | Our status + evidence | Fits | Effort |
|---|------|------------|-----------------------|------|--------|
| L1 | **MemFS:** memory as a git-tracked folder. Root `MEMORY.md` = core memory in the prompt; nested files = deferred memory, loaded on demand through per-folder `MEMORY.md` indexes. Commit messages hold the reason for each change, so every memory edit can be reviewed and reverted. | `src/skills/builtin/initializing-memory/SKILL.md`, `src/skills/builtin/maintaining-deferred-memory/SKILL.md` | **PART.** Our memory is semantic (Hindsight) plus static `soul.md`. No reviewable, revertable notebook. The plan (§12) mentions "revertible, diffable memory" but it is not built. | AG | L |
| L2 | **Reflection trigger** `step-count` or `compaction-event`: reflect into memory when compaction fires. | `src/reflection-settings.ts` | **PART.** `RT/memory_hindsight.py` retains the summary on `on_summary`. Using the compaction moment as the H1 trigger is cheap: the transcript is about to be folded anyway. | AG | S |
| L3 | **`/doctor <symptom>`:** the agent investigates its own bad behaviour (prompt, memory, skills). | Letta README "Self-improvement & Learning" | **PART.** `HOST/doctor.py` checks the host setup, not agent behaviour. | AG | M |
| L4 | **Memory onboarding:** an `initializing-memory` skill that researches and asks the user, then writes core memory. | `src/skills/builtin/initializing-memory/SKILL.md` | **MISS.** A new coworker starts empty. | AG + C | S |
| L5 | **Self-configuration skill:** the agent changes its own permissions, hooks and settings when the user asks. | `src/skills/builtin/` (`self-configuration-*` tests) | **MISS.** Fits the phone: "stop asking me before mail" said in chat. | AG + C | M |

---

## 7. Problems we have that they solved

1. **The agent does not learn from corrections.** It saves a skill only if the
   model calls `propose_skill` (`RT/skill_proposals.py`). A wrong skill stays
   wrong (no edit tool). Hermes: background review fork (H1, H2) plus
   `skill_manage` with read-before-write (H3).
2. **The skill library will rot.** No usage data, no archive (`RT/skills.py`).
   Hermes: curator (H5).
3. **Skill bodies vanish in compaction without a trace.** `RT/context.py` has no
   skill handling. Hermes: `[SKILL_PRUNED]` marker and reload rule (H9).
4. **Automations can multiply and cost money.** A fired run keeps the
   automation tools (`RT/runtime.py:491`) and there is no count cap. Hermes:
   cron runs cannot create cron jobs (H37).
5. **A sleeping PC fires stale jobs.** `HOST/automations.py:274` runs any
   overdue row. Hermes: catch-up window (H38) and the 5/15/30 min retry after
   wake (H39).
6. **A broken automation alerts every run, or the user never hears about a
   streak.** Hermes: incidents with one alert, one reminder, and a "fix, pause
   or remove?" nudge (H40).
7. **The local backend has no floor.** No hardline blocklist, no protected
   credential paths, no self-protection (grep on `RT/`, `EX/`, `SB/` finds
   none). Hermes: H23, H24, H25.
8. **The agent can say "done" after a failed write or send.** Hermes:
   failed-edit footer (H29).
9. **Workspace git writes into the user's repo** (DS audit B14,
   `RT/workspace_git.py:356`). Hermes: shadow store outside the project (H30)
   and a rollback that keeps the user's hand-edits (H31).
10. **Project rules in the user's repo are ignored** (`RT/memory.py:66`).
    codex C6, Hermes H33 (cache-safe for subfolders).
11. **Child processes get real secret values** (`EX/secrets.py`). codex C5,
    Hermes H36. Short-term: per-skill env lists (H11).
12. **Network is all or nothing** (`SB/policy.py:146`). codex C4.
13. **No rewind to an earlier message and no fork** (`EX/protocol.py:219`).
    opencode O1, O2; codex C12.
14. **Every pause over 5 minutes re-pays the whole prefix**
    (`api_server/chat/prompt_cache.py:86`). Hermes: 1 h TTL for human-paced
    chats (H15).
15. **Logins need a takeover every time** (`RT/browser.py:81`). Hermes:
    origin-bound credential vault (H32).
16. **A degenerate output loop or a deterministic empty reply burns retries.**
    Hermes H21, H22; OpenHands OH1 for tool-call loops.
17. **Stdio MCP servers start from `npx` / `uvx` with no supply-chain check**
    (`RT/mcp_client.py:26`). goose G1.

## 8. Top 15 to build (by value)

| Rank | Item | Why | Fits | Effort |
|------|------|-----|------|--------|
| 1 | **Background review + skill edit** (H1, H2, H3, H6, H7; trigger also on compaction, L2) | The learning loop is the main selling point of Hermes and Letta. We have the approval card already; the review fills it. | AG + C | M |
| 2 | **Automation guards** (H37 no recursion + count cap, H38 catch-up window, H39 retry after wake, H40 incidents) | Stops runaway cost and stale or noisy pushes. All small changes in `HOST/automations.py`. | AG + C | S-M |
| 3 | **Local safety floor** (H23 hardline, H24 protected paths, H25 self-protection, H28 content checks) | The agent runs on the user's real PC. One bad command can wipe keys or our own install. | AG | S |
| 4 | **Project context files** (H33, C6) | Agents that work in a repo must follow its `AGENTS.md`. Small change, big quality gain. | AG | S |
| 5 | **Prompt cache TTL 1 h for human-paced chats** (H15) | Direct cost cut for phone users who pause between turns. | API | S |
| 6 | **Command rules + remembered approvals** (C1, C2, C3, G7, then H27) | Shell can ask without nagging; a phone card "always allow `git push`". | AG + C | M |
| 7 | **Skill marker after compaction + skill support files** (H9, H4) | Keeps long tasks correct; enables knowledge-base skills and `/learn` (H8). | AG + C | S-M |
| 8 | **Failed-action footer** (H29, generalised) | Trust: the user sees when the agent's "done" is false. | AG + C | S |
| 9 | **Stuck and loop guards** (OH1, H22, H21) | Stops paid loops that DS #23 does not catch. | AG + C | S |
| 10 | **Shadow checkpoints, rewind and fork** (H30, H31, O1, O2) | Fixes DS B14 and gives "undo to here" on the phone. | AG + C | M |
| 11 | **OSV malware check for MCP servers** (G1) | Cheap supply-chain defence. | AG + C | S |
| 12 | **Subagent `output_schema` + stall outcome** (H47, H48) | Reliable fan-out results; no silent dead children. | AG | S |
| 13 | **Credential vault for browser logins** (H32) | Daily automations on logged-in sites without a takeover each time. | AG + C | M |
| 14 | **Inbound webhooks via the relay, with filters and coalescing** (H44) | Event triggers (GitHub, Stripe, monitoring) that competitors ship. | API + AG | M |
| 15 | **Skill curator** (H5) | Keeps the catalogue small once item 1 creates skills. | AG | M |

Next after these: recap card (C9), self-rated risk (OH2), MoA "council"
model (H19), `/btw` side question (H20), `/review` button (H49, C11), recipes
with output schema (G2), memory onboarding (L4), session import from Claude
Code (G8), egress proxy and credential broker (C4, C5, H36), trajectory export
for `agents/bench` (H52).
