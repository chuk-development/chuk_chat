# Agent mail

Each paying user gets one email address for the agent. The agent can
receive and send mail. Each new mail can start an agent run. The user can
read and manage the mailbox in the app.

Tracking: bd `chuk_chat-m0j3`. Version 2 (2026-10-01): Cloudflare only,
all mail sealed at rest. Resend is gone.

## 1. Decisions

| Topic | Decision |
|---|---|
| Provider | Cloudflare Email Service only. Inbound: Email Routing (free) with a catch-all rule to the Worker `agent-mail-inbound`. Outbound: Email Sending REST API (Workers Paid, 3 000 mails per month included). |
| Provider storage | Cloudflare keeps metadata only. **Email preview** on the sending domain must stay OFF, otherwise Cloudflare keeps sent mail for 7 days. |
| Domain | `chukagents.com`, DNS at Cloudflare. A separate domain, so abuse does not put `chuk.chat` on block lists. |
| Address | One address per user, for ever. Local part: 10 random characters from `abcdefghijkmnpqrstuvwxyz23456789`, for example `k7f3q9x2mh@chukagents.com`. Never given to a different user. |
| Who gets one | Only users with an active subscription (`user_billing.is_subscribed`). |
| Subscription ends | The mailbox is frozen: no send, incoming mail is rejected. A new subscription unfreezes the same address. |
| Unknown address | The Worker rejects the mail at SMTP time (`setReject`). |
| Storage | Every content field is **sealed** to the user's mail key (§3). The server keeps plaintext only in memory while it handles one request. No log line contains content, subjects or addresses. |
| Privacy text | The app says: agent mail is normal email, not end-to-end encrypted; it is stored encrypted. |

## 2. Trust model

Source: Meta "Agents Rule of Two", Manus Mail, Microsoft FIDES, Google CaMeL.
A run must not have untrusted input, private data and outside
communication at the same time.

Each incoming mail gets one `sender_trust` value, set by the server at
arrival:

| Value | Rule |
|---|---|
| `owner` | The From address is the email of the user account, and the mail has a valid DKIM signature whose `d=` domain aligns (relaxed) with the From domain. |
| `trusted` | The From address (or its `@domain`) is a contact with `trusted_inbound = true`, and aligned DKIM passes. |
| `unknown` | All other mail. No aligned DKIM always gives `unknown`. |

Outgoing rows (sent mail and drafts) carry `self`. A reply whose parent is an
`unknown` mail keeps `unknown`, so a full run cannot read it (§7). Clients
must know all four values.

The server checks DKIM itself (`dkimpy`) on the raw message. It does not
trust `Authentication-Results` headers in the message. A mail from a
`blocked` contact is dropped.

Rules:

1. **Unknown text only goes into a restricted run.** The server cannot read
   stored mail any more, so the **host code** enforces this rule: for an
   `unknown` mail, full-run tools give only sender, subject, `codes` and
   `links`. The server computes `codes` and `links` at arrival with a fixed
   pattern and seals them with the mail.
2. **A restricted run has no power.** No shell, files, browser, memory, MCP
   or chat search. It can read its one mail, write a note, write a reply
   draft (always a draft) and archive.
3. **The server decides when a mail is sent.** Direct only when each
   recipient is the owner, a contact with `allowed_outbound = true`, or the
   host sets `user_requested = true` (only for runs the user started in the
   app). Else the server stores a **draft**. The user sends or discards it in
   the app; sending marks its recipients `allowed_outbound`.
4. **Trust a sender** in the app sets both `trusted_inbound` and
   `allowed_outbound`.

## 3. Encryption at rest

### 3.1 Mail key

* Each user has one X25519 key pair, the **mail key**. The **app** makes it
  when the user first opens the mailbox (Settings → Agents → Mailbox).
* Table `agent_mail_keys`: `user_id` (primary key), `public_key` (base64 of
  the raw 32 bytes), `private_key_sealed` (the raw private key, sealed by the
  app with the user's chuk key through `EncryptionService`, the same way as
  chats), `created_at`.
