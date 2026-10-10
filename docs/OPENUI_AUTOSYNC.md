# OpenUI Flutter fork: automatic sync with upstream

Status: design only. Nothing is built. Research date: 2026-10-10.

Scope: a fork of `mtwichel/openui_flutter` (Dart/Flutter port, MIT) stays in
sync with `thesysdev/openui` (TypeScript/React, MIT). An LLM agent (GLM-5.3-Flash)
ports upstream changes to Dart, runs tests and opens a pull request. A human
merges.

## 0. Short result

1. Upstream changes fast (520 commits in 6 months), but the part that needs a
   port is small. About 4 % of the commits touch the parser, runtime, prompt
   or component schemas. After manual review, only **1 to 3 commits per month**
   need a real port.
2. The OpenUI Lang spec page (`specification-v05.mdx`) did not change since
   2026-04-06. The changes are implementation semantics: validation, streaming,
   fences in strings, new components.
3. The Flutter port is **not 1:1 today**. It is dormant since 2026-05-28, it
   has 17 of about 45 components, and it diverges on purpose (`$x = @Query(...)`
   instead of canonical `Query(...)`, extra `@Map`). Autosync works only after
   a one-time catch-up. A cheap model must not do the catch-up alone.
4. Upstream has **no language-neutral test fixtures**. Its tests are inline
   vitest code. The gate must be a **differential oracle**: run upstream
   `lang-core` in Node at a pinned SHA, dump JSON results for a corpus, and
   compare the Dart output with these goldens.
5. Harness: Claude Code headless (`claude -p`) with
   `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`. It is on the Z.ai list
   of supported tools. OpenCode or Crush are the second choice.
6. The Z.ai Coding Plan terms do not allow use "outside such tools" and name
   "bots" and "other systems". A cron job that runs Claude Code is in a grey
   zone. The safe choice is a pay-as-you-go API key for the bot. The cost is
   about **1 to 5 USD per month** with GLM-5.3-Flash.
7. Run it on the PC with a systemd user timer at night (off-peak, 50 % credit
   rate on the plan). Run the agent in a container, because upstream text is
   untrusted input for an agent with shell access.
8. The main cost is human review time (about 1 to 1.5 hours per month), not
   tokens.

## 1. What changes upstream, and how often

### 1.1 Method

* `gh api repos/thesysdev/openui/commits?since=2026-04-10` (520 commits, no
  merge commits; upstream squash-merges).
* For each commit, `gh api repos/thesysdev/openui/commits/<sha>` for the file
  list, then a path classifier.
* Cross-check with `gh api .../commits?path=<dir>` (this uses full history and
  is not limited by the 300-file cap of the commit API).
* Manual review of each candidate commit diff.
* npm version history of `@openuidev/lang-core`, `react-lang`, `react-ui`.

Path classes:

| Class | Paths | Port? |
|-------|-------|-------|
| Core | `packages/lang-core/src/parser/**`, `runtime/**`, `library.ts` (not telemetry, not cloud) | Yes |
| Prompt | `packages/lang-core/src/parser/prompt.ts`, `react-ui/src/genui-lib/prompt-options/**` | Yes, if the Dart side generates the system prompt (it does: `generatePrompt`) |
| Schema | `packages/react-ui/src/genui-lib/**/schema.ts`, `genui-lib/Charts/*.ts` | Yes, for components that the Dart library has |
| Noise | React views, docs site, examples, devtools, telemetry, cloud, CLI, observability, CI | No |

### 1.2 Numbers per month

Month 2026-04 starts at 04-10. Month 2026-10 ends at 10-10.

| Month | All commits | Touch `lang-core/src` | Touch `genui-lib` | Real port needed (manual) | Of these: parser semantics |
|-------|-------------|-----------------------|-------------------|---------------------------|----------------------------|
| 2026-04 | 21 | 3 | 1 | 1 | 0 (1 new feature: serializer) |
| 2026-05 | 58 | 0 | 3 | 2 | 0 (2 schema changes) |
| 2026-06 | 49 | 2 | 0 | 2 | 2 |
| 2026-07 | 139 | 4 | 3 | 3 (prompt/spec output) | 0 |
| 2026-08 | 118 | 8 | 1 | 2 | 1 (large) |
| 2026-09 | 110 | 3 | 2 | 3 (+ about 14 new component schemas) | 1 |
| 2026-10 | 25 | 2 | 0 | 1 | 1 |
| **Sum** | **520** | **22** | **10** | **14** | **5** |

