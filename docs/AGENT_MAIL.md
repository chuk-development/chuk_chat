# Agent mail

Each paying user gets one email address for the agent. The agent can
receive and send mail. Each new mail can start an agent run. The user can
read and manage the mailbox in the app.

Tracking: bd `chuk_chat-m0j3`.

## 1. Decisions

| Topic | Decision |
|---|---|
| Provider | Resend (resend.com), free plan: 3 000 mails per month, 100 per day. Receiving is included. Price is per mail, not per address. |
| Domain | `chukagents.com`. DNS at Cloudflare. It is a separate domain, so abuse does not put `chuk.chat` on block lists. |
| Resend region | `eu-west-1` (Ireland). |
| Address | One address per user, for ever. The local part is 10 random characters from `abcdefghijkmnpqrstuvwxyz23456789`, for example `k7f3q9x2mh@chukagents.com`. The address is never given to a different user. |
| Who gets one | Only users with an active subscription (`user_billing.is_subscribed`). The server makes the mailbox on the first request. |
| Subscription ends | The mailbox is frozen: no send, incoming mail is dropped. A new subscription unfreezes the same address. |
| Unknown address | Mail to an address that does not exist is dropped. |
| Storage | Supabase tables, written only by the API server (service role). RLS is on with no policies. The app reads through the REST API. Mail is not end-to-end encrypted (see §9). |

## 2. Trust model

Source: Meta "Agents Rule of Two", Manus Mail, Microsoft FIDES, Google CaMeL.
A run must not have untrusted input, private data and outside
communication at the same time.

Each incoming mail gets one `sender_trust` value:

| Value | Rule |
|---|---|
| `owner` | The From address is the email of the user account, and `authentication.dmarc == "pass"`. |
| `trusted` | The From address (or its `@domain`) is a contact with `trusted_inbound = true`, and `dmarc == "pass"`. |
| `unknown` | All other mail. A failed DMARC check always gives `unknown`. |

A mail from a `blocked` contact is dropped.

Rules that follow from this:

1. **Unknown text only goes into a restricted run.** A full run never sees
   the text of an `unknown` mail. `mail_read` and `mail_wait` in a full run
   give only the sender, the subject, and codes and links taken out by a
   fixed pattern on the server (§5.4). No model is used for this.
2. **A restricted run has no power.** No shell, no files, no browser, no
   memory, no MCP, no chat search. It can only read its one mail, write a
   note, write a reply draft, and archive.
3. **The server decides when a mail is sent.** A mail goes out directly only
   when each recipient is the owner, a contact with
   `allowed_outbound = true`, or when the host sets `user_requested = true`.
   The host sets it only for runs that the user started in the chat. In all
   other cases the server stores a **draft**. The user sends or discards the
   draft in the app. When the user sends a draft, the recipients become
   `allowed_outbound` contacts.
4. **Trust a sender** in the app sets both `trusted_inbound` and
   `allowed_outbound`.

## 3. Limits

| Limit | Value |
|---|---|
| Recipients per mail (to + cc) | 5 |
| Sent mails per user | 5 per hour, 30 per day |
| Open drafts per user | 20. A new draft over the cap is `429 rate_limited`. |
| Restricted run time | 300 seconds wall clock, 8 model rounds |
| Sent mails, all users | stop at `AGENT_MAIL_PLAN_DAILY` (100) per day and `AGENT_MAIL_PLAN_MONTHLY` (3 000) per month |
| Quota alert | at 80 % of the daily or monthly plan (sent + received), once per period: PostHog event `agent_mail_quota_warning`, a server log line, and a mail to `AGENT_MAIL_ALERT_TO` when it is set |
| Restricted runs | 20 per mailbox per day. More unknown mail is stored, but no run starts. |
| Bulk mail | A mail with a `List-Unsubscribe` header or `Precedence: bulk/list` is stored with `is_bulk = true`. It never starts a run. |
| Send suspension | 3 bounces or complaints in 24 hours set `send_suspended_at`. Sending is then refused until the owner clears it. |
| Subject / text | subject max 300 characters, text body max 100 KB (outgoing). Incoming text is cut at 200 KB. |
| Attachments | incoming: max 10 MB each, 25 MB per mail, larger ones are listed as `too_large`. Outgoing: max 5 MB in total. Outgoing mail is plain text only. |

## 4. Server (api_server)

### 4.1 Environment

| Variable | Use |
|---|---|
| `RESEND_API_KEY` | Resend key with full access. |
| `RESEND_WEBHOOK_SECRET` | `whsec_…` secret of the Resend webhook. |
| `AGENT_MAIL_DOMAIN` | `chukagents.com`. |
| `AGENT_MAIL_PLAN_DAILY` | default `100`. |
| `AGENT_MAIL_PLAN_MONTHLY` | default `3000`. |
| `AGENT_MAIL_ALERT_TO` | optional address for quota alerts. |

When `RESEND_API_KEY` or `AGENT_MAIL_DOMAIN` is not set, every agent mail
route answers `503 {"detail": "agent_mail_unavailable"}`. The server gives the
same answer for a passing fault (for example a Supabase timeout). Thus only
the `GET /mailbox` probe tells a client that there is no mailbox; a 503 of
another route is retried.

