# Cloud box per user: provider survey (research 2026-11-03)

Question: which provider runs one isolated Linux box per user, 24/7, for at
most about EUR 3-5 per month (our cost)? The box runs the Python host daemon.
The daemon holds one outbound websocket and is idle most of the time. Some
times it runs Chromium and shell tools for some minutes.

Target box: about 2 vCPU burst, 2-4 GB RAM, 5-20 GB disk, Linux, root, Docker
if possible. The api_server must create and delete a box with one API call.
The account limit must be high or easy to raise. EU is strongly preferred.

Related docs: `HOSTING_AGENT37.md` (Agent37 details), `CLOUD_HOST.md`.
Raw notes and page snapshots: `_scratch/box24/` (local only, gitignored).

## How to read the table

- **Verified = yes**: we read the number on the provider's own live page on
  2026-11-03.
- **Verified = no**: the number comes from a third party, from an older doc,
  or from our own calculation on unverified rates. Do not use it for a
  contract decision.
- "24/7" = the box runs all month (730 h). Prices exclude VAT.
- USD and EUR are shown as the page shows them. We did not convert them.
- "Real use" = the provider bills only the CPU and RAM that the box uses.
  "Reserved" = the provider bills the full size all the time.
- For real-use providers we use this load: 0.3 GB and about 0.02 vCPU when
  idle, 1.5 GB and 1 vCPU when active, active about 5 % of the month on
  average (10-15 % at peak).

## Table: all providers