Mean: about 87 commits per month upstream, about 2.3 port-worthy commits per
month, about 0.8 parser-semantics commits per month.

Docs churn is high and not relevant for the port: `docs/content/docs` had
2, 4, 14, 25, 27, 32, 8 commits per month.

### 1.3 The port-worthy commits

| Date | Commit | What | Class | Size |
|------|--------|------|-------|------|
| 2026-04-28 | `ac414abf` | `jsonToOpenUI` serializer (new) | Feature | +279 src, +590 test |
| 2026-05-15 | `8d3b31b0` | PieChart schema change | Schema | +17 −4 |
| 2026-05-18 | `b6b4ab41` | Select schema: 1 new field | Schema | +1 |
| 2026-06-08 | `96aaed49` | Keep markdown fences and comments inside strings | Parser | +44 −18 |
| 2026-06-29 | `17c1dc85` | Stream parser scans the preprocessed buffer (fences, comments). **Hidden in a 300-file commit named "Agent Interface SDK".** | Parser | +45 −29 |
| 2026-07-10 | `8ecdcfda` | `toSpec()` extended | Prompt/spec | +20 −7 |
| 2026-07-11 | `d66cf7bb` | Optional library identifier | Library | +4 |
| 2026-07-24 | `269d2594` | Move to spec generation | Prompt | +29 |
| 2026-08-17 | `0d021ef9` | Nested schema validation and `type-mismatch` | Parser | +370 new `validation.ts`, +361 test |
| 2026-08-26 | `de390586` | System prompt wording for data generation | Prompt | +5 −5 |
| 2026-09-02 | `a1db90bc` | `validate-library.ts` (port this part; skip the cloud flag) | Library | +182 |
| 2026-09-15 | `8e0d1c81`, `b4aa87cb` | About 14 new component schemas in the chat and standard libraries | Schema | about +400 schema lines |
| 2026-09-28 | `55df79c2` | Stream parser: last complete definition wins for duplicate IDs | Parser | +4 −6 |
| 2026-10-06 | `7c8f5e9a` | Plain objects in component slots are `type-mismatch` | Parser | +32 −4 |

Noise inside `lang-core/src` (do not port): telemetry (`dbad744d`,
`6facbd6a`, `44fa7952`, `a59581ef`, `ea2115d0`, `f1f66c42`), cloud
(`923deba4`), devtools library id (`a7ac9055`), zod v3/v4 import compat
(`a64d30bc`), React StrictMode timer (`45920dbb`), ModelSwitcher (`19617a2d`).

### 1.4 Releases

* GitHub releases exist only since 2026-09 (changesets, PR #1069). Before
  that, only npm.
* `@openuidev/lang-core` on npm: 18 versions from 0.2.2 (2026-04-14) to 0.4.0
  (2026-10-10). That is about 3 per month. Many have no lang-core change
  (0.4.0 says "No changes in this release.").
* Since 0.3.0 the lang family (`lang-core`, `react-lang`, `vue-lang`,
  `svelte-lang`, `angular-lang`) has one version line. The `CHANGELOG.md` of
  `lang-core` has one entry per PR with a plain-English summary. This is a good
  second signal for the agent.
* **Use commits, not releases, as the trigger.** Releases bump versions
  without a change, and fixes land days before a release.

### 1.5 State of the Flutter port

* `mtwichel/openui_flutter`: 7 stars, 0 forks, last push 2026-05-28. Packages:
  `openui_core`, `openui`, `openui_components`, `openui_mcp`.
* Its own `docs/canonical-comparison.md` lists the gaps: `Query(...)` syntax
  (High), array pluck (High), builtin set (High), query lifecycle (High),
  standard library 17 vs about 45 components (High), `jsonToOpenUI` (Medium).
* It has intentional Flutter-only extensions (`$var = @Query(...)`, `@Map`).
* It stores no upstream SHA. Nothing tells which upstream state it follows.

Consequence: since 2026-05-23 (date of the parity doc) the port missed the
parser commits above, plus the earlier gaps. **The first job is a one-time
catch-up**, not an incremental sync. Do it with a strong model and a human
(estimate: 3 to 6 working days). Decide first: canonical syntax or Flutter
extensions. Autosync only works well if the fork follows canonical syntax.
Every kept divergence is a permanent conflict source.

## 2. Agent harness

### 2.1 Model facts (official Z.ai docs, 2026-10-10)

* GLM-5.3-Flash exists. Model code `glm-5.3-flash`. **Context 1M tokens,
  max output 128K.** 320B total parameters, 18B active. Native multimodal.
* Pay-as-you-go price per 1M tokens: input 0.15 USD, cached input 0.03 USD,
  cached input storage "Limited-time Free", output 0.50 USD. GLM-5.3: 1.4 /
  0.26 / 4.4 USD.
* Coding Plan: "All plans support **GLM-5.3**, GLM-5.3-Flash." Plan starts at
  18 USD per month. Credits: Lite 2,000 per 5 h and 10,000 per week; Pro
  12,000 / 60,000; Max 28,000 / 140,000.
* Credit formula: "(Input tokens × Input multiplier + Cached Input tokens ×
  Cached Input multiplier + Output tokens × Output multiplier) / 10,000".
  Multipliers for GLM-5.3-Flash: input 2.3, cached 0.56, output 8. GLM-5.3:
  6.9, 1.7, 24.
