# Hosted Agents host: Agent37 vs. own Hetzner (research 2026-11-03)

Question: can we run one Agents host per user in the cloud (like Grok Bot /
OpenAI Dots), instead of on the user's own machine? Source: the Agent37 docs
dump `https://www.agent37.com/docs/llms-full.txt` (read 2026-11-03).

## Agent37 pricing (how it works)

- Prepaid wallet, no plan fee. Metered per minute. Rate = monthly price / 730 h.
- Rates (default instance): vCPU $0.80/month, RAM $0.70/GB/month,
  disk $0.09/GB/month. 2 vCPU / 4 GB / 4 GB disk = **$4.76/month at 24/7**.
- Sleeping or stopped: disk only ($0.36/month at 4 GB). Cold storage:
  $0.03/GB/month on compressed bytes.
- Shapes: 2/4, 4/8, 4/16, 4/32 (vCPU/GB). 4 vCPU is the ceiling. Disk max per
  shape: 12, 20, 40, 80 GB.
- `type: "vm"` (own kernel, Docker inside) = 2.5x compute.
  `type: "performance"` (dedicated cores) = 4x compute.
- Default instances are gVisor containers on shared hardware. Sustained heavy
  CPU is throttled when the host is busy. This overcommit is why it is cheap.
- Instance caps: 10 after first top-up, 50 at $100 total top-ups, 200 at $250.
- Regions: `us`, `eu` (France), `ap-south`. **`eu` runs only `vm` and
  `performance`.** Backups and the control-plane record stay in the US.

## Cost per user (EU, VM type, 2 vCPU / 4 GB / 4 GB disk)

- 24/7: about $11.36/month.
- Auto-sleep, awake 2 h/day: about $1.26/month.
- Compare: LLM tokens per active user are about EUR 13/month
  (`docs/COWORK_PRICING_PLAN.md`). Compute is not the main cost.

## Problems for our host

1. **Sleep vs. relay.** Auto-sleep counts only bytes through the instance's
   own URLs. Our host holds an outbound socket to
   `wss://api.chuk.chat/v2/relay/ws`; that is not activity. The instance sleeps
   after `idle_timeout_seconds` (default 900) and the relay socket dies.
   Fix: the api_server relay wakes the instance (`POST /v1/instances/{id}/start`
   or a request to its URL) when a frame arrives for an offline host, and
   queues the frame. The host must reconnect after a checkpoint restore.
2. **Docker boxes.** `agents/sandbox` uses `DockerEnvironment` (docker/podman).
   That needs `type: "vm"`. Alternative: run `LocalEnvironment` and let the
   Agent37 instance be the isolation.
3. **Browser box.** Chrome plus the agent in 4 GB is tight. Agent37 itself
   says computer use wants Performance (4x).
4. **Scheduled tasks** do not fire while asleep. Use their cron API or let our
   server wake the instance.
5. **Privacy claim.** US control plane and US backups conflict with
   "Private and Secure". Instance env is readable by the agent: no shared keys
   in env.
6. **Vendor risk.** Small startup, prices can change, 200-instance cap needs a
   mail. Keep provisioning behind one interface so we can move.

## Own Hetzner variant

- Dedicated server, many users per box (gVisor or Firecracker per user).
  Most agents idle, so overcommit works the same as at Agent37.
- User disks stay on local NVMe. Incremental, encrypted backup (restic/kopia)
  to Hetzner Object Storage (S3). Move a disk to S3 only after long
  inactivity, restore on wake. Do not run disks from S3: a wake would have to
  download the whole disk.
- Same wake path: the relay is the central point that knows a message waits.
- More ops work (scheduler, placement, backups, abuse), but EU-only and
  cheaper per user at scale.

## Recommendation

Start on Agent37 (`eu`, `vm`, auto-sleep, relay-driven wake) behind a
`HostProvisioner` interface. Move to own Hetzner boxes when the user count
makes the ops work pay, or when the US control plane becomes a sales problem.
