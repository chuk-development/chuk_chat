# How Grok Bot 0.47 passes credentials to an agent without the agent seeing them

Source: static analysis of `grok-bot_0.47.0_amd64.deb` (Electron app, product name
`sand`, by Anysphere/Cursor). Evidence is the unpacked `app.asar`: the minified
bundles `dist/electron-main/main-app.cjs`, `dist/electron-main/onepassword-connection-service.cjs`,
`dist/node-agent-coordinator/main.cjs`, `dist/local-exec-daemon/main.cjs` and the
renderer chunks. Protobuf type names and UI strings survive minification, so the
protocol can be read exactly.

There are four separate credential paths. They never overlap.

## 1. Inline secret request (the "Paste your API key / Save securely" card)

This is the flow in the screenshot ("Stored securely, never shown to your Bot.").

The agent does not ask for the key in prose. It emits a typed chat card. The chat
transcript is a list of typed cards, not text; the card kinds are visible in the
renderer bundle as leaked source paths:

    /src/electron-renderer/features/chat/cards/send-message/secret-request/{card.ts,view.tsx}
    /src/electron-renderer/features/chat/cards/send-message/credential-request/…
    /src/electron-renderer/features/chat/cards/send-message/user-form/…
    /src/electron-renderer/features/chat/cards/send-message/local-tool-permission/…
    /src/electron-renderer/features/chat/cards/send-message/virtual-card-approval/…
    …plus text, attachment, widget, email-draft, slack-draft, connector,
    cookie-origin-approval, auto-review-approval, team-access, bot-template-share

The `secret-request` card carries only a **label** — the model writes
`secretRequest.label` ("Bland API key") and nothing else. Proof: the transcript
cache key for that card is built from `e.secretRequest.label.length`, the only
field read anywhere in the renderer.

The input field is a normal React input whose value goes **straight to the backend**,
never through `sendPrompt`:

    submitSecret({ entryId, value, agentId, sessionId })     // chunk-view-B3oZDmb9.js
    → aiserver.v1.SubmitGrokBotSecretRequest { agent_id, entry_id, value, session_id }
    → SubmitGrokBotSecretResponse { accepted, refusal }

The value is bound to `entry_id` (the pending request), not to a message. The
local state is cleared the moment it is sent. Afterwards the card re-renders in a
"saved" state showing dots — the UI string is "Dots mark a value that is already
stored." The agent's turn is paused while the request is open; the failure string
"Bot failed to resume after secret submission" shows the turn is resumed by the
server, not by a chat message.

So the model sees: a request it made, and later the fact that it was answered.
It never sees the value.

## 2. User secrets store (Settings → Secrets), pushed into the cloud box as env vars

`dist/electron-main/main-app.cjs` contains the whole store.

* File: `<userData>/user-secrets.json`, `version: 2`, keyed by account scope,
  written atomically with mode `0600`.
* Each value is encrypted with Electron `safeStorage` (OS keychain/keyring) and
  stored base64. Class `ON`: `safeStorage.encryptString(v).toString("base64")`,
  `reveal()` decrypts on demand.
* If the OS keyring is unavailable the store degrades to memory only, and warns:
  "OS secure storage (keychain/keyring) is unavailable; box secrets are kept in
  memory for this session only and will NOT persist across restart."
  Errors are typed: `SandSecureStorageUnavailableError`,
  `SandSecretsSnapshotUndecryptableError`, `SandSecretsAccountRequiredError`.
* Validation before accepting a secret (`kFe`): name must match
  `^[A-Za-z_][A-Za-z0-9_]*$`; reserved names `PATH HOME USER SHELL TERM PWD DISPLAY`;
  reserved prefixes `SAND_`, `__CURSOR`, `LD_`; also anything matching
  `/CURSOR_SANDBOX/i`. Max 100 secrets, max 32 KiB per value, max 96 KiB total.
  The reserved names prove the delivery form: **environment variables inside the box.**
* Delivery: `pushBoxSecrets` → RPC `setBoxSecrets({ secrets })`. The desktop
  decrypts, sends the snapshot to the host, and telemetry records only
  `secretCount` / `scopeHash` / `applied`, never keys or values.

The agent process gets the env vars. The model gets the transcript. Those are
two different channels — that is the whole trick.

## 3. 1Password: a scoped, expiring, read-only service account