* "During off-peak hours, model usage is charged at 50% of the standard credit
  rate." Peak: Monday to Friday, 14:00 to 18:00 UTC+8 (08:00 to 12:00 CEST,
  07:00 to 11:00 CET).
* Claude Code setup from Z.ai: `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic`,
  `ANTHROPIC_AUTH_TOKEN=<key>`, `API_TIMEOUT_MS=3000000`, model mapping
  `glm-5.3-flash[1m]` / `glm-5.3[1m]`. OpenAI-compatible coding endpoint:
  `https://api.z.ai/api/coding/paas/v4` (general API: `https://api.z.ai/api/paas/v4`).

### 2.2 Coding Plan terms for automated use (quoted)

From the Subscription Terms, section 4 "Usage Rules":

> "You understand and agree that the usage quota under GLM Coding Plan is only
> used within officially supported tools. If the system detects usage through
> unauthorized or unsupported tools (such as SDK-based access or other
> third-party integrations), some subscription benefits may be restricted to
> ensure fairness and service stability."

> "You shall not use the GLM Coding Plan quota for general-purpose API access or
> any scenarios outside such tools, including but not limited to directly
> invoking model APIs from your own applications, bots, websites, SaaS products
> or other systems, unless you have entered into a separate written agreement
> with Z.ai."

> "If Z.ai reasonably suspects that you are engaging in account sharing, bulk or
> automated usage on behalf of others, resale of access, [...] Z.ai is entitled
> to take measures including, without limitation, restricting certain features,
> reducing or limiting your usage quota, suspending or terminating the service,
> reclaiming any remaining quota [...]"

From the Usage Policy:

> "Use limited to supported tools: GLM Coding Plan may only be used within
> officially supported tools and products. Use in unsupported tools may result
> in restricted benefits."

> "Accounts with more than three violations may be banned."

> "refunds are not supported."

Reading (business risk, not legal advice):

* Claude Code, Codex, OpenCode, Crush, Goose, Droid, Cline, Kilo Code, Roo
  Code, Pi are on the supported list. **Aider and OpenHands are not.** A direct
  SDK call from a Python script is explicitly flagged.
* The terms do not say "no CI" and do not say "no cron". They forbid "bots"
  and "other systems" outside the tools, and they name "automated usage on
  behalf of others". A personal cron job that starts Claude Code for the
  owner's own repository is a supported tool used by the subscriber. That is
  the strongest position, but it is still a grey zone.
* GitHub Actions runners use shared datacenter IP ranges. That looks more like
  a bot than a home PC. Higher flag risk.
* What a flag costs: rate limit, frozen account, ban after three violations,
  no refund. If the owner also uses this plan for daily coding, the loss is
  the daily tool, not the bot.
