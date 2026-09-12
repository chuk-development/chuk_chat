# CoWork — how user credentials are handled today (audit, 2026-09-13)

Read-only audit of `/home/user/git/cowork` @ branch `cowork` (HEAD `f694826`).
Question: where do user-supplied API keys / logins / tokens enter, and does the
model ever see them? Written to compare against Grok Bot's design.

**Headline: CoWork already has a complete, purpose-built "secret request" path.**
It was designed in session `cowork-26` on 2026-09-05 and is specified in
`docs/WIRE_CONTRACT.md:851` ("Secrets (API keys the model never sees)").
The `secret_request` frame, the `request_secrets` tool, a value scrubber, an
encrypted host vault and an encrypted Supabase mirror all exist and are tested.
What is *missing* is not the mechanism — it is that the request renders as a
pinned bar above the composer instead of an inline message in the transcript,
and that the coverage is limited to *vault* values (MCP connector credentials
and account tokens ride other paths that the scrubber does not know about).

---

## 1. Where secrets enter the system today

There are **five** distinct entry points. Only one of them (A/B) is the "the
agent needs a key" path.

### A. Settings → API Keys (the user volunteers a key)
- `app/lib/pages/secrets_settings_page.dart:19` — the page. Names listed, values
  never shown; add/change/delete at `:42`, `:51`, `:59`.
- The dialog is `_SecretDialog` in the same file; values go straight to
  `SecretsService.set()`.

### B. The model asks by name (`request_secrets`) — the existing "secret request"
- Tool definition: `agent/src/cowork_agent/secrets.py:168` (`REQUEST_SECRETS_SCHEMA`),
  handler `:214` (`make_request_secrets_handler`), registration `:266`.
- Executor emits the frame and BLOCKS the worker thread:
  `executor/src/cowork_executor/executor.py:2764` (`_request_secrets`), timeout
  `SECRET_REQUEST_TIMEOUT = 600.0` at `:353`.
- Frame builder: `executor/src/cowork_executor/protocol.py:758`
  (`secret_request_payload`).
- App receives it: `app/lib/services/cowork/cowork_relay_client.dart:2599`
  (`case 'secret_request'`), model class `CoworkRelaySecretRequest` at `:1075`.
- UI: `app/lib/widgets/cowork_thread_view.dart:1500` (`_buildSecretRequestBar`),
  mounted at `:1280`, state at `:253`–`:256`, submit `:1031`, skip `:1057`.
- Answer goes back as a full `secrets` frame tied to the `request_id`:
  `app/lib/services/secrets/secrets_service.dart:135` (`setMany`) and `:160`
  (`answerUnchanged` for "Skip").

### C. Supabase table `cowork_secrets` (cross-device restore)
- Migration: `supabase/migrations/20260905120000_cowork_secrets.sql` — one row
  per name; `name` plaintext (a label), `ciphertext` an `EncryptionService`
  AES-256-GCM envelope encrypted **client-side**. Owner-only RLS on all four
  verbs (`:30`–`:50`).
- Client mirror: `app/lib/services/secrets/secrets_sync.dart:48` (`save`),
  `:88` (`load`). Decrypt failures cost one row, not the set.

### D. MCP connector credentials (a *separate*, parallel path)
- API-key style connectors: `showMcpCredentialDialog` in
  `app/lib/pages/settings/mcp_connectors_page.dart:674`, consumed at `:609`,
  stored via `McpService.connectWithCredentials` →
  `app/lib/services/mcp/mcp_service.dart:554`–`:587` (`store.setApiCredentials`)
  into secure storage under `mcp_secrets_<id>` (see
  `app/lib/services/mcp/mcp_connection.dart:62`).
- OAuth connectors: tokens minted in-app, forwarded to the host inside the
  sealed `task` frame's `mcp_servers` list
  (`executor/src/cowork_executor/protocol.py:155` docstring, `:203`).
- Rotation flows back as `mcp_credentials`
  (`executor/src/cowork_executor/protocol.py:688`; `client_secret` is
  deliberately never returned, `:711`).
- **These values are NOT in the secrets vault and are NOT known to the
  scrubber.** See §2 gap.

### E. Build/deploy environment (not user-facing at runtime)
- `app/.env` (gitignored, `.gitignore:20`) carries Supabase URL/anon key and
  feature flags, injected via `--dart-define-from-file` in
  `scripts/build_apk.sh:44`.
- The paired account bearer lives in `host/src/cowork_host/account_store.py`
  (`TOKEN_FIELDS` at `:41`), a `0600` file next to `paired.json`.