| Provider | Plan near 2 vCPU / 2-4 GB | Price 24/7 per box | Billing | API create (1 call) | Account limit | Docker inside | EU | Sleep / wake | Verified | Source |
|---|---|---|---|---|---|---|---|---|---|---|
| Agent37 default | 2 vCPU / 4 GB / 4 GB disk (gVisor) | $4.76 | Reserved per minute, overcommit | Yes | 10 / 50 / 200 instances by top-up, more by mail | No (gVisor) | **No**: `eu` runs only `vm` and `performance` (`503 no_capacity`) | Auto-sleep, disk-only cost | Yes | agent37.com/docs/llms-full.txt |
| Agent37 VM | 2 vCPU / 4 GB (2.5x compute) | about $11.36 | Reserved per minute | Yes | Same as above | Yes | Yes (France) | Auto-sleep; awake 2 h/day = about $1.26 | Yes (rates), price is calculated | same |
| Agent37 burstable | Not documented | "from $1/month" | Not documented | Yes, after enablement | Apply by a booked call | Not documented | Probably no (EU runs only vm/performance) | Not documented | Partly (only the one line) | same |
| Fly Machines | shared-cpu-2x 4 GB, `fra` | about $27 (known) | Reserved per second | Yes | Raisable | Yes (Firecracker VM, root) | Yes | Stop/start, rootfs $0.15/GB-month | Partly: `iad` shared-cpu-2x 2 GB = $13.39, extra RAM $6/GB, `fra` 1 GB = $7.73 | docs.fly.io/about/pricing |
| Fly Sprites | Real use | $5-16 (known) | Real use: $0.0385/CPU-h, $0.021875/GB-h | Yes | Not checked | Root VM | Yes | Yes | No (known from earlier work, not re-read) | fly.io/sprites |
| Northflank | nf-compute-200: 2 vCPU / 4 GB | $48 ($0.5/1 GB = $12) | Reserved per second | Yes | Pay-as-you-go: no hard caps | No (container) | Not shown on page | No | Yes | northflank.com/pricing |
| Koyeb | eco-large 2 vCPU / 4 GB; eco-medium 1 / 2 GB | $21.43; $10.71 (+ Pro plan $29/month) | Reserved per second | Yes | Pro: 100 services, 100 CPU concurrency | No (container) | Yes (Frankfurt) | Scale-to-zero | Yes | koyeb.com/docs/reference/instances, koyeb.com/pricing |
| Railway | Real use | Calculated: idle about $4.90 (0.3 GB + 10 GB volume), with 5 % active about $6.60 | Real use per second: about $20/vCPU-month, $10/GB-month, $0.15/GB-month volume; Pro plan $20 incl. $20 usage | Yes (GraphQL API) | Pro: 100 services per project, 42 replicas | No (container, no root VM) | Yes (Amsterdam) | Serverless sleep after 5-10 min without outbound packets. Our websocket keeps it awake | Rates yes, totals calculated | railway.com/pricing, docs.railway.com |
| Render | Starter 0.5 CPU / 512 MB; Standard 1 CPU / 2 GB | about $7; about $25 | Reserved | Yes | Not read | No | Yes (Frankfurt) | No | **No** (page content did not load) | render.com/pricing |
| Scaleway DEV1-S | 2 vCPU / 2 GB | EUR 6.55 + disk + optional IPv4 | Reserved per hour | Yes | Org quotas, raise by verification/ticket (page 403) | Yes (VM, root) | Yes (Paris, Amsterdam, Warsaw) | Stop = disk only | Yes (price); no (quota) | scaleway.com/en/pricing/virtual-instances/ |
| Scaleway DEV1-M | 3 vCPU / 4 GB | EUR 14.74 + disk | Reserved per hour | Yes | Same | Yes | Yes | Same | Yes | same |
| Scaleway STARDUST1-S | 1 vCPU / 1 GB | EUR 0.43 + disk + optional IPv4 | Reserved per hour | Yes | Low quota, often out of stock (not verified) | Yes | Yes | Same | Yes (price) | same |
| Scaleway Serverless Containers | 0.5 vCPU / 2 GB, min scale 1 | Calculated about EUR 21 | Provisioned resources while running: EUR 0.00001/vCPU-s, EUR 0.000002/GB-s | Yes | Namespace quotas | No | Yes | Scale-to-zero | Rates yes | scaleway.com/en/pricing/serverless/ |
| Scaleway Kapsule | Pods on DEV1/PLAY2 nodes | Node price / users per node | Nodes reserved | Yes (pods via K8s API) | Node quotas | Only with privileged pods | Yes | No | No | not read |
| OVHcloud d2-4 | 2 vCPU / 4 GB / 50 GB | $13.50 ($0.0244/h) | Reserved per hour | Yes | Project quotas, raise by quota upgrade | Yes | Yes (many EU) | No | Yes (world site in USD) | ovhcloud.com/en/public-cloud/prices/ |
| OVHcloud d2-2 | 1 vCPU / 2 GB / 25 GB | $6.74 | Reserved per hour | Yes | Same | Yes | Yes | No | Yes | same |
| UpCloud Starter | 2 vCPU / 2 GB / 30 GB; 2 vCPU / 4 GB | EUR 8; EUR 12 (1/1 GB = EUR 3, max 5 per customer) | Reserved per hour | Yes | Not stated | Yes | Yes (FI, DE, NL, ...) | No | Yes | upcloud.com/pricing/ |
| Vultr | 2 vCPU / 2 GB; 2 vCPU / 4 GB | $15; $20 (IPv6-only 0.5 GB = $2.50) | Reserved per hour | Yes | Raisable by ticket | Yes | Yes | No | Yes | vultr.com/pricing/ |
| DigitalOcean | Basic 2 vCPU / 2 GB; 2 / 4 GB | $18; $24 | Reserved per hour | Yes | Droplet limit, raisable | Yes | Yes (FRA, AMS) | No | Yes | digitalocean.com/pricing/droplets |
| Akamai / Linode | 2 vCPU / 4 GB | $24 (1/1 GB = $5) | Reserved per hour | Yes | Raisable | Yes | Yes | No | Yes | akamai.com/cloud/pricing/cpu |
| Contabo | Cloud VPS 4: 4 vCPU / 8 GB / 100 GB | EUR 6.55 month-to-month (EUR 4.40 on a 24-month term), incl. tax | Monthly term | Yes (API, CLI) | Not stated | Yes | Yes (DE) | No | Yes | contabo.com/en/vps/ |
| netcup | VPS 500 G12.5: 2 vCPU / 4 GB / 64 GB | EUR 8.26 on 12-month term | Contract term | Not confirmed for ordering | Not stated | Yes | Yes (DE, AT) | No | Yes (price) | netcup.com/en/server/vps |
| IONOS Cloud Cubes | Basic Cube S: 2 vCPU / 4 GB / 120 GB | $10.08 max per 30 days ($0.014/h) | Per minute, monthly cap | Yes (IONOS Cloud API) | Not stated | Yes | Yes | No | Yes (US page) | ionos.com/cloud/cloud-servers |
| Exoscale | Small 2 / 2 GB; Medium 2 / 4 GB | Not readable (price cells empty) | Per second, disk extra | Yes | Not read | Yes | Yes (CH, DE, AT, BG) | No | Specs yes, price no | exoscale.com/pricing/ |
| Hostinger | KVM 1: 1 vCPU / 4 GB; KVM 2: 2 / 8 GB | $6.49 / $8.79 on 24-month prepaid, renewal $11.99 / $14.99 | Prepaid term | Public API exists, VPS create not confirmed | Not stated | Yes | Yes (LT, NL, FR, DE; not verified) | No | Yes (price) | hostinger.com/vps-hosting |
| Oracle Cloud A1 | 1 OCPU (Arm core) / 4 GB | Calculated $11.68 (2 OCPU / 4 GB = $18.98) | Reserved per hour: $0.01/OCPU-h, $0.0015/GB-h | Yes | Low service limits, raise by request (not verified) | Yes | Yes (Frankfurt, ...) | No | Yes (rates) | oracle.com/cloud/price-list/ |
| Oracle Always Free | 2 OCPU / 12 GB total per tenancy | $0 | - | Yes | 1 tenancy = only a few boxes; idle boxes reclaimed after 7 days | Yes | Yes | No | Yes | docs.oracle.com Always Free Resources |
| Cloudflare Containers / Sandbox | basic: 1/4 vCPU / 1 GiB / 4 GB; standard-1: 1/2 vCPU / 4 GiB | Calculated: basic about $7.30; standard-1 about $28 (+ $5 Workers Paid) | Memory and disk provisioned while running, CPU on active use | Yes | 6 TiB memory, 1,500 vCPU per account, raisable | No | No EU pinning shown | Sleep after timeout | Rates yes | developers.cloudflare.com/containers/pricing/ |
| Modal Sandboxes | 0.125 core / 2 GiB | Calculated about $48 | Real use, sandbox rate is 3x list | Yes | Starter: 100 containers | No | Region pick costs 1.15-1.75x | Yes | Rates yes | modal.com/pricing |
| Blaxel | 2 GB sandbox | Calculated 24/7 about $60; awake 1 h/day about $2.50 + snapshot $0.80 | Active GB-s only ($0.0000115); standby = snapshot $0.20/GB-month | Yes | Tiers: 10 / 50 / 200 / ... / 100,000+ sandboxes by top-up | Not checked | Not listed | Yes, resume about 25 ms | Rates yes | blaxel.ai/pricing |
| Morph Cloud | 2 vCPU / 4 GB = 2 MCU | Calculated $73 | $0.05 per MCU-hour | Yes | Developer up to 64 vCPU, Team 256, Scale 1024 | Not checked | Not listed | Snapshots, very cheap to store | Yes (rate) | cloud.morph.so/web/pricing |
| Runloop | 2 vCPU / 4 GB devbox | Calculated about $231 | Real use; suspended = storage only | Yes | Trial: 3 devboxes | Not checked | Not listed | Suspend/resume | Yes (rates) | runloop.ai/pricing |
| CodeSandbox SDK | - | Not read (Cloudflare block, 403) | Credits per hour | Yes | Not read | Yes (VM) | Not read | Hibernate | No | codesandbox.io/pricing |
| Namespace | Devbox S: 4 vCPU / 8 GB | Calculated about $175 | Per minute | Yes | 3-50 devboxes per workspace, max run 3-24 h | - | Not listed | Idle timeout 15 min | Yes | namespace.so/pricing |
| Unikraft Cloud | - | Not published | - | Yes | - | No (unikernel) | Not shown | Scale-to-zero | No | unikraft.com/pricing/ |
| E2B, Daytona | - | Far too expensive 24/7 (known) | Real use | Yes | - | - | - | Yes | No (not re-read) | - |
| Hetzner Cloud CX23 | 2 vCPU / 4 GB / 40 GB (Cost-Optimized) | EUR 5.99 incl. IPv4 (EUR 0.0096/h) | Reserved per hour | Yes | Per-account limit, see below | Yes | Yes (NBG1, HEL1) | No | Yes. Page shows "currently unavailable" on every plan | hetzner.com/cloud/cost-optimized/ |
| Hetzner Cloud CAX11 | 2 vCPU Arm / 4 GB / 40 GB | EUR 6.49 | Reserved per hour | Yes | Same | Yes | Yes | No | Yes | same |
| Hetzner Cloud CPX22 | 2 vCPU AMD / 4 GB / 80 GB | EUR 19.99 | Reserved per hour | Yes | Same | Yes | Yes | No | Yes | hetzner.com/cloud/regular-performance/ |