* **Recommendation:** give the bot its own pay-as-you-go API key (general
  endpoint, billed per token). At about 1 to 5 USD per month (section 3.7) the
  plan saves almost nothing, and the risk goes to zero. If the owner still
  wants to use the plan: only on the PC, only through Claude Code, only at
  night. Open question to check after the first run: on the Z.ai "Charge
  Type" page, confirm which balance the Anthropic-compatible endpoint charges
  for a pay-as-you-go key.

### 2.3 Harness comparison

| Harness | Headless mode | GLM connection | On Z.ai list | Fit |
|---------|---------------|----------------|--------------|-----|
| Claude Code | `claude -p "<prompt>" --output-format json --max-turns N --allowedTools ...` | `ANTHROPIC_BASE_URL=https://api.z.ai/api/anthropic` (documented by Z.ai) | Yes | **Best.** The owner knows it, it supports hooks and permission lists, Z.ai documents it. Use a separate `CLAUDE_CONFIG_DIR` so the bot does not load the owner's global config. |
| OpenCode | `opencode run "<prompt>"` | Built-in Z.ai / coding-plan provider | Yes | Good second choice. Open source, simple. |
| Crush | `crush run "<prompt>"` | OpenAI-compatible provider config | Yes | Good. Small, single binary. |
| Goose | `goose run -t "<prompt>"`, recipes | OpenAI-compatible provider | Yes | Good for scripted recipes. |
| Codex CLI | `codex exec "<prompt>"` | `model_providers` entry in `config.toml` | Yes | Works. Tool format is tuned for OpenAI models. |
| Droid | `droid exec` | Custom model config | Yes | Works, closed source. |
| Aider | `aider --message ... --yes-always` | OpenAI-compatible | **No** | Plan use breaks the terms. OK with a pay-as-you-go key. Weak at running tests in a loop. |
| OpenHands | Headless CLI, Docker runtime | OpenAI-compatible (LiteLLM) | **No** | Heavy (Docker sandbox). OK with a pay-as-you-go key. Has a sandbox by design. |

Decision: **Claude Code headless, inside a podman container, with GLM-5.3-Flash
as the default model and GLM-5.3 as the retry model for a failed port.**

## 3. Pipeline

### 3.1 Overview

```
systemd timer (03:30 daily, Persistent=true)
  └─ sync.sh (no LLM until step 4)
       1. fetch upstream, read .upstream-sync (last synced SHA)
       2. list commits LAST..origin/main that touch the watch paths
       3. regenerate goldens with the Node oracle at each new SHA
       4. per relevant commit: agent run in container -> branch
       5. gate: dart analyze, dart test, conformance, guard rules
       6. gh pr create (or draft PR + bd issue when the gate fails)
  human: review, merge  -> .upstream-sync advances with the merge
```

### 3.2 Trigger: PC (recommended) or GitHub Actions

| | PC (systemd user timer) | GitHub Actions schedule |
|--|--|--|
| Cost | 0 | Free for a public repo; 2,000 min/month free for a private repo |
| ToS risk with Coding Plan | Lower (home IP, supported tool) | Higher (datacenter IP, looks like a bot) |
| Secrets | Local `.env` via `env-set` | Repository secrets |
| Reliability | `Persistent=true` runs a missed job after a reboot | Scheduled runs can be late or skipped; GitHub disables schedules after 60 days without repo activity |
| Resources | 32 GB RAM, memguard and `claude.slice` apply | 7 GB runner, enough for `dart test` |
| Safety | The agent runs on the main PC: container is required | Runner is disposable: safer by design |

Recommendation: PC timer, agent in a rootless podman container. Mount only
the fork checkout and a goldens directory. No `~/.ssh`, no `~/.claude`, no home
directory. Give the container a fine-grained GitHub token that has only
`contents:write` and `pull_requests:write` on the fork repository. The token
cannot push to `main` (branch protection).

If the owner wants zero agent risk on the PC: run steps 1 to 3 on the PC and
steps 4 to 6 in GitHub Actions with a pay-as-you-go key.

Timer example (user unit, about 03:30 local time is off-peak for Z.ai):

```ini
# ~/.config/systemd/user/openui-sync.timer
[Timer]
OnCalendar=*-*-* 03:30
Persistent=true
RandomizedDelaySec=15m
[Install]
WantedBy=timers.target
```

### 3.3 Diff extraction