### 4.2 Tables

`agent_mailboxes`, `agent_mail_messages`, `agent_mail_contacts`,
`agent_mail_waits`, `agent_mail_usage`. The migration is in
`api_server/supabase/migrations/`. Mailbox rows are never deleted; the user
FK is `on delete set null`, so a deleted account does not free the address.

### 4.3 REST API

All routes need `Authorization: Bearer <Supabase access token>`. The app and
the host use the same kind of token. Errors use FastAPI `{"detail": "<code>"}`.

| Method and path | Result |
|---|---|
| `GET /v1/agent-mail/mailbox` | `{address, status: "active"\|"frozen", send_suspended, created_at}`. Makes the mailbox when the user has a subscription. No subscription and no mailbox: `402 no_subscription`. |
| `GET /v1/agent-mail/messages` | Query: `folder` (`inbox`, `archive`, `trash`, `sent`, `drafts`, `all`; default `inbox`), `trust` (`unknown`, `known`), `undelivered` (bool), `limit` (max 100, default 50), `before` (ISO time). Result: `{messages: [Summary], next_before}`. |
| `GET /v1/agent-mail/messages/{id}` | `Message`. For the app. The host uses the `view` query (§5.4). |
| `PATCH /v1/agent-mail/messages/{id}` | Body `{folder?, read?, agent_note?, importance?}`. |
| `DELETE /v1/agent-mail/messages/{id}` | Deletes the row and its stored attachments. |
| `GET /v1/agent-mail/messages/{id}/attachments/{attachment_id}` | The attachment bytes. |
| `POST /v1/agent-mail/messages/claim` | Body `{ids: [..]}`. Sets `delivered_to_host_at` only where it is empty. Result `{claimed: [..]}`. |
| `POST /v1/agent-mail/send` | Body `{to: [..], cc?: [..], subject, text, reply_to_message_id?, attachments?: [{filename, content_type, content_base64}], user_requested?: bool, force_draft?: bool}`. `force_draft = true` always stores a draft, also for allowed recipients. Result `200 {id, status: "sent"}` or `202 {id, status: "draft", reason}`. Errors: `402 no_subscription`, `403 mailbox_frozen`, `403 send_suspended`, `422 too_many_recipients`, `429 rate_limited`, `429 quota_exhausted`. |
| `POST /v1/agent-mail/drafts/{id}/send` | Body `{text?, subject?}` (the user can edit). Sends the draft, marks its recipients `allowed_outbound`. |
| `GET /v1/agent-mail/contacts` | `{contacts: [Contact]}`. |
| `PUT /v1/agent-mail/contacts` | Body `{address, trusted_inbound?, allowed_outbound?, blocked?}`. `address` is an address or `@domain.tld`. Upsert. |
| `DELETE /v1/agent-mail/contacts?address=` | Removes the contact. |
| `POST /v1/agent-mail/waits` | Body `{from_contains?, subject_contains?, timeout_s}` (max 600). Result `{wait_id, expires_at}`. |
| `GET /v1/agent-mail/waits/{id}` | `{status: "pending"\|"matched"\|"expired", message?: HostView}`. `matched` has no `message` when the mail was deleted since. |
| `POST /webhooks/resend` | Resend webhook. No bearer token; the Svix signature is checked. |

`Summary`: `id, direction (inbound | outbound), thread_id, from_address, from_name,
to_addresses, subject, snippet, sender_trust, folder, read, is_bulk,
has_attachments, status, importance, agent_note, created_at`.

`Message`: `Summary` + `cc_addresses, text_body, message_id, in_reply_to,
attachments: [{id, filename, content_type, size, available, too_large}],
auth: {spf, dkim, dmarc}`. `available = false` with `too_large = false`
means that the download from Resend failed.

`PATCH` takes `folder` = `inbox`, `archive`, `trash` or the home folder of
the mail (`drafts` for a draft, `sent` for other outbound mail). A client
moves a mail back from the archive to its home folder, not to `inbox`.

`Contact`: `address, trusted_inbound, allowed_outbound, blocked, created_at`.

### 4.4 Incoming mail

1. Check the Svix signature on the raw body (`svix-id`, `svix-timestamp`,
   `svix-signature`; HMAC-SHA256 over `id.timestamp.body` with the base64
   key after `whsec_`; 5 minutes tolerance).
2. `email.received`: take the recipients (`to`, `cc`, `received_for`) at
   `AGENT_MAIL_DOMAIN`. Drop recipients with no mailbox or a frozen one.
3. Get the full mail: `GET https://api.resend.com/emails/receiving/{email_id}`.
   Use `text`; when it is empty, make text from `html`.
4. Set `sender_trust` (§2), `is_bulk` (§3). Drop mail from blocked contacts.
5. Store the row. `provider_id` (the Resend email id) is unique, so a repeated
   webhook does nothing.
6. Download attachments (list and retrieve received attachment API) into the
   private storage bucket `agent-mail`, path `<user_id>/<message_id>/<attachment_id>`.
