# Cloud box: plan (2026-11-03, reversed 2026-11-21)

**Decision (owner, 2026-11-21): built, on Contabo.** The 2026-11-03 "not
built" decision is reversed. Every paying Agents user gets one Contabo
Cloud VPS 4 (4 vCPU, 8 GB, 100 GB; EUR 4.40 net on a 24-month term, about
EUR 6.55 gross monthly). Plans EUR 20 / 30 / 40 include the box; higher plans
add model credit. Self-hosting with the install command stays. Plane epic:
CHAT-161 (children CHAT-162 to CHAT-167).

## Shape (2026-11-21)

- **Instant, zero clicks.** A pool of pre-installed, hardened, unpaired
  boxes long-polls `POST /v2/agents/cloud-box/claim` (header
  `Box <box_id>:<secret>`; the secret is written by cloud-init, the DB keeps
  only its hash). After payment the app sends a fresh pairing token to
  `POST /v2/agents/cloud-box`; the server takes a pool box atomically and
  hands the token to it once. The host pairs through the normal relay.
  Release (cancel, account deletion) = final backup, reinstall with a new
  secret, back to the pool. Pool target: 2 spare boxes.
- **Access.** No SSH for the customer; only the agent runs there (user
  `agent`, no root). Packages through the root helper `pkg-install` (official
  Ubuntu package names only; `sudo apt` would be root). Admin user `ops`, SSH
  key only, port 22 only from dps (Contabo firewall + nftables).
- **Abuse = money risk.** One abusive customer can get the whole Contabo
  account suspended. nftables blocks SMTP, torrent, SMB for `agent` and
  rate-limits new outbound connections. A Contabo abuse report stops the box
  of that IP at once.
- **Updates.** `unattended-upgrades` daily, reboot 04:00 local. Emergency:
  `ops/cloud_box/fleet_patch.py` in waves (5 % canary, then batches; stop on
  failure).
- **Backups.** dps pulls every box with restic into one shared, deduplicated,
  compressed repo on the Hetzner Storage Box. Boxes hold no backup
  credentials, so no customer can read another one's data. Final backup of a
  deleted account: 90 days (GDPR Art. 17), not forever.
- **Billing.** Box only with an active, paid Stripe subscription whose price
  id is in `CLOUD_BOX_PRICE_IDS`. Payment failed: 7 days grace, then stop;
  30 days: release. Contabo price page checked weekly; a change mails users
  30 days ahead (terms must allow passing on provider prices).
- **Contabo API.** Sub-user `api@chuk.dev` (role Techniker, no 2FA), values
  in `api_server/.env`, check with `api_server/scripts/contabo_check.py`.
  Trap: Cloudflare in front of the API answers plain Python HTTP with 403;
  use `curl_cffi` with `impersonate="chrome"`.

## Research (2026-11-03)

Research: `SPRITES_REFERENCE.md`, `CLOUD_BOX_PROVIDERS.md`,
`HOSTING_AGENT37.md`, `CLOUD_HOST.md`. Code facts below come from a read of
`agents/host` and `api_server/routers/cowork` on 2026-11-03.

## Principle: the box sleeps, the server holds the clock

The box runs only while it has work. The server knows when work comes:

| Work | Today | Cloud box |
|---|---|---|
| Message from the phone | Relay drops it with `executor_offline` (`cowork_relay.py:460-514`) | Relay queues the frame, wakes the box, delivers on reconnect |
| Cron / interval automation | Host thread, tick 15 s (`automations.py:794`) | Schedule copy on api_server; server wakes the box at due time |
| URL watch | Host thread, each page every 15 min (`url_watch.py`) | Server fetches the page; wakes the box only on change |
| Agent mail | Host polls every 300 s (`agent_mail.py:93`) | Server wakes the box when mail arrives |
| Long job ("tell me when done") | Runs on host | Box stays awake while the run is active (real work, real cost), then sleeps |
| Notification at run end | Host writes Supabase + FCM (`notify.py`) | Same; the box is awake at that moment |

A watcher that waits on an outside event never holds the box awake. It moves
to the server or to a timed wake.

## Work packages (beads under epic `chuk_chat-vbgv`)

1. **BoxProvider interface** (api_server): `create`, `wake`, `stop`,
   `delete`, `status`, `usage`. Backends: `fake` (tests), then the chosen
   provider. All code above it is provider-neutral.
2. **Relay store-and-forward + wake** (api_server): queue per
   `user_id/device_id` for cloud boxes, TTL, size cap, `wake()` on a frame for
   an offline cloud host, flush on auth. Phone sees "waking" not "offline".
3. **Host cloud mode** (agents/host, `AGENTS_CLOUD_BOX=1`): no host-side
   timers; idle detector (no run, no controller, no pending call for N
   minutes) closes the relay socket and tells api_server "idle"; api_server
   then stops the box. Keep-awake while a run is active.
4. **Server scheduler** (api_server): automation schedules and URL watches
   mirrored to the server; due item = wake + trigger frame.
5. **Provisioning and pairing** (api_server + app): `POST /v2/agents/cloud-box`
   creates the box with a one-time install token in its env. The app claims
   the pairing channel itself, so the end-to-end trust stays app-to-host and
   the server sees no key. No code for the user to type.
6. **Encrypted backup** (box + app): restic/kopia from the box to S3 every
   N hours and before stop. The repo key is wrapped with the account
   encryption key and mirrored like the pairing record
   (`agents_pairing_restore.dart`). A new box restores from it. Scope:
   `$AGENTS_HOME` (`paired.json`, `host_device.key`, `account.json`,
   `secrets.enc`, all `*.db` with WAL files, `agents/`, `hindsight/`).
7. **Billing** (api_server): monthly box fee from credits plus awake hours
   above the included amount, read from the provider usage API.
8. **App UI**: "Cloud computer" on/off, size, state (asleep / waking /
   running), last backup.

## Provider decision (open, owner)

- **Fly Sprites** has two blockers: the terms allow "internal use" only and
  let Fly suspend the whole org for one abusive user; the usage API reports
  reserved memory (2 GB floor), so cost may be well above the price list.
- **Agent37** is built for one instance per end user. EU only as VM type.
  About $1.30-3.50 per user with sleep.
- **Own Hetzner dedicated + Firecracker**: EX44/AX41 64 GB at EUR 59/month,
  about 80 users per server, about EUR 0.50-1.00 per user with snapshot
  sleep. Restore 25 ms from local NVMe, about 2-4 s from S3. EU, no reseller
  risk, more ops work.

Packages 2-8 are the same for every provider.