* The fork stores the last synced upstream SHA in a file `.upstream-sync` at
  the repository root (one line: full SHA plus date). The file changes only in
  merged sync PRs. This keeps the state in git, on every machine.
* Use a local clone (`git clone --filter=blob:none`), not the GitHub API.
  Reason: the commit API returns at most 300 files per commit. Commit
  `17c1dc85` has 300+ files and hides a stream parser fix. `git log` and
  `git diff` have no cap.
* Watch paths (allow list): `packages/lang-core/src/parser/**`,
  `packages/lang-core/src/runtime/**`, `packages/lang-core/src/library.ts`,
  `packages/react-ui/src/genui-lib/**/schema.ts`,
  `packages/react-ui/src/genui-lib/Charts/*.ts`,
  `packages/react-ui/src/genui-lib/prompt-options/**`,
  `docs/content/docs/openui-lang/specification-*.mdx`.
* Deny list inside the watch paths: `**/telemetry/**`, `cloud*.ts`,
  `postinstall*`, `**/__tests__/**` (tests go to the agent as context, but
  they do not trigger a run).
* Classify by path, never by commit title. Titles lie ("Agent Interface SDK"
  carried a parser fix).
* Per relevant commit, give the agent: the filtered diff, the full message,
  the matching `CHANGELOG.md` entry, the golden delta (3.4), and a file map
  `TS file -> Dart file` (kept in the fork as `tool/upstream_map.yaml`).
* If no watched path changed: no LLM call. The script writes the new SHA in a
  small direct commit (deterministic, no review needed), or waits for the next
  sync PR.
* One upstream commit = one branch = one PR. Small PRs are easy to review and
  easy to revert.

### 3.4 Conformance gate: differential oracle

Upstream has no fixture files. Findings:

* `packages/lang-core/src/**/__tests__/*.test.ts`: vitest with inline strings
  (about 37 parser tests, 30 serialize, 14 validation, 11 prompt). Not
  language-neutral.
* `benchmarks/samples/*.oui`: 7 real LLM outputs (dashboard, form, table,
  pricing page, ...), plus `benchmarks/schema.json` (a library JSON Schema)
  and `benchmarks/system-prompt.txt`. These are neutral and reusable.
* `docs/content/docs/openui-lang/*.mdx`: about 45 code blocks with OpenUI
  Lang examples.
* `docs/generated/*.spec.json`: generated library specs.

Design:

1. `tool/oracle/` in the fork: a small Node script. It checks out upstream at
   a given SHA, builds `lang-core` (`pnpm --filter @openuidev/lang-core build`)
   and calls the public API: `parse(src, schema)`, the stream parser from
   `createParser` (feed every prefix of each input, record each snapshot),
   `jsonToOpenUI` / `serialize`, `mergeStatements`, `generatePrompt`.
2. Corpus (`test/conformance/corpus/`): the 7 benchmark `.oui` files, the doc
   code blocks, all string literals from `parse(...)` calls in upstream tests
   (extract them with the TypeScript compiler API, not with a regex), plus
   generated variants (truncations, fences, comments, duplicate IDs, wrong
   types in slots).
3. Output (`test/conformance/goldens/<case>.json`): normalized JSON (root tree,
   `meta.errors` with codes, `incomplete`, `unresolved`, stream snapshots,
   prompt text hash and text).
4. The Dart test reads each golden, runs the Dart parser on the same input
   and compares the normalized JSON.
5. Schema conformance: dump upstream component schemas
   (`library.toJSONSchema()` / spec) and the Dart library definitions to the
   same JSON form. Compare for every component that the Dart library has. New
   upstream components show up as a list, not as a failure.
6. `test/conformance/divergences.yaml`: cases that differ on purpose (for
   example the `@Query` form while it exists). Each entry needs a reason.
7. Set `OPENUI_TELEMETRY_DISABLED=1` and `DO_NOT_TRACK=1` for every Node run.
   Upstream `lang-core` has an opt-out postinstall telemetry.

The script, not the LLM, makes the goldens. The golden delta between the old
and new upstream SHA is the most precise description of the change: it shows
what behavior changed. If the goldens do not change, the commit was a refactor,
and the agent only checks for new API surface.

What the oracle does not cover: Flutter rendering (widgets, layout, charts).
That stays a human check in the example app.

### 3.5 Guard rules (hard checks after the agent run)