* The server reads only `public_key`. It never sees the private key.
* The app gives the raw private key to the host over the end-to-end relay
  (sealed app frame `agent_mail_key`, §6.1). The host keeps it in its local
  secret store.
* A mailbox needs a mail key. Without one, `GET /mailbox` answers
  `status: "needs_key"` and incoming mail is rejected.

### 3.2 Seal format `chuk-agent-mail-v1`

Sealing to a public key `R` (32 bytes):

1. New ephemeral X25519 key pair `e`, `E`.
2. `shared = X25519(e, R)`.
3. `key = HKDF-SHA256(ikm = shared, salt = E ‖ R, info = "chuk-agent-mail-v1", length = 32)`.
4. `nonce` = 12 random bytes. `ct = AES-256-GCM(key, nonce, plaintext, aad = "chuk-agent-mail-v1")` (the 16-byte tag at the end).
5. Text form (JSON fields): `{"v":1,"epk":b64(E),"n":b64(nonce),"ct":b64(ct)}`, standard base64 with padding.
6. Binary form (attachment objects): `"CAM1" ‖ E ‖ nonce ‖ ct`.

Test vector (every implementation must decrypt it, and produce it when `e`
and `nonce` are fixed):

| Item | Value |
|---|---|
| recipient private key (hex) | `0102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f20` |
| recipient public key (b64) | `B6N8vBQgk8i3VdwbEOhstCY3StFqqFPtC9/AsrhtHHw=` |
| ephemeral private key (hex) | `65666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f8081828384` |
| nonce (hex) | `c9cacbcccdcecfd0d1d2d3d4` |
| plaintext (UTF-8) | `hello agent mail ✓` |
| text envelope | `{"v":1,"epk":"VxR2nRFr92Q2rnS8eT0sMK0ZA8WaxSc4BcfiaYtBDDY=","n":"ycrLzM3Oz9DR0tPU","ct":"bPxiL4cAEjEH7OPALFms6fEudfWc8Wz6VHV5vyBhIkO5Cis9"}` |
| binary envelope (b64) | `Q0FNMVcUdp0Ra/dkNq50vHk9LDCtGQPFmsUnOAXH4mmLQQw2ycrLzM3Oz9DR0tPUbPxiL4cAEjEH7OPALFms6fEudfWc8Wz6VHV5vyBhIkO5Cis9` |

### 3.3 What is sealed

Each message row has two sealed JSON documents:

* `sealed_summary`: `{subject, from_address, from_name, to, snippet}`.
* `sealed_body`: `{text, cc, message_id, in_reply_to, references, codes, links, attachments: [{id, filename, content_type, size, too_large}], auth: {dkim_aligned, dkim_domain}}`. A `too_large` attachment is listed but not stored. Outgoing rows have `message_id: null` and `auth: null`.
* `agent_note_sealed`: `{note}` (the host sends the note in plain text; the server seals it).
* Attachment objects in the bucket `agent-mail` use the binary form, path `<user_id>/<message_id>/<attachment_id>`.

Plain columns (no content): `id, mailbox_id, user_id, direction
(inbound|outbound), provider_id, thread_id, sender_trust, folder, read,
is_bulk, has_attachments, attachment_count, size_bytes, status, importance,
draft_reason, delivered_to_host_at, sent_at, created_at, updated_at`.

`thread_id` is a server UUID. Replies name their parent by
`reply_to_message_id` (a row id); the client sends the `In-Reply-To` and
`References` values it read from `sealed_body`.

Contacts: `address_hash = HMAC-SHA256(AGENT_MAIL_CONTACT_PEPPER, lower(address))`
(an address or `@domain`), `label_sealed = seal({address})`, flags. The
server matches a From address by the hash of the address and of its
`@domain`.

Waits: `from_contains` and `subject_contains` stay in plain text only while
the wait is open. The row is deleted when it matches or expires.

## 4. Limits