`dist/electron-main/onepassword-connection-service.cjs` is a separate process.
It downloads and verifies the 1Password CLI itself (size/type checks, "The
1Password CLI archive is invalid."), talks to the desktop app for approval ("The
request was not approved in the 1Password desktop app."), and then runs:

    op service-account create <name> --account <uuid> --vault <vaultId>:read_items --expires-in <N>s --raw

So the token is read-only, limited to one dedicated vault, and expires. The user
never pastes a master password and never pastes the token. The token goes to the
server through a two-step mint with a ticket:

    BeginOnePasswordConnection  { connection_id, vault_id }
      → { mint_ticket, expected_generation, expiration_mode,
          provider_expires_in_seconds, credential_expires_at_ms,
          ticket_expires_at_ms, policy_version }
    CompleteOnePasswordConnection { mint_ticket, service_account_token,
                                    account_uuid, account_email, account_url }

What the agent can see is only the **catalog**, which has no secret field at all:

    OnePasswordCredentialItem { credential_id, title, category, sites[],
                                target_rules[], vault_name, connection_id,
                                catalog_revision }
    CredentialTargetRule      { kind, scheme, host, port, registrable_domain }

Use is per-request and per-site:

    ApproveOnePasswordCredentialRequest { entry_id, agent_id, credential_id,
                                          connection_id, catalog_revision, target_site }
    DenyOnePasswordCredentialRequest    { entry_id, agent_id }
    SetOnePasswordAlwaysAllow           { connection_id, always_allow }

`catalog_revision` makes the approval stale if the vault changed; `target_site`
plus `CredentialTargetRule` binds the credential to a host. The fill happens in
the browser inside the box; the result reported back into the chat is literally

    "Filled into the page. Secret values were never shown to your Bot."
    "Could not fill into the page — it may have moved or changed. Secret values were never shown to your Bot."

`OnePasswordConnection` also tracks `credential_generation`, `issued_at_ms`,
`expires_at_ms`, `renew_by_at_ms`, `reminder_at_ms`, `lifecycle_state` — i.e.
rotation is a first-class state machine, not a manual step.

## 4. Form vault (addresses, names, "Saved form values")

Non-secret-but-private values that the agent should fill without reading:

    GrokBotUserFormVaultEntry { entry_id, kind, label, extra_key, value,
                                created_at_ms, last_used_at_ms, origin_host }
    List/Upsert/DeleteGrokBotUserFormVaultEntry, ListGrokBotUserFormVaultKeys

The agent sends a `user-form` card (`formRequest { title, fields[] }`); the client
prefills from the vault (`getUserFormPrefill`) and the user submits with
`submitUserForm`. Same shape as the secret request: values go to the backend, the
transcript keeps the request and the fact of an answer.

## 5. Log and diagnostic scrubbing

`main-app.cjs` carries a scrub table applied to crash/update diagnostics:

    AKIA[0-9A-Z]{16}            → [REDACTED:AWS_ACCESS_KEY]
    ASIA[0-9A-Z]{16}            → [REDACTED:AWS_SESSION_KEY]
    gh[pousr]_[A-Za-z0-9]{30,}  → [REDACTED:GITHUB_TOKEN]
    github_pat_[A-Za-z0-9_]{20,}→ [REDACTED:GITHUB_TOKEN]
    xox[baprs]-…                → [REDACTED:SLACK_TOKEN]
    npm_[A-Za-z0-9]{30,}        → [REDACTED:NPM_TOKEN]
    sk-[A-Za-z0-9_-]{20,}       → [REDACTED:API_KEY]
    eyJ….….                     → [REDACTED:JWT]
    -----BEGIN … PRIVATE KEY----- → [REDACTED:PRIVATE_KEY]
    (key|token|sig|secret|signature|password|passwd|pwd)=…  → [REDACTED]

Sentry payloads are scrubbed separately (`<REDACTED: user-file-path>`,
`<REDACTED: url>`, `<REDACTED: exception-message>`). MCP config can be fetched for
editing with `GetMcpConfigRequest({ redactSecrets: true })` so the settings UI
never holds the real values.

## Related hardening in the same release

* WebAuthn proxy: the box's browser can use a YubiKey plugged into the desktop.
  "Allow Grok Bot to use a security key (such as a YubiKey) connected to your
  computer. You'll be asked to approve each use." / "Require a hardware security
  key, like a YubiKey, for sensitive actions."
* Egress tunnel: the box's traffic is routed through the desktop's network, so
  logins are not seen from a datacenter IP ("Route egress through this desktop").
* Chrome cookie import: `injectChromeCookies` copies sessions, explicitly
  "Only cookies are copied, not passwords."
* `virtual-card-approval` card + `listVirtualCardPaymentMethods`: payments are a
  separate approval kind with its own card.