- Config explicitly refuses to hold secrets:
  `common/cowork_config/src/cowork_config/schema.py:32` documents the
  `*_key_ref` / `*_token_ref` convention (e.g. `model.api_key_ref` at `:454`,
  `memory.embed_api_key_ref` at `:529`), and
  `common/cowork_config/tests/test_no_secrets.py:30` fails the build if a new
  field looks like a credential without the `_ref` suffix.

---

## 2. Does the model ever see a secret?

**For vault values: no, by construction — two enforcement seams plus one
heuristic.**

1. **Tool results never carry a value.** `request_secrets` and `list_secrets`
   return a status map only: `{"NAME": "set" | "missing"}`
   (`agent/src/cowork_agent/secrets.py:205` `status_map`, and the defensive
   re-derivation at `:238`–`:241` — whatever the access layer returns, the model
   gets a status map over exactly the names it asked for).
2. **The `Scrubber` masks values in everything flowing back.**
   `agent/src/cowork_agent/secrets.py:97` (`class Scrubber`). It masks the raw
   value plus base64, base64url (padded and unpadded) and URL-encoded forms
   (`_variants`, `:76`), longest-match-first, with `[REDACTED:<NAME>]`.
   Values shorter than `REDACT_MIN_LEN = 8` (`:45`) are deliberately not masked.
   Installed at **three** seams:
   - registry dispatch result — `agent/src/cowork_agent/secrets.py:275`
     (`registry.result_filter = Scrubber(access.env).scrub_obj`), applied in
     `agent/src/cowork_agent/registry.py:226`–`:235`.
   - the message-row write path (so the stored transcript is masked too) —
     `agent/src/cowork_agent/runtime.py:619` (`persist_filter=...`), applied in
     `agent/src/cowork_agent/loop.py:312`–`:316`.
   - the executor's frame sealer, so the **app** also only ever sees masks —
     `executor/src/cowork_executor/executor.py:1661`–`:1669`, scrubber built at
     `:793`.
3. **Values never reach a child's shell state.** They are passed only as the
   environment of the `run_command` / `python` child process:
   `agent/src/cowork_agent/tools.py:187` (`_secret_env`), `:223`, `:320`.
   Docker path: `sandbox/src/cowork_sandbox/docker.py:444` uses `docker exec -e
   NAME` **with no value**, so the value rides the docker client's own env and
   never appears in argv/`ps`/history. Local path:
   `sandbox/src/cowork_sandbox/local.py:79`. The base env's contract is spelled
   out in `agent/src/cowork_agent/environment.py:57`–`:63` and
   `sandbox/src/cowork_sandbox/base.py:80`, `:202` (the `declare -px` session
   snapshot is taken **after** the names are unset).
4. **The prompt tells the model this is deliberate**:
   `agent/src/cowork_agent/prompt.py:144` ("Never print secrets…") and the
   builtin skill `skills/builtin/secrets/SKILL.md`.

**Heuristic second net (different path, do not confuse it with the scrubber):**
`agent/src/cowork_agent/context.py:227` `redact_secrets()` — regex patterns for
`sk-…`, `ghp_…`, `xox…`, `AKIA…`, `AIza…`, JWTs, `Bearer …`, and
`api_key=/token:/password=` assignments. It runs on the **context-compaction**
path (transcript handed to the aux model), on `transcript_export.py`,
`workspace_git.py`, and on the final-answer/stream path at
`executor/src/cowork_executor/executor.py:3223`. It is *not* on the ordinary
tool-result path.

### Gaps found
- **MCP connector credentials are outside the scrubber.** An API key entered in
  `showMcpCredentialDialog`, or an OAuth bearer forwarded in `mcp_servers`, is
  never registered with `SecretsVault`, so `Scrubber` does not know its value.
  If an MCP tool result or an error text echoes the bearer, only the *heuristic*
  `redact_secrets` might catch it, and only on the paths listed above.
- **The paired account bearer is likewise not vault-registered**
  (`host/src/cowork_host/account_store.py`), though it is never handed to a tool.
- **Sub-8-character values are intentionally unmasked** (`REDACT_MIN_LEN`,
  `secrets.py:45`). Documented in the UI at
  `app/lib/widgets/cowork_thread_view.dart:1568`.
- **No per-agent or per-session scoping.** One set per user, global for every
  agent, every session and every room turn on the host
  (`host/src/cowork_host/host.py:231`–`:260`). Any agent can `run_command` with
  any key in the set.

---

## 3. Existing structured / inline message kinds in the chat

The in-frame payload protocol is documented in
`executor/src/cowork_executor/protocol.py:15`–`:130` and the builders are the
`*_payload` functions in that file. The Dart switch that consumes them is
`app/lib/services/cowork/cowork_relay_client.dart:2516`–`:2694`.