7. Match open waits (§5.4). A matched mail is claimed and gets no push.
8. Else push the relay frame `{"type": "agent_mail", "event": "new",
   "message_id": "<uuid>"}` to all hosts of the user (local registry and peer
   mesh). The frame has no mail content.
9. Count the mail in `agent_mail_usage` and check the quota alert.

`email.bounced`, `email.complained`, `email.failed`, `email.delivered`
update the status of the sent mail. A bounce or complaint sets
`allowed_outbound = false` for that recipient and counts toward the send
suspension.

## 5. Host and runtime (agents/)

### 5.1 Frame

The host takes the `agent_mail` relay control frame in
`CloudRelayLink.handle_frame` and records it in the frame ledger. The frame
only tells the host to fetch. The host also fetches when it starts, when the
relay connects again, and every 5 minutes.

### 5.2 Dispatch

The host lists `undelivered=true` mail and handles each mail once:

| Mail | Action |
|---|---|
| `is_bulk` | Claim. No run. |
| `owner` or `trusted` | Claim, then start a **full run** on the main agent session with `origin="mail"`. The prompt gives sender, subject and text as data, not instructions (same framing as `fired_prompt`). More mails that wait are put into one run. |
| `unknown` | Wait until the mail is 30 seconds old (so that a `mail_wait` can take it first), claim, then start a **restricted run** with `origin="mail_untrusted"` on a new session key `mail:<message_id>`. Max 20 per day (§3). |

### 5.3 Restricted run

`build_runtime` with memory, terminal, browser, MCP, skills and chat search
off, a tool allowlist, a short system prompt for this job, and no transcript
export. Tools, all bound to the one mail:

* `mail_read()` — the mail text, marked as untrusted data.
* `mail_note(note, importance)` — `low`, `normal` or `high`; saved as
  `agent_note` / `importance` on the mail. The app shows it.
* `mail_draft_reply(text)` — always a draft (server `send` with
  `force_draft = true`, reply to the sender only).
* `mail_archive()`.

### 5.4 Tools in a full run

| Tool | Use |
|---|---|
| `mail_address()` | The agent's own address and its status. |
| `mail_list(folder?, unread_only?, limit?)` | Summaries. For `unknown` mail the snippet is empty. |
| `mail_read(id)` | `owner`/`trusted`: full text (max 8 000 characters). `unknown`: the HostView only. |
| `mail_send(to, subject, text, cc?, attachments?)` | `attachments` are workspace paths. `user_requested` is set by host code when the run came from the user's chat. The model cannot set it. |
| `mail_reply(id, text)` | Reply in the same thread. |
| `mail_archive(id)`, `mail_delete(id)` | Folder changes. |
| `mail_wait(from_contains?, subject_contains?, timeout_s?)` | Registers a wait on the server and polls it every 3 seconds. The server also matches mail from the last 120 seconds that no one has claimed. Returns the HostView or `timeout`. |

HostView (`GET /v1/agent-mail/messages/{id}?view=host` and wait results):
`owner`/`trusted` mail and the agent's own sent mail and drafts
(`sender_trust = "self"`) give the full `Message` with the text cut at 8 000
characters. `unknown` mail gives only `{id, from_address, subject,
sender_trust, codes: [..], links: [..], note}`. `codes` are digit groups of
4 to 8 digits and groups of 6 to 8 upper-case letters and digits. `links`
are up to 10 `https` URLs from the text, each at most 2 048 characters
(the host keeps them whole). `note` tells the agent that the
text is hidden because the sender is not trusted.

## 6. App (Flutter)

* Entry point: row "Mailbox" in the Agents settings group (phone and desktop
  settings), next to API keys.
* Mailbox page: the address with a copy action, filter
  `Inbox | Unknown | Drafts | Sent | Archive` (`ConnectedGroup`), the list.
* Mail page: sender, trust badge, date, agent note, text, attachments.
  Actions: archive, delete, trust sender, block sender. A draft can be edited
  and sent, or discarded.
* Contacts page: trusted and blocked addresses and domains.
* No subscription: an info card, no list.
* The app never renders mail HTML. It shows `text_body`.

## 7. Resend and DNS set-up (done by hand)

* Domain `chukagents.com` in Resend, region `eu-west-1`, sending and
  receiving on. Records set with "Auto configure" (Cloudflare).
* DMARC: `_dmarc` TXT `v=DMARC1; p=quarantine;`.
* Webhook to `https://api.chuk.chat/webhooks/resend` for `email.received`,
  `email.bounced`, `email.complained`, `email.delivered`, `email.failed`.
* Cloudflare Email Routing stays off for this domain. It would replace the
  MX records.

## 8. Release order

1. Apply the migration and make the `agent-mail` bucket.
2. Set the environment in Dokploy, push api_server, check `/v1/version`.
3. Make the Resend webhook, set `RESEND_WEBHOOK_SECRET`.
4. Update the host, then ship the app.

## 9. Open points

* End-to-end encryption of stored mail (seal to a user key). Mail arrives in
  plain text at every provider, so this protects only the database copy.
* More than one address per agent.
* HTML view in the app.