The PR is not opened (draft only) if one of these is true:

* `dart analyze` has an error, or `dart test` fails, or conformance fails.
* The diff touches `test/conformance/goldens/**`, `test/conformance/corpus/**`,
  `divergences.yaml`, `.upstream-sync`, or `tool/oracle/**`.
* The diff deletes or skips a test (`skip:`, removed `test(` calls).
* The diff is larger than a limit (for example 600 changed lines), or touches
  files outside the `upstream_map.yaml` targets.

Agent limits: `--max-turns 60`, 45 min wall time, 2 attempts (Flash, then
GLM-5.3). After that: draft PR with the log, plus `bd create` in the fork.

### 3.6 PR and human review

* `gh pr create` with: upstream commit link, CHANGELOG entry, golden delta
  summary (cases changed, new error codes), test result, agent turn count and
  token use. Label `upstream-sync`.
* Never auto-merge. Branch protection on `main`: required CI checks, the bot
  token cannot merge.
* Review checklist: does the Dart diff match the TS diff line by line in
  intent; is any new behavior covered by a golden; no telemetry ported; no new
  network call.
* The merge advances `.upstream-sync`.

### 3.7 Cost per month

Assumptions:

* About 3 to 4 port PRs per month (observed mean 2.3, plus margin), 2
  attempts each: 8 agent runs per month.
* One run: about 40 turns, mean context about 60K tokens, so about 2.5M input
  tokens per run, 90 % cache hits; about 40K output tokens.
* Detection and goldens: no LLM, 0 tokens.

Per month: about 20M input tokens (18M cached, 2M not cached), about 0.3M
output tokens.

| Option | Calculation | Per month |
|--------|-------------|-----------|
| Pay-as-you-go, GLM-5.3-Flash | 2M × 0.15 + 18M × 0.03 + 0.3M × 0.50 USD | **about 1.0 USD** (about 0.9 EUR) |
| Pay-as-you-go, busy month (5× runs, like 2026-09) | | about 5 USD |
| Pay-as-you-go, all runs on GLM-5.3 | 2M × 1.4 + 18M × 0.26 + 0.3M × 4.4 USD | about 9 USD |
| Coding Plan credits, Flash, off-peak | about 215 credits per run × 0.5 × 8 runs | about 900 credits = about 2 % of a Lite month (about 43,000 credits) |
| GitHub Actions minutes | 8 runs × 10 min | 80 min (free) |
| Human review | 3 to 4 PRs × 20 min | **1 to 1.5 hours** |

EUR values assume 1 USD = about 0.9 EUR. Check the rate on the day.

One-time catch-up (not part of the monthly cost): about 40 to 80 runs, use
GLM-5.3, about 1.1 USD per run, so about 45 to 90 USD pay-as-you-go. On a Lite
plan this is about 2 to 3 weeks of the weekly credit cap (about 650 credits
per GLM-5.3 run at peak, about 325 off-peak). Plus 3 to 6 days of human work.

Token cost is too small to matter. The real cost drivers are review time and
the catch-up.

## 4. Risks that cost money or time