| kind | Python builder (`executor/…/protocol.py`) | Dart model (`…/cowork_relay_client.dart`) |
|---|---|---|
| `delta` | `:357` | `CoworkRelayDelta` `:168` |
| `user` | (replay) | `CoworkRelayUser` `:194` |
| `reasoning` | `:361` | `CoworkRelayReasoning` `:213` |
| `tool` | `:372` | `CoworkRelayTool` `:249` |
| `file` | `:383` (`MAX_FILE_BYTES` `:150`) | `CoworkRelayFile` `:393` |
| `subagent` | `:417` | `CoworkRelaySubagent` `:590` |
| `approval_request` / `approval_decision` | `:283` / `:320` | `CoworkRelayApprovalRequest` `:970` |
| **`secret_request`** | **`:758`** | **`CoworkRelaySecretRequest` `:1075`** |
| **`secrets`** (app→host) | **`:733`** | `sendSecrets` **`:2307`** |
| `run_state` / `run_ack` | `:224` / `:256` | `CoworkRelayRunState` `:526` |
| `done` / `error` | `:522` / `:726` | `CoworkRelayDone` `:423` / `CoworkRelayRunError` `:903` |
| `automation` / `automation_list` / `automation_control` | `:567`, `:573`, `:578` | `:637`, `:688` |
| `agent_create/rename/list` | `:586`, `:592`, `:602` | `CoworkRelayAgentList` `:825` |
| `agent_status` | `:636` | `CoworkRelayAgentStatus` `:757` |
| `skills_list` / `skill_control` | `:610` / `:620` | `CoworkRelaySkillsList` `:718` |
| `mcp_tools` / `mcp_credentials` | `:663` / `:688` | dispatch `:2660` / `:2664` |
| `documents` / `documents_list` / `document_read` | — | `CoworkRelayDocuments` `:1317` |
| `room_*` (create/task/add/remove/rename/delete/history/turn/done) | `:428`–`:514` | `:855`, `:877`, `:895` |
| `browser_data` / `browser_view` | `:819` / `:870` | `:934` / `:940` |
| `debug_context` | `:774` | `CoworkRelayDebugContext` `:914` |
| `stop` / `stop_ack` / `replay` | `:334` / `:352` / `:262` | — |

Rendering-side inline widgets that already exist:
`app/lib/widgets/ask_user_card.dart` (option chips under an `ask_user` tool
call — the closest thing to a "form" today), `app/lib/widgets/mcp_connect_card.dart`
(written, **not yet mounted** in the thread view, see its header comment at
`:11`–`:12`), `app/lib/widgets/automation_card.dart`,
`app/lib/widgets/sandbox_artifact_block.dart`,
`app/lib/models/content_block.dart:4` (`ContentBlockType { text, toolCalls,
reasoning, sandboxArtifact }`).

**Important structural detail:** `secret_request` and `approval_request` are the
only two *blocking* host→app frames, and neither is a transcript message. They
render as pinned bars above the composer
(`app/lib/widgets/cowork_thread_view.dart:1276`–`:1281`), they are **not**
persisted as event rows, and they are **not** replayed from the store — the
executor holds them in memory and re-sends on the next `replay` of that session
(`executor/src/cowork_executor/executor.py:1737` →
`_flush_pending_secret_requests` at `:2722`). The run ledger records an approval
as a synthetic completed `ask_user` tool call
(`app/lib/services/cowork/cowork_run_ledger.dart:684`); **no equivalent exists
for `secret_request`**, so a secret request leaves no trace in the transcript at
all.

---

## 4. How the sandbox/agent gets env vars and credentials

- **Never an `.env` file, never a file in the workspace.** Stated in
  `docs/WIRE_CONTRACT.md:868` and enforced by the injection code.
- The host holds one `SecretsVault` per user, built in
  `host/src/cowork_host/host.py:238`–`:242`, loaded from disk at `:242`.