| Limit | Value |
|---|---|
| Recipients per mail (to + cc) | 5 |
| Sent mails per user | 5 per hour, 10 per day |
| Sent mails, all users | stop at `AGENT_MAIL_PLAN_DAILY` (100) per day and `AGENT_MAIL_PLAN_MONTHLY` (3 000) per month, the included quota |
| Quota alert | at 80 % of the daily or monthly plan, once per period: PostHog event `agent_mail_quota_warning`, a log line, and a mail to `AGENT_MAIL_ALERT_TO` when set |
| Open drafts per user | 20 (`429 rate_limited` above) |
| Restricted runs | 20 per mailbox per day, 300 s wall clock, 8 model rounds |
| Bulk mail | `List-Unsubscribe` or `Precedence: bulk/list`: stored with `is_bulk = true`, never starts a run |
| Send suspension | 3 permanent bounces in 24 hours set `send_suspended_at` |
| Size | inbound message max 25 MB (Cloudflare limit); attachments max 10 MB each, 25 MB per mail, larger ones listed as `too_large`; outbound message max 5 MiB in total (Cloudflare limit), so outbound attachments max 3 MiB raw in total (4 MiB as base64), else `422 attachments_too_large`; outbound mail is plain text only; subject max 300 characters; outbound text max 100 KB; inbound text cut at 200 KB |

## 5. Server (api_server)

### 5.1 Environment

| Variable | Use |
|---|---|
| `CLOUDFLARE_ACCOUNT_ID` | Account of the Email Sending domain. |
| `CLOUDFLARE_EMAIL_TOKEN` | API token with the Email Sending permission only. |
| `AGENT_MAIL_DOMAIN` | `chukagents.com`. |
| `AGENT_MAIL_INBOUND_SECRET` | Shared HMAC key with the Worker. |
| `AGENT_MAIL_CONTACT_PEPPER` | HMAC key for contact hashes. |
| `AGENT_MAIL_PLAN_DAILY` | default `100`. |
| `AGENT_MAIL_PLAN_MONTHLY` | default `3000`. |
| `AGENT_MAIL_ALERT_TO` | optional address for quota alerts. |

Without `CLOUDFLARE_*`, `AGENT_MAIL_DOMAIN` or `AGENT_MAIL_INBOUND_SECRET`,
every agent mail route answers `503 {"detail": "agent_mail_unavailable"}`.

### 5.2 Inbound: `POST /internal/agent-mail/inbound`

Only the Worker calls it. Body: the raw RFC 5322 message
(`application/octet-stream`). Headers:

* `x-agent-mail-to`: the envelope recipient (one address).
* `x-agent-mail-from`: the envelope sender.
* `x-agent-mail-timestamp`: unix seconds.
* `x-agent-mail-signature`: `v1=` + hex HMAC-SHA256 with
  `AGENT_MAIL_INBOUND_SECRET` over `timestamp + "\n" + to + "\n" + from + "\n" + hex(sha256(body))`.
  Tolerance 5 minutes; constant-time compare.

Steps: check the signature; find the mailbox of `to` (none, frozen, no
subscription or no mail key: answer `404 {"status":"reject"}`, the Worker
rejects); dedupe by `provider_id = hex(sha256(body))` per mailbox; parse the
MIME with the stdlib `email` package (text part, HTML to text fallback,
attachments); check DKIM (§2); set `sender_trust` and `is_bulk`; drop mail
from blocked contacts (`200 {"status":"dropped"}`); extract `codes`/`links`;
seal and store; store sealed attachments; match open waits; push the relay
frame `{"type":"agent_mail","event":"new","message_id"}` (no content) unless
a wait took the mail; count usage. Answer `200 {"status":"stored"}`. A
server error answers `5xx`; the Worker then throws, so the sending server
retries later.

### 5.3 REST API

All routes need `Authorization: Bearer <Supabase access token>`. The app and
the host use the same kind of token. Errors: `{"detail": "<code>"}`.