### Hetzner Cloud limit

- Hetzner does not publish a fixed number. Each account has its own limit. You
  see it in the Console on the "Limits" tab.
- To raise it: `console.hetzner.com/limits` -> "Request change" ->
  "Limit increase". Staff check the request by hand.
- You can ask only after the account is one month old and the first invoice
  is paid (docs.hetzner.com/cloud/servers/faq/, verified).
- Third-party guides say 10-25 servers for new accounts. Not verified.

### Answer to question 1

No provider meets all conditions at the same time: 24/7, 2 vCPU, 2-4 GB, EU,
one API call, high limit, and EUR 3-5.

- **Fixed price, full spec, EU:** Hetzner CX23 (EUR 5.99) is the cheapest.
  Then CAX11 (EUR 6.49), Scaleway DEV1-S (EUR 6.55, only 2 GB), UpCloud
  (EUR 8 / 12). All are above EUR 5. Hetzner has the per-account limit.
- **Under EUR 5, but smaller box:** Scaleway STARDUST1-S (1 vCPU / 1 GB,
  EUR 0.43 + disk), UpCloud 1 GB (EUR 3, max 5 per customer), Vultr IPv6-only
  (0.5 GB, $2.50). These are too small for Chromium, and stock or limits are
  low.
- **Under EUR 5 only with sleep:** Agent37 `eu` VM, Blaxel, Cloudflare
  Containers, Fly Sprites. This needs the relay to wake the box when a frame
  arrives (see `HOSTING_AGENT37.md`).
