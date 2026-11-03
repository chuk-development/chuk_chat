# Cloud computer per user (research 2026-11-03)

Goal (owner): a paid add-on (EUR 5-10/month) that gives each user a cloud
computer for the Agents host. The app (through api_server) creates it with one
API call. We rent no servers and hit no per-account server limit. Encrypted
backups go to S3.

## Pick: Fly.io Sprites

Source: `https://fly.io/pricing.md`, `https://fly.io/sprites`,
`https://docs.fly.io/sprites/working-with-sprites` (read 2026-11-03).

- Create: `PUT https://api.sprites.dev/v1/sprites/{name}` (bearer token).
  Run commands: `POST .../exec`. SDKs: JS `@fly/sprites`, Python `sprites-py`.
- Billing is on **actual use**: CPU from `cpu.stat` at $0.0385/CPU-hour,
  memory at actual usage at $0.021875/GB-hour. Hot storage $0.50/GB-month
  while awake, cold storage $0.02/GB-month always. No per-Sprite fee.
  Bandwidth not metered (fly.io/sprites).
- Disk: 100 GB volume per Sprite, pay what is used. Checkpoints built in
  (copy-on-write, `sprite checkpoint create`).
- Sleep: no activity means sleep. Wake on a request to the Sprite URL in
  about 100-500 ms, cold wake 1-2 s.
- Limits: cold Sprites unlimited. Running/warm Sprites have a per-org ceiling
  (fly.io/sprites names 100 on one plan; pricing.md says no plans). Ask Fly
  before launch.

### Cost per user (estimate)

| Usage | Month |
|---|---|
| Asleep all month, 5 GB data | about $0.10 |
| Awake 2 h/day, 1.5 GB real RAM, 0.3 CPU average | about $3 |
| Awake 8 h/day, same load | about $11 |

Cap heavy users (awake hours or a spend cap) or the EUR 5-10 add-on loses
money.

### What we must change

1. **The relay socket keeps a Sprite awake.** An open TCP connection counts
   as activity. Held 24/7, the host bills memory 24/7 (0.3 GB = about
   $5/month). Fix: the host closes the relay socket after N minutes idle.
   api_server wakes the Sprite with an HTTP request to its URL when a frame
   arrives for an offline host, holds the frame, and the host reconnects.
   The same path wakes it for scheduled tasks.
2. **No Docker inside a Sprite** (not documented). Run the host with
   `LocalEnvironment`; the Sprite is the sandbox. Chromium runs directly on
   the Sprite (Ubuntu 25.10 image).
3. **No region choice.** A Sprite is created near the caller. Call the API
   from the api_server (EU), then check where it landed.
4. **Backups:** restic or kopia inside the Sprite to S3 (Hetzner Object
   Storage or Tigris). Client-side encryption, key derived per user and kept
   by us or by the user. Fly checkpoints are extra, not the backup.

## Rejected

| Provider | Why not |
|---|---|
| Fly Machines | Reserved billing. fra shared-cpu-2x 4 GB about $27/month at 24/7. Works only with stop/suspend; Sprites do this for us. |
| E2B | Pro plan $150/month plus usage, 24 h session cap on Pro. |
| Daytona | About $0.083/h for 1 vCPU/2 GB, about $60/month at 24/7. |
| Agent37 | See `HOSTING_AGENT37.md`. EU only as VM type, US control plane. Fallback option. |
| Hetzner, Scaleway, OVH VPS | Rented servers, account server limits. |