| Method and path | Result |
|---|---|
| `GET /v1/agent-mail/mailbox` | `{address, status: "active"\|"frozen"\|"needs_key", send_suspended, created_at}`. Makes the mailbox with a subscription. No subscription and no mailbox: `402 no_subscription`. |
| `GET /v1/agent-mail/key` | `{public_key, private_key_sealed}` or `404 no_key`. |
| `PUT /v1/agent-mail/key` | Body `{public_key, private_key_sealed}`. Only when no key exists (else `409 key_exists`). |
| `GET /v1/agent-mail/messages` | Query: `folder` (`inbox`, `archive`, `trash`, `sent`, `drafts`, `all`; default `inbox`), `trust` (`unknown`, `known`), `undelivered` (bool), `limit` (max 100), `before` (ISO time). Result: `{messages: [Summary], next_before}`. |
| `GET /v1/agent-mail/messages/{id}` | `Message`. |
| `PATCH /v1/agent-mail/messages/{id}` | Body `{folder?, read?, agent_note?, importance?}`. `agent_note` is plain text; the server seals it. |
| `DELETE /v1/agent-mail/messages/{id}` | Deletes the row and its stored attachments. |
| `GET /v1/agent-mail/messages/{id}/attachments/{attachment_id}` | The sealed binary object (the client unseals it). |
| `POST /v1/agent-mail/messages/claim` | Body `{ids}`. Sets `delivered_to_host_at` where empty. `{claimed}`. |
| `POST /v1/agent-mail/send` | Body `{to, cc?, subject, text, reply_to_message_id?, in_reply_to?, references?, attachments?: [{filename, content_type, content_base64}], user_requested?, force_draft?}`. `200 {id, status:"sent"}` or `202 {id, status:"draft", reason}`. Errors: `402 no_subscription`, `403 mailbox_frozen`, `403 send_suspended`, `422 too_many_recipients`, `429 rate_limited`, `429 quota_exhausted`. |
| `POST /v1/agent-mail/drafts/{id}/send` | Body `{to, cc?, subject, text, in_reply_to?, references?}`: the app sends the full draft (it decrypted it; the user can edit). The server replaces the sealed draft, sends it, marks the recipients `allowed_outbound`. |
| `GET /v1/agent-mail/contacts` | `{contacts: [{id, label_sealed, trusted_inbound, allowed_outbound, blocked, created_at}]}`. |
| `PUT /v1/agent-mail/contacts` | Body `{address, trusted_inbound?, allowed_outbound?, blocked?}` (plain address; the server hashes and seals). Upsert. `{contact}`. |
| `DELETE /v1/agent-mail/contacts/{id}` | Removes the contact. |
| `POST /v1/agent-mail/waits` | Body `{from_contains?, subject_contains?, timeout_s}` (max 600). `{wait_id, expires_at}`. |
| `GET /v1/agent-mail/waits/{id}` | `{status: "pending"\|"matched"\|"expired", message_id?}`. |

`Summary`: `id, direction, thread_id, sender_trust, folder, read, is_bulk,
has_attachments, attachment_count, status, importance, draft_reason,
created_at, sealed_summary, agent_note_sealed`.

`Message`: `Summary` + `sealed_body`.

### 5.4 Sending

`POST https://api.cloudflare.com/client/v4/accounts/{CLOUDFLARE_ACCOUNT_ID}/email/sending/send`
with `Authorization: Bearer $CLOUDFLARE_EMAIL_TOKEN`. Body: `from: {address,
name}`, `to`, `cc`, `subject`, `text`, `headers` (`In-Reply-To`,
`References`), `attachments`. The response lists `delivered`,
`permanent_bounces` and `queued`. A permanent bounce sets
`allowed_outbound = false` for that recipient and counts toward the send
suspension. The server stores the sent copy sealed.

## 6. Worker `agent-mail-inbound`

Code: `api_server/workers/agent-mail-inbound/` (TypeScript, `wrangler.jsonc`).
Secrets: `AGENT_MAIL_INBOUND_SECRET`. Variable: `API_URL`
(`https://api.chuk.chat`).