- **Real use, 24/7, EU:** Railway (Amsterdam) costs about $5-7 for our load.
  This is the closest 24/7 match. But there is no root VM and no Docker.
- **Splitting a big VPS:** Contabo Cloud VPS 4 (4 vCPU / 8 GB, EUR 6.55)
  holds 2-3 users, so EUR 2-3 per user. But this is renting servers
  ourselves, on a monthly term.

## Question 2: run it ourselves on Hetzner dedicated servers

### Prices (verified on hetzner.com, 2026-11-03, excl. VAT)

| Server | CPU | RAM | Disk | EUR / month | Setup fee |
|---|---|---|---|---|---|
| AX41 | Ryzen 5 3600 (6C / 12T) | 64 GB DDR4 | 2x 512 GB NVMe | 59.00 | 0 |
| EX44 | Core i5-13500 (14C / 20T) | 64 GB DDR4 | 2x 512 GB NVMe | 59.00 | 0 |
| AX42 | Ryzen 7 PRO 8700GE (8C / 16T) | 64 GB DDR5 ECC | NVMe | 99.00 | 49 |
| EX63 | Core Ultra 7 265 (20C) | 64 GB DDR5 ECC | 2x 1 TB NVMe | 149.00 | 74 |
| AX102 | Ryzen 9 7950X3D (16C / 32T) | 128 GB DDR5 ECC | 2x 1.92 TB NVMe | 259.00 | 129 |
| EX131 | Xeon (32C) | 128 GB DDR5 ECC reg. | 2x 1.92 TB NVMe | 559.00 | 279 |
| AX162 | EPYC 9454P | 128 GB DDR5 ECC reg. | 2x 1.92 TB NVMe | 614.00 | 304 |

The 2026 RAM price rise is visible: AX102 was about EUR 104 before 2026 (from memory, not verified).
Server Auction boxes can be cheaper. We did not read the auction list.

Sources: hetzner.com/dedicated-rootserver/matrix-ax/ and matrix-ex/.

### Hetzner Object Storage (verified)

- Base price EUR 6.49 per month. It includes 1 TB storage and 1 TB egress.
- More storage: EUR 0.0087 per TB-hour (about EUR 6.47 per TB-month).
- More egress: EUR 1.00 per TB. Ingress, internal traffic and API calls are
  free.
- Source: hetzner.com/storage/object-storage/.

### Users per box

Assumptions:

- One Firecracker microVM (or gVisor sandbox) per user. Local NVMe holds the
  disks. A shared base image with copy-on-write (reflink or overlay) keeps the
  real disk use per user at about 3-5 GB.
- Idle user: 0.3 GB. Active user: 1.5 GB. Active share at peak: 15 %.
- Average RAM per user at peak: 0.85 x 0.3 + 0.15 x 1.5 = 0.48 GB.
  With 30 % safety margin: about 0.63 GB.
- Host reserve: 8 GB (64 GB box), 12 GB (128 GB box).
- CPU: an active user with Chromium wants 1-2 threads for some minutes.

Mode A, all boxes stay in RAM 24/7 (websocket always open):

| Server | RAM limit | CPU limit (15 % active) | Disk limit (about 4 GB per user, RAID 1) | Users per box |
|---|---|---|---|---|
| AX41 | (64-8) / 0.63 = 89 | 12 threads -> about 50 | 512 GB -> about 120 | about 50 |
| EX44 | 89 | 20 threads -> about 80-90 | about 120 | about 80 |
| AX102 | (128-12) / 0.63 = 184 | 32 threads -> about 170 | 1.92 TB -> about 450 | about 170 |