- Values are injected per command only:
  `agent/src/cowork_agent/tools.py:187` (`_secret_env`) → `env.run_bash(..., env=…)`
  → `sandbox/src/cowork_sandbox/docker.py:444` (`docker exec -e NAME`, value from
  the client's own env, never argv) or `sandbox/src/cowork_sandbox/local.py:79`.
- Background/tmux jobs get the same seam:
  `agent/src/cowork_agent/shell_tools.py:249`, `:276`–`:279`.
- Subagents inherit the parent's seam:
  `executor/src/cowork_executor/executor.py:3738`–`:3743`.
- Room turns get it too: `host/src/cowork_host/host.py:258`.
- The container image itself carries **no** credentials — see
  `sandbox/docker/Dockerfile` and `sandbox/docker/entrypoint.sh`.
- MCP servers are the exception: their bearer is attached as an
  `Authorization: Bearer …` HTTP header inside the agent process
  (`agent/src/cowork_agent/mcp_client.py:739`–`:762`), never exported to the shell.

---

## 5. Encryption at rest

**Client (Flutter)**
- `app/lib/services/secrets/secrets_store.dart:60` — the whole set is one record,
  key `cowork_secrets_v1`, in `flutter_secure_storage` via
  `FlutterSecureKeyValueStore` (defined in
  `app/lib/services/cowork/cowork_pairing_store.dart`).
- `app/lib/services/encryption_service.dart:187` — `EncryptionService`,
  AES-256-GCM under a password-derived key; the key itself sits in
  `FlutterSecureStorage` (`:190`). Unlocked at login
  (`app/lib/pages/login_page.dart:63`).
- `flutter_secure_storage: ^10.0.0` (`app/pubspec.yaml:47`).
- **Known limitation, already noted in the code:**
  `app/lib/services/password_revision_service.dart:142` — "secure-at-rest on
  Linux requires flutter_secure_storage" (desktop Linux backing is weaker than
  Keychain/Keystore).

**Supabase (cloud)**
- `cowork_secrets.ciphertext` is client-side AES-256-GCM; the server sees opaque
  blobs. Names are plaintext labels by design
  (`supabase/migrations/20260905120000_cowork_secrets.sql:26`).

**Host (Python)**
- `~/.cowork/secrets.enc`, AES-256-GCM, `0600`, written atomically:
  `executor/src/cowork_executor/secrets.py:171` (`save`), `:206` (`load`),
  AAD `b"cowork/host/secrets-at-rest/v1"` at `:246`.
- The key is **derived**, not stored: HKDF-SHA256 over the host's Ed25519 device
  seed — `host/src/cowork_host/secrets_key.py:26` (`secrets_at_rest_key`).
  Deleting `host_device.key` makes the vault unreadable, which is the intended
  "this host is no longer mine" behaviour.
- `forget_at_rest()` at `executor/src/cowork_executor/secrets.py:237`.
- Caps: `MAX_VALUE_CHARS = 8192`, `MAX_ENTRIES = 256` (`:44`–`:45`).

---

## 6. What would have to change to make the secret request an inline chat message

The transport, the blocking round-trip, the vault, the scrubber and the crypto
are all done. Only the **presentation and the ledger** are missing. The files:

1. `app/lib/widgets/cowork_thread_view.dart` — move `_buildSecretRequestBar`
   (`:1500`) out of the pinned area (`:1276`–`:1281`) and render it as a list
   item in the transcript; drop the `topInset` bump at `:1434`.
2. `app/lib/services/cowork/cowork_run_ledger.dart` — add a secret-request entry
   next to the approval→`ask_user` mapping at `:275`/`:306`/`:684`, so the card
   has a position in the message list and survives a rebuild.
3. `app/lib/services/cowork/cowork_relay_client.dart` — `CoworkRelaySecretRequest`
   (`:1075`) needs whatever extra fields the inline card wants (a per-name label
   or hint); `sendSecrets` at `:2307` stays as is.
4. `executor/src/cowork_executor/protocol.py:758` (`secret_request_payload`) and
   `:733` (`secrets_payload`) — only if new optional fields are added.
5. `executor/src/cowork_executor/executor.py` — `_request_secrets` (`:2764`) and
   `_flush_pending_secret_requests` (`:2722`) if the card must survive a replay
   as a *stored* row rather than an in-memory re-send.
6. `agent/src/cowork_agent/secrets.py:168` (`REQUEST_SECRETS_SCHEMA`) — only if
   the model should be able to attach a per-name hint/placeholder.
7. `docs/WIRE_CONTRACT.md:851`–`:960` — the contract text for any field change.
8. Tests that pin the current behaviour:
   `app/test/widgets/cowork_thread_view_secrets_test.dart`,
   `app/test/services/cowork/cowork_relay_secrets_test.dart`,
   `app/test/services/secrets/secrets_store_test.dart`,
   `agent/tests/test_secrets.py`, `executor/tests/test_secrets_e2e.py`,
   `host/tests/test_secrets_vault.py`.

**No change is needed** to make the value miss the model — `Scrubber`
(`agent/src/cowork_agent/secrets.py:97`), `result_filter`
(`registry.py:226`), `persist_filter` (`loop.py:312`) and the frame sealer
(`executor.py:1661`) already guarantee that, and the value never travels through
a model-visible field in the first place.
