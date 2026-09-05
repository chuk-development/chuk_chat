# Handover — Secrets vault (session cowork-26 / cowork-secrets), 2026-09-05

User ask: "The AI has a .env it can never read; it uses the keys only
programmatically; it can ask the user by name; Settings manage the keys;
E2E encrypted in Supabase and to the Python host." One set per user, global
for every agent and session (coordinator's clarification). Contract:
`docs/WIRE_CONTRACT.md`, section "Secrets". Beads: epic `cowork-3sn`
(children `.1` Python, `.2` Dart, `.3` skill).

Nothing is committed. Everything below is in the working tree.

## What was built

### Python

| Piece | Where | Notes |
|---|---|---|
| Tools + scrubber + access protocol | `agent/src/cowork_agent/secrets.py` (new) | `request_secrets(names, purpose)`, `list_secrets()`, `Scrubber` (raw / base64 / base64url / URL-encoded, values >= 8 chars), `SecretsAccess` protocol, `DictSecrets` for tests, `status_map`, `valid_name`. |
| Dispatch chokepoint | `agent/registry.py` | `ToolRegistry.result_filter`: every dispatch result and every error envelope pass it. A raising filter yields an error envelope, never the raw result. |
| Store chokepoint | `agent/loop.py` | `AgentLoop(persist_filter=)`, applied in the one `_append` path for system / user / assistant / tool / context rows. Wired by `build_runtime` to the registry's filter when `secrets` is given. |
| Child env | `agent/environment.py`, `agent/tools.py` | `Environment.run_bash(..., env=)`; `run_command` and `python` pass `env=secrets.env()` ONLY when there is something to pass (`tools._secret_env`), so fakes without the keyword keep working. File tools, terminal, probes: no secrets. |
| Runtime seam | `agent/runtime.py` | `build_runtime(secrets=)` registers the tools, installs both filters. Children inherit through `SubagentConfig.runtime_kwargs["secrets"]`. |
| Sandbox injection | `sandbox/base.py`, `local.py`, `docker.py` | `run_bash`/`run`/`_run_bash` take `env=`. Local: `Popen(env={**os.environ, **env})`. Docker: `-e NAME` (no value on argv) + Popen env. The wrapper `unset -v NAME...` after the user block, before `declare -px`, so the session snapshot never holds a value. |
| Vault | `executor/src/cowork_executor/secrets.py` (new) | `SecretsVault`: in-memory set, `replace(entries, revision)` (last frame wins), `env()`, `names()`, `status()`, `scrubber()`, at-rest AES-256-GCM file (0600) `load()`/`save()`. |
| Executor wiring | `executor/executor.py` | `Executor(secrets=, on_secret_request_pending=)`; `secrets` frame → `_handle_secrets` (replace + wake waiters); tool bridge `_secrets_access` / `_request_secrets` (emits `secret_request`, polls kill/timeout 600 s); `_flush_pending_secret_requests` on replay; `_seal_b64` scrubs every frame except `browser_data`; `_call_hook` scrubs hook payloads; `begin_run` prompt and `finish_run` final_answer scrubbed; transcript exporter gets `scrub=`. |
| Frames | `executor/protocol.py` | `secrets_payload(...)`, `secret_request_payload(...)`. |
| Host | `host/host.py`, `host/serve.py`, `host/secrets_key.py` (new) | `LocalHost.secrets_vault` (built in `__init__`, `~/.cowork/secrets.enc`, key = HKDF(identity seed, "cowork/host/secrets-at-rest/v1")), loaded at start; passed through `TaskServer(secrets=)`; `_on_secret_request_pending` → desktop toast (names only) when no app is attached. |
| Skill | `skills/secrets/SKILL.md` (new) | Seeded into an agent workspace on the NEXT host start (`seed_workspace_skills`, non-destructive). |

Also done on request: `sandbox/docker.py` read-only mount of
`<workspace>/transcript` (b5), test `sandbox/tests/test_docker_create_args.py`.

### Dart

| Piece | Where |
|---|---|
| Store (secure storage, one record `cowork_secrets_v1`, revision) | `app/lib/services/secrets/secrets_store.dart` |
| Mirror (Supabase `cowork_secrets`, one row per name, `EncryptionService` value) | `app/lib/services/secrets/secrets_sync.dart` (`SecretsMirror` interface, `NoopSecretsMirror`, `SecretsSync`) |
| Service (names notifier, set/remove/setMany/answerUnchanged/forwardToHost, mirror + host push) | `app/lib/services/secrets/secrets_service.dart` |
| Relay | `cowork_relay_client.dart`: `CoworkRelaySecretRequest`, `sendSecrets(values:, revision:, requestId:)`, ctor `secretsForwarder:` (called after every `provisionAccount`), `_dispatch` case `secret_request` |
| Thread view card | `cowork_thread_view.dart`: `_buildSecretRequestBar` (one obscured field per name, "Already set" helper, Save keys / Skip) |
| Settings | `app/lib/pages/secrets_settings_page.dart` (new); hub rows in `settings_page.dart` (CoWork section) and `desktop_settings_modal.dart` (`id: 'apikeys'`) |
| Wiring | `cowork_shell_state.dart`, `session_recovery.dart`: `secretsForwarder: SecretsService.instance.forwardToHost` |
| Exhaustive switches | one `case CoworkRelaySecretRequest()` each in `websocket_chat_service.dart` and `cowork_replay_loader.dart` |
| Migration + schema | `supabase/migrations/20260905120000_cowork_secrets.sql`, `docs/SUPABASE_SCHEMA.md` (section "CoWork secrets") |

## Tests

Python (each run alone, `uv run pytest ... -q -p no:cacheprovider`):

- `agent/tests/test_secrets.py` 18 — scrubber variants, tools, chokepoint,
  `print(os.environ['X'])` masked, file tools without env, error envelope,
  store rows masked through `build_runtime`.
- `sandbox/tests/test_secrets_env.py` 4 — value reaches the command, not the
  snapshot, not the next command. `test_docker_create_args.py` 2.
- `executor/tests/test_secrets_e2e.py` 7 — the coordinator's proof
  (`print(os.environ["X"])`, base64, `printenv`, a model that echoes the
  value: not in tool result, not in frames, not in messages/runs rows);
  request round-trip; cancel → missing; frame with every name wakes the
  wait; stop ends the wait; replay re-sends the open request.
- `host/tests/test_secrets_vault.py` 6 — key derivation, at-rest round trip
  (0600, ciphertext only), foreign key reads empty, replace semantics, host
  reloads after restart, pending nudge is names only.
- Full suites: executor 145 passed, host 146 passed, sandbox 41 passed.
  Agent: all green except 6 `test_skills` + 1 `test_subagents`, caused by
  the uncommitted mem0 `observe_turn` hunk (memory.py / loop.py
  `turn_observer`, not this session's) running the extraction on the mock
  model — reported to the coordinator.

Dart: `test/services/secrets/secrets_store_test.dart`,
`secrets_service_test.dart`, `test/services/cowork/cowork_relay_secrets_test.dart`,
`test/pages/secrets_settings_page_test.dart`,
`test/widgets/cowork_thread_view_secrets_test.dart`; `settings_page_test.dart`
lists "API Keys". Scoped `dart analyze` over every touched file: 0 issues.
Results of the `flutter test` runs: see the status log at the end.

## How it flows (for whoever debugs it)

1. App: user adds a key (Settings > API Keys) or answers the card →
   `SecretsService` → secure storage (+ revision) → mirror row (encrypted)
   → `controller.sendSecrets(...)` = one `secrets` frame with the WHOLE set.
2. Host: executor `_handle_secrets` → `vault.replace` → at-rest file →
   waiters woken (by `request_id`, or every asked name now set).
3. Task: `build_runtime(secrets=bridge)`; `run_command` / `python` get
   `env=vault.env()`; registry `result_filter` + loop `persist_filter` +
   executor `_seal_b64` mask every value on the way out.
4. `request_secrets` (model) → `secret_request` frame → card in the thread
   view → step 1 with `request_id` → tool returns `{name: set|missing}`.
5. Host restart with no app: vault reloads `secrets.enc`; the next provision
   re-sends the device's set (device is the authority).

## Open / not done

- **Host restart** needed for the wiring and the seeded skill (bundled by
  the coordinator). Live proof with the real app not run (no screen window).
- **Docker sandbox path** (`docker exec -e NAME`) is unit-tested on argv
  only, not against a running container.
- `cowork_run_ledger.dart` untouched: a `secret_request` is not a transcript
  card and is not replayed from the store (host re-sends open requests on
  replay instead).
- No push notification (FCM) for a pending `secret_request`; desktop toast
  only. Follow-up bead if wanted.
- Values < 8 chars are injected but not masked (contract; said in the skill,
  the settings page and the card).
- `cowork-75` (terminal/jobs) reuses `tools._secret_env`; the tmux server
  keeps the values in its environment for its lifetime (their note).

## Status log

- 2026-09-05 ~14:30 — Dart tests run one at a time in the coordinator's
  compiler window: `test/services/secrets` 13, `cowork_relay_secrets_test`
  4, `secrets_settings_page_test` 6, `settings_page_test` 4,
  `cowork_thread_view_secrets_test` 4, `cowork_thread_view_test` 25
  (regression). Full `flutter analyze`: 0 errors (5 pre-existing infos /
  warnings in imported chuk files, none in this session's files).
- Beads `cowork-3sn.1/.2/.3` closed; epic `cowork-3sn` stays open until the
  host restart + live proof with the real app, and the Supabase migration
  has been run by the user.
- Side finding: `skills/workspace/SKILL.md` has a 336-char description
  (limit 300) and is therefore missing from the skill catalogue.