Mode B, idle boxes are snapshotted to NVMe and the relay wakes them: RAM holds
only active and recently used boxes. Then RAM is not the limit any more. Disk
and CPU set the limit. An AX102 can hold about 300-350 users, but then the
disk is nearly full (10 GB disk + 0.3 GB memory file per user). Cold users
must move to Object Storage.

### Cost per user (Mode A)

Add 25 % spare capacity, because we need at least one spare box for failover
and moves. Backups use the Object Storage base price.

| Server | Users | Server + share of storage | With 25 % spare | Per user / month |
|---|---|---|---|---|
| AX41 | 50 | EUR 59 + 6.49 | EUR 82 | about EUR 1.60 |
| EX44 | 80 | EUR 59 + 6.49 | EUR 82 | about EUR 1.00 |
| AX102 | 170 | EUR 259 + 5.40 setup over 24 months + 6.49 | EUR 339 | about EUR 2.00 |

In 2026 the 64 GB Intel EX44 is the best price per user. The 128 GB boxes
cost more per GB of RAM than two 64 GB boxes. In Mode B the cost per user
falls to about EUR 0.50-1.00.

Not included: our work time for the scheduler, placement, backups, abuse
control, monitoring and on-call. This is the real cost of this option.

### Firecracker snapshot and restore latency

| Case | Figure | Source | Verified |
|---|---|---|---|
| Cold boot to guest init | 125 ms or less | Firecracker SPECIFICATION.md | Yes |
| VMM memory overhead | 5 MiB or less per microVM | same | Yes |
| Restore from local NVMe (mmap of memory file) | `snapshot/load` 25 ms, full restore to SSH ready 176 ms (256 MiB, 2 vCPU) | numavm.com/blog/2026-03-10-1-second-boot/ | Yes (vendor blog, own test) |
| Restore from S3 (Ceph RGW, about 2 Gbit/s), 3.5 GiB set (3 GiB rootfs + 512 MiB memory) | same node 1.86 s, other node 3.79 s (chunked, zero-elided); old full copy 24-25 s | github.com/opensandbox-group/fast-sandbox/issues/146 | Yes (project issue) |
| Lazy memory from object storage (UFFD, range requests) | restore step about 49 ms, cross-host fork 1.2-3.5 s | pandastack.ai blog | No (vendor claim, no method) |
| Blaxel resume from standby | about 25 ms | blaxel.ai/pricing | Yes (vendor claim) |

Rules from the Firecracker docs (snapshot-support.md, verified):

- Restore maps the memory file with `MAP_PRIVATE`. Pages load on demand. The
  memory file must stay on disk for the life of the VM. So keep it on local
  NVMe, not on S3.
- Network connections are not kept after resume. The host daemon must
  reconnect its websocket after a restore.
- The guest clock continues from the snapshot time. Sync the clock after a
  restore.
- Do not restore one snapshot more than one time at the same moment. Random
  state and tokens repeat in each clone.

## Recommendation (ranked)

1. **Agent37 `eu` VM with auto-sleep and relay wake.** About $1.30-3.50 per
   user per month (awake 2-6 h per day; 24/7 would be $11.36). EU (France),
   root, Docker, one API call, 200 instances after $250 top-up, more by mail.
   Also ask Agent37 to enable `burstable` in `eu` ("from $1/month"). Risks:
   US control plane and backups, small vendor, the relay must wake the box.
2. **Railway, EU West (Amsterdam), 24/7 real-use billing.** About $5-7 per
   user per month for our load. No sleep logic is necessary, the websocket
   stays open. API create, 100 services per project and many projects. Risks:
   no root VM and no Docker inside, so the sandbox must run without Docker
   (`LocalEnvironment`). Cost grows with active minutes.
3. **Hetzner Cloud CX23, 24/7 fixed price.** EUR 5.99 per user per month,
   full spec (2 vCPU / 4 GB / 40 GB), root, Docker, EU. Risks: per-account
   limit (raise after one month and one paid invoice), and the page showed
   "currently unavailable" on 2026-11-03.

Baseline: our own Hetzner EX44 boxes with Firecracker cost about EUR 1.00 per
user per month (Mode A) or EUR 0.50-1.00 (Mode B), plus our ops work. Move to
this option when the user count makes the ops work worth it. Keep the
provisioning behind one `HostProvisioner` interface, so that a move is a
config change.