| Risk | Evidence | Effect | Mitigation |
|------|----------|--------|------------|
| Silent wrong port | The agent writes its own tests and confirms its own misunderstanding | Bugs in chat UI rendering that look like model errors | Goldens come from upstream code, not from the agent. The agent cannot edit goldens (guard). The reviewer reads the golden delta. |
| Test gaps | Upstream tests are inline vitest; the oracle covers parse, stream, serialize, prompt, schema, not rendering | Widget bugs pass the gate | Keep rendering out of autosync. The example app plus a manual check for component PRs. |
| Hidden changes in big commits | `17c1dc85`: parser fix inside a 300-file SDK commit; the GitHub API caps the file list at 300 | Missed port, drift grows unseen | Local `git diff`, path filter, oracle at every SHA (the golden delta catches it even if the path filter misses it). |
| ToS flag on the Coding Plan | Terms quoted in 2.2: "bots", "other systems", "automated usage", ban after three violations, no refund | Loss of the plan (and the daily coding tool if it is the same account) | Separate pay-as-you-go key for the bot. If the plan is used: PC only, Claude Code only, night only. |
| Upstream breaking rewrite | `lang-core` is 0.x; 0.3.0 changed release tooling; "move to spec generation" (`269d2594`); `prompt.ts` is 30 KB and changes often | One huge PR that the cheap model cannot do; days of work | PR size cap. A large change becomes a `bd` issue for a human with a strong model. Pin to a version line and sync in batches if churn is high. |
| Fork divergence | The port has `@Query`, `@Map`, 17 of 45 components | Every upstream Query change conflicts | Decide canonical vs extensions before autosync. Track each kept difference in `divergences.yaml`. |
| Telemetry ported by mistake | Upstream added PostHog telemetry in 2026-08 (`dbad744d`, `ea2115d0`, ...) | A phone-home in chuk_chat, privacy claims broken | Deny list for `telemetry/**`. Review rule: no new network call. |
| Prompt injection from upstream | The agent reads upstream diffs, comments and commit messages, and has a shell | Secrets on the main PC leak; malicious push | Container without home directory and SSH keys; scoped token; no auto-merge. |
| Original port comes back to life | `mtwichel/openui_flutter` dormant since 2026-05-28 | Two diverged Dart ports, merge pain | Treat the fork as a hard fork. Offer fixes upstream to mtwichel only when cheap. |
| Plan or model change | GLM-5.2 and 5.1 are already routed to 5.3; prices say "Limited-time Free" for cache storage | Cost or quality change without notice | Log tokens per run; alert if a run costs more than 1 USD. Keep the harness model-agnostic (OpenAI-compatible fallback). |
| PC offline or under memory pressure | 24/7 PC, but memguard kills over 6 GB | Missed runs, killed tests | `Persistent=true`; Dart tests are small. Do not run Flutter widget tests in parallel with other heavy jobs. |

## 5. Order of work

1. Decide canonical syntax vs Flutter extensions for the fork.
2. Build the oracle and the goldens at the SHA that matches the current port
   (about 2026-05-23). Make the Dart conformance test pass with
   `divergences.yaml`.
3. Catch-up to upstream `main` (human plus strong model), commit by commit
   with the same gate.
4. Write `.upstream-sync`, `tool/upstream_map.yaml`, `sync.sh`, the
   container image and the timer.
5. Run in dry mode (no PR, only a report) for 2 weeks. Then turn on PRs.

## Sources

* Upstream repository and data: `gh api repos/thesysdev/openui/commits`,
  `.../commits/<sha>`, `.../commits?path=...`, `.../releases`,
  `.../compare/@openuidev/lang-core@0.3.0...@openuidev/lang-core@0.4.0`,
  `.../git/trees/main?recursive=1` (queried 2026-10-10).
* lang-core changelog: https://github.com/thesysdev/openui/blob/main/packages/lang-core/CHANGELOG.md
* npm registry: https://registry.npmjs.org/@openuidev/lang-core,
  `.../@openuidev/react-lang`, `.../@openuidev/react-ui`
* Flutter port: https://github.com/mtwichel/openui_flutter and its
  `docs/canonical-comparison.md`
* OpenUI Lang spec v0.5: https://github.com/thesysdev/openui/blob/main/docs/content/docs/openui-lang/specification-v05.mdx
* Z.ai Coding Plan overview (models, credits, multipliers, off-peak): https://docs.z.ai/devpack/overview
* Z.ai Usage Policy: https://docs.z.ai/devpack/usage-policy
* Z.ai Subscription Terms, section 4 Usage Rules: https://docs.z.ai/legal-agreement/subscription-terms
* Z.ai supported tools: https://docs.z.ai/devpack/tool/others
* Z.ai Claude Code setup: https://docs.z.ai/devpack/tool/claude
* GLM-5.3-Flash model page (1M context, 128K output): https://docs.z.ai/guides/vlm/glm-5.3-flash
* Z.ai pricing: https://docs.z.ai/guides/overview/pricing
* Third-party summaries seen during discovery (not used as a basis):
  https://hyscaler.com/insights/glm-coding-plan-review,
  https://aiengineerguide.com/til/anthropic-api-format-glm-coding-plan/
* Harness headless flags: from each tool's own docs (Claude Code `-p`,
  OpenCode `run`, Crush `run`, Goose `run`, Codex `exec`, Aider `--message`).
  Check the flags against the installed version before you build.
