# Cloud box: plan (2026-11-03, reversed 2026-11-21)

**Decision (owner, 2026-11-21): built, on Contabo.** The 2026-11-03 "not
built" decision is reversed. The cloud box is an optional add-on (CHAT-172):
pre-selected and "recommended" (size S) at checkout, can be unticked, booked
later, resized, cancelled monthly. Without it the user self-hosts with the
install command. Plans EUR 20 / 30 / 40 carry only model credit.

**Price = our Contabo monthly cost + 1 EUR, nothing more** (owner). Contabo
contracts are always monthly: a 24-month term would leave paid, useless boxes
when customers leave. Monthly-term prices, gross incl. 19 % VAT, no setup fee
(product pages, 2026-11-21):

| Size | Contabo | Our cost | Customer |
|---|---|---|---|
| S (recommended) | V153 Cloud VPS 4: 4 vCPU, 8 GB, 100 GB | 6.55 | 7.55 |
| M | V154 Cloud VPS 6: 6 vCPU, 12 GB, 200 GB | 8.93 | 9.93 |
| L | V155 Cloud VPS 8: 8 vCPU, 24 GB, 300 GB | 16.66 | 17.66 |
| XL | V156 Cloud VPS 12: 12 vCPU, 48 GB, 400 GB | 29.75 | 30.75 |

Margin after Stripe fees is about EUR 0.5-0.8 a month, so the box must be an
item on the plan's subscription, never a second subscription. Spare pool
boxes cost the full monthly price while idle: keep the pool small. Upgrade:
in place via Contabo `upgrade` (offerId), prorated. Downgrade: at period end,
move to a smaller box restored from the backup. A 24-month prepaid option
may come later. Plane epic: CHAT-161.

## Shape (2026-11-21)

- **Instant, zero clicks.** A pool of pre-installed, hardened, unpaired
  boxes long-polls `POST /v2/agents/cloud-box/claim` (header
  `Box <box_id>:<secret>`; the secret is written by cloud-init, the DB keeps
  only its hash). After payment the app sends a fresh pairing token to
  `POST /v2/agents/cloud-box`; the server takes a pool box atomically and
  hands the token to it once. The host pairs through the normal relay.
  Release (cancel, account deletion) = final backup, reinstall with a new
  secret, back to the pool. Pool target: 1-2 spare boxes (each costs
  EUR 6.55 a month idle).
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
- **Billing (owner, 2026-11-21: optional add-on).** The box is NOT in a
  plan. It is an add-on with its own price per size, pre-selected and
  "recommended" (`s`) in the checkout, can be unticked and booked later.
  Self-hosting with the install command needs no add-on. Sizes
  (`CLOUD_BOX_SIZES` in api_server): s = Cloud VPS 4 (4 vCPU/8 GB/100 GB),
  m = VPS 6 (6/12/200), l = VPS 8 (8/24/300), xl = VPS 12 (12/48/400).
  Price = Contabo MONTHLY-term cost + 1 EUR (contracts always 1 month):
  s 7.55, m 9.93, l 17.66, xl 30.75 EUR. The margin is about 0.5-0.8 EUR a
  month after Stripe fees, so the box is always a second ITEM on the plan's
  subscription, never its own subscription (one fixed Stripe fee). Upgrade:
  charged pro rata now, Contabo upgrades in place (reboot). Downgrade: from
  the next period; at the period end the data moves to a new smaller box
  (`api_server/ops/cloud_box/migrate.py`), no new pairing. Cancel: the box
  runs to the end of the paid period. Payment failed: 7 days grace, then
  stop; 30 days: release. Contabo monthly prices are checked weekly per
  size; a change mails the owner with the suggested new price, nothing
  changes by itself. Endpoints and Stripe choices: api_server `CLAUDE.md`,
  section "Cloud box add-on".
- **Contabo API.** Sub-user `api@chuk.dev` (role Techniker, no 2FA), values
  in `api_server/.env`, check with `api_server/scripts/contabo_check.py`.
  Trap: Cloudflare in front of the API answers plain Python HTTP with 403;
  use `curl_cffi` with `impersonate="chrome"`.

## Research (2026-11-03)

Research: `SPRITES_REFERENCE.md`, `CLOUD_BOX_PROVIDERS.md`,
`HOSTING_AGENT37.md`, `CLOUD_HOST.md`. Code facts below come from a read of
`agents/host` and `api_server/routers/cowork` on 2026-11-03.

## Principle: the box sleeps, the server holds the clock

**Obsolete for Contabo (2026-11-21):** a monthly VPS costs the same awake
or asleep, so the box runs 24/7 and host timers stay on the host.

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