`email(message, env, ctx)`: buffer `message.raw` once; if `message.rawSize`
is above 25 MB, reject; sign and `POST` to `/internal/agent-mail/inbound`;
`404` → `message.setReject("Unknown address")`; `2xx` → done; anything else
→ throw (temporary failure, the sender retries). The Worker logs no content
and no addresses. Routing: Email Routing catch-all → Worker.

### 6.1 Relay frame and key hand-over

* Relay control frame from the server: `{"type":"agent_mail","event":"new","message_id"}`.
* Sealed app frame from the app to the host: `{"type":"agent_mail_key","public_key","private_key"}` (base64 raw keys). The app sends it each time its end-to-end channel to a host comes up, and after it makes a new key. The host stores it when it differs from the stored key and answers nothing. The frame is idempotent.

## 7. Host and runtime (agents/)

* Fetch on frame, on start, on reconnect, every 5 minutes.
* Keep the mail private key in the host secret store; without it the mail
  tools say "open the app once and go to Settings > Agents > Mailbox" (the
  app makes the key on that page, §8) and dispatch pauses.
* Unseal `sealed_summary`, `sealed_body`, `agent_note_sealed` and attachments locally.
* **HostView (host code, not the model):** `owner`, `trusted` and `self`
  give the full text (max 8 000 characters). `unknown` gives only
  `{id, from_address, subject, sender_trust, codes, links, note}`.
* Dispatch: `is_bulk` → claim, no run. `owner`/`trusted` → claim, full run
  on the host agent session (`origin = "mail"`), several waiting mails in
  one run. `unknown` → wait until 30 s old, claim, restricted run
  (`origin = "mail_untrusted"`, session `mail:<id>`, own store, no transcript
  export).
* Mail automations (`docs/WIRE_CONTRACT.md`, "Event triggers"): every
  claimed mail is offered as its summary (HostView shape) to the `mail`
  automations. A match fires that automation in its own session. A trusted
  mail an automation took leaves the general full run; an unknown mail keeps
  its restricted run; bulk still starts no run of its own.
* Tools in a full run: `mail_address`, `mail_list`, `mail_read`, `mail_send`,
  `mail_reply`, `mail_archive`, `mail_delete`, `mail_wait`.
* Tools in a restricted run: `mail_read`, `mail_note`, `mail_draft_reply`
  (`force_draft: true`), `mail_archive`.
* `user_requested` only for `origin = "app"`; a forged app origin is refused.
* Attachments for `mail_send` only from the run workspace.

## 8. App (Flutter)

* Entry: row "Mailbox" in the Agents settings (phone and desktop).
* Mail key: make, seal with the chuk key, `PUT /key`; hand it to the host.
* Mailbox page: address with copy action, filter `Inbox | Unknown | Drafts | Sent`, Archive row, Contacts row, the privacy text of §1.
* Mail page: unseal and show sender, trust badge, date, agent note, text, attachments (download unseals). Actions: archive, delete, trust sender, block sender. Drafts: edit, send (full draft in the body), discard.
* Contacts: unseal `label_sealed`; delete by id.
* No subscription: info card. `needs_key`: the app makes the key.
* The app never renders mail HTML.

## 9. Cloudflare set-up (by hand)

1. Workers Paid on the account.
2. `chukagents.com`: Email Sending enabled; **Email preview OFF**.
3. Email Routing enabled; catch-all rule → Worker `agent-mail-inbound`.
4. Account-owned API token with the permission **Email Sending: Edit** → `CLOUDFLARE_EMAIL_TOKEN`; account id → `CLOUDFLARE_ACCOUNT_ID`.
5. `_dmarc` TXT `v=DMARC1; p=quarantine;`.

## 10. Release order

1. Apply the v2 migration (`scripts/apply_migration.py`).
2. Set the environment in Dokploy, push api_server, check `/health`.
3. Deploy the Worker (`wrangler deploy`), set its secret, set the catch-all rule.
4. Push chuk_chat; update the host; ship the app.

## 11. Open points

* More than one address per agent.
* HTML view in the app.
* Key rotation.
