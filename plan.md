# plan.md — Improvements for `start-scratch.sh` & the Private-Cloud Bootstrap

Concrete, prioritized improvements found while documenting the stack
(see `architecture.md`). Grouped by severity. Each item notes **why** it matters and
**what** to change.

> ⚠️ **OPEN (2026-06-16): minikube is Stopped — platform down.** Restart it here, then
> re-push the registry, then finish the yolo reconcile Vault-durability task. Full pickup
> steps: [`HANDOFF-2026-06-16-cluster-down.md`](HANDOFF-2026-06-16-cluster-down.md).
> Permanent registry fix that prevents the recurring wipe = **R8** below.

---

## P0 — Security (do these first)

### 1. Live secrets are hard-coded in the script and committed to git
`start-scratch.sh` / `restart-minikube.sh` contain in cleartext:
- Jenkins basic-auth + API token: `private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com`
- Splunk HEC token: `25577715-5282-4f8b-ab9c-c8aa95a75bea`
- Vault userpass password `r00tT0k£n` (in `vault/start-vault.sh`)

Re **`cluster-keys.json`:** the vault repo's Phase 1 (2026-06) already moved it OUT of the
repo to **`~/.vault/cluster-keys.json`** (0600); `start-vault.sh` writes there via
`$VAULT_KEYS_FILE`, so it is no longer in any repo dir. The vault repo also tightened
per-app policies to least privilege and provisions scoped Jenkins AppRoles instead of
handing out root — see vault `plan.md`. **Still outstanding here in STEP0:** the Jenkins
basic-auth/API token, the Splunk HEC token, and the Vault userpass password (line 15).

> **Partial progress 2026-06-30 (Jenkins token).** The token was **externalized** out of the
> hot path: `trigger-app-builds.sh` and `start-scratch.sh`'s vault→Jenkins credential sync now
> read it from the gitignored `STEP0/.env` (`JENKINS_CRED`), which `backup-minikube-mnt.sh`
> captures and `restore-scratch.sh` restores. **But the token value is NOT yet rotated**, and it
> still sits in cleartext at: `restart-minikube.sh:123` (a **live, uncommented** warm-restart curl),
> commented examples (`start-scratch.sh:153`, `restart-minikube.sh:124`), the restore plan doc
> (`docs/superpowers/plans/2026-06-30-restore-scratch.md`, 6×, reproduced as before/after reference),
> and **git history**. Externalization alone does not undo any of those — **rotation is the fix.**

**Fix — rotate the Jenkins token. ✅ DONE 2026-06-30.** The old token (user `private-cloud`, name
`build`, uuid `0a2b57cb…`, value `117c6b…`) was **revoked** — it now returns **HTTP 401**. The
replacement (name `step0-rotated-2026-06-30`, uuid `e44eced5…`) lives **only** in the gitignored
`STEP0/.env`. Rotation was done via the Jenkins REST API (generate → verify new → update `.env` →
verify → revoke old → verify old dead). Because the old value no longer authenticates, **every
cleartext copy of it (git history included) is now inert.**
1. ✅ Generated a new API token and revoked `build` (verified: old → 401, new → authenticated).
2. ✅ `STEP0/.env` updated to the new `JENKINS_CRED` (gitignored; both scripts source it; verified
   end-to-end via `whoAmI` through the exact `.env` read path).
3. ✅ Externalized the last live inline use (`restart-minikube.sh:123`, commit 4d05f12).
4. ⏳ *Optional* cosmetic cleanup of the now-INERT cleartext copies (harmless — they can't auth):
   the commented `delete_mem_leak_java` line `start-scratch.sh:153`, the literal tokens in
   `docs/superpowers/plans/2026-06-30-restore-scratch.md` (6×, before/after reference), and `plan.md:18`.
5. ✅ History rewrite **not needed** — a revoked token can't authenticate, so leaving it in history is harmless.

> **Note:** the off-site backup's captured `.env` still holds the old (now-dead) token until the next
> weekly backup runs; a restore from an older archive would need `JENKINS_CRED` re-set to the current
> value. The `?token=<job>` per-job *build-trigger* tokens are unrelated and were not changed.

**Fix — Splunk HEC token + Vault userpass password (same pattern):**
- Move them to the untracked `STEP0/.env` (or a dedicated `secrets.env`) and `source`/grep them in.
- **Rotate both** — consider them compromised.
- Add `.gitignore` rules for `secrets.env` and any `*-env-variables.sh` that land here (`.env` is
  already ignored).
- Going-forward, app secrets flow through the vault repo's declarative manifests +
  `vault-sync.sh` + the `vault-secrets-sync` Jenkins pipeline (AppRole auth), not the
  inline `*-env-variables.sh` seeding.

### 2. Vault uses 1 key share / threshold 1
Single unseal key = single point of compromise and no recovery quorum. For a personal
cloud this is a deliberate tradeoff, but at minimum keep the key offline (see #1). Consider
auto-unseal (transit/cloud KMS) so the key never sits in a file on the host.

---

## P1 — Reliability & idempotency

### 3. Replace fixed `sleep` waits with readiness checks
The script blocks on `sleep 1m` (yolo) and `sleep 3m` (splunk x2) — ~7 minutes of guessing.
If a pod is slow, the next step still fires; if it's fast, time is wasted. With `set -e`,
a not-yet-ready dependency causes a hard abort.

**Fix:** use real gates, e.g.
```bash
kubectl rollout status deploy/vault -n vault --timeout=180s
kubectl wait --for=condition=Ready pod -l app=qcguy -n qcguy --timeout=180s
```
before triggering dependent Jenkins builds / Splunk setup.

### 4. `kubectl version` is the wrong "is the cluster up?" probe
Both scripts gate `minikube start` on `if kubectl version`. `kubectl version` can succeed
against a stale kubeconfig or hang when the API is down. Use the purpose-built probe:
```bash
if minikube status --format '{{.Host}}' | grep -q Running; then ...
```

### 5. `vault operator init` is not re-run safe — ✅ RESOLVED (vault repo, 2026-06)
`vault/start-vault.sh` now guards init/unseal on `vault status` (initialized/sealed) and
the auth/secrets enables on `auth|secrets list`, so it is fully re-run safe. (It was worse
than "errors out": the unconditional `init -format=json > $KEYS_FILE` truncated the keys
file, wiping the root token + unseal key.) Verified end-to-end on a warm cluster: keys
file byte-identical before/after, secrets/policies/roles/AppRoles preserved.
`restart-vault.sh` was also de-drifted to just tear down + delegate to `start-vault.sh`,
so there is now one bootstrap path, not two divergent ones (closes #9's vault portion).

### 6. Network subnet is inconsistent between the two scripts
- `start-scratch.sh`: `--subnet=172.16.0.0/16` ✅ (matches gateway `172.16.238.1`)
- `restart-minikube.sh`: `--subnet=172.16.238.0/16` ❌ (malformed — host bits set on a /16)

If the network ever gets (re)created by `restart-minikube.sh`, addressing may differ from
the fixed `172.16.238.2/.10` the rest of the system assumes. Make both use
`--subnet=172.16.0.0/16`.

### 7. Path-casing fragility (two `Ideaprojects` directories)
`start-scratch.sh` mixes `$HOME/Ideaprojects/...` (lowercase) and
`$HOME/IdeaProjects/splunk-hsbc-demo/...` (capital P). It only works because **both**
directories exist on the host. This is a latent foot-gun: a single backup/restore or a
new machine will collapse them and silently break Splunk (or worse, deploy stale code).

**Fix:** pick one canonical root, define `PROJECTS="$HOME/Ideaprojects"` once at the top,
use `"$PROJECTS/..."` everywhere, and `mv` / symlink the splunk dir into it.

### 8. No `set -u` / `set -o pipefail`, no error trap
Only `set -e` is on. An unset var (`$HOME` mis-expansion, missing `PROJECTS`) expands to
empty and silently `cd /` or builds wrong paths. Add:
```bash
set -euo pipefail
trap 'echo "FAILED at line $LINENO: $BASH_COMMAND" >&2' ERR
```

---

## P2 — Maintainability & operability

### 9. Collapse `start-scratch.sh` and `restart-minikube.sh` into one parameterized script
They are ~80% duplicated and have already drifted (subnet #6, GPU addon enabled in one
but not the other, monitoring/qcguy/splunk commented out in restart). Maintaining two
copies guarantees they keep diverging. Use one script with flags/functions:
```bash
./bootstrap.sh --cold        # full rebuild
./bootstrap.sh --warm        # reuse cluster, idempotent vault, skip app re-apply
./bootstrap.sh --with-splunk # opt-in heavy demo
```
Make each service a function (`setup_network`, `setup_minikube`, `deploy_vault`, ...) so
steps are independently runnable and testable.

### 10. Add a logging + timing wrapper
There's no record of what ran or how long it took. Wrap with `exec > >(tee -a
~/private-cloud-bootstrap.log) 2>&1` and a per-section `echo "=== <step> $(date) ==="`
so failures are diagnosable after the fact.

### 11. End-of-run health verification
The script ends by firing Jenkins builds and exits — it never confirms the cloud is
actually healthy. Add a final summary:
```bash
kubectl get po -A | grep -vE 'Running|Completed' && echo "⚠ unhealthy pods" || echo "✓ all pods healthy"
```
plus a quick `curl -so /dev/null -w '%{http_code}' https://qcguy.com` smoke test per public domain.

### 12. Resource sizing on a 48 GB / 12900K / 3080 Ti host
Minikube takes `--memory 32768` (32 GB) + `--cpus 12`, leaving ~16 GB and 12 threads for
host + Nginx + Docker + Ollama. With GPU LLM inference (`quantos`/qwen2.5:7b — see note) this is tight
under load. Worth either: (a) trimming Minikube to 28 GB and reserving headroom, or
(b) setting K8s resource requests/limits per app so the GPU/RAM-hungry Ollama pod can't
starve qcguy/yolo. Also confirm `--cpus 12` is intentional given 8P+8E cores (P-cores
matter most for latency-sensitive services).

> **Superseded / expanded by the dedicated [Cluster resource efficiency](#cluster-resource-efficiency-detailed-plan)
> section at the end of this file**, which is based on live measurements of the running cluster
> (2026-06-14). The `start-scratch.sh` `minikube start` line has already been patched per that section.

### 13. Two registry mechanisms coexist
The Minikube `registry` addon (`172.16.238.2:5000`) and the NPM-fronted
`container-registry.traderyolo.com` both point at :5000. Document which is canonical for
`docker push`, and drop the unused path to avoid "pushed to the wrong registry" confusion.

### 14. Splunk block is heavy, optional, and HSBC-specific
~6 minutes of sleeps + SCK Helm install for a demo that `restart-minikube.sh` already
disables. Gate it behind `--with-splunk` (see #9) so the default cold boot is faster and
doesn't drag in HSBC-specific config.

### 15. Pin versions for reproducibility
`minikube start` pulls "latest" K8s; `minikube-delete-and-upgrade.sh` curls the latest
Minikube binary. A future upgrade can break the whole cold-boot with no warning. Pin
`--kubernetes-version=vX.Y.Z` and record the tested Minikube/addon versions in `architecture.md`.

---

## Suggested order of execution

1. **P0 #1, #2** — rotate + remove secrets (urgent, independent of everything else).
2. **P1 #6, #7, #8** — quick correctness fixes (subnet, paths, strict mode).
3. **P1 #3, #4, #5** — readiness gates + idempotency (biggest reliability win).
4. **P2 #9** — unify the two scripts (prevents future drift; do after #3–#5 so the
   functions you extract are already correct).
5. **P2 #10–#15** — operability polish.

---

## Cluster resource efficiency (detailed plan)

> Based on live measurements of the running cluster on **2026-06-14**. Goal: every project
> (qcguy ~100 visitors/day, predictonomy ~100/day, bestrentaladmin ~5/day, plus Ollama shared
> by predictonomy + traderyolo) stays responsive **while** IntelliJ + Chrome run on the same host.
> Steady-state load is trivial; this plan targets the **concurrent-spike** case (a Jenkins build +
> Ollama inference + browsing at once), which is the only time the box is felt to struggle.

### Measured baseline (2026-06-14)

| Layer | Configured | Reality on the box |
|-------|-----------|--------------------|
| Host | — | i9-12900K (24 threads), **46 GB RAM, NO swap (0 B)**, RTX 3080 Ti (12 GB VRAM) |
| Disks | — | `/` (sda5) 44 G (27 G free) · `/var` 92 G (67% used, holds minikube/docker) · `/mnt/minikube-backups` 432 G |
| `start-scratch.sh` flags | `--cpus 12 --memory 32768 --disk-size 40g` | — |
| Docker cgroup on `minikube` container | — | hard cap **12 CPU / 32 GB** (MemSwap 64 G but host has no swap → effectively 32 G hard) |
| What kubelet reports to the scheduler | — | **24 CPU / 49 GB / ~92 GB ephemeral** — i.e. the *whole host* |
| Actual cluster usage | — | ~1.6 cores, **11.8 GB** RAM. GPU: sole claimant = Ollama; apps' served model `quantos:latest` (qwen2.5:7b) ≈ 5 GB VRAM. (Standalone `deepseek-r1:32b` Modelfile ≈ 20 GB, not the served model.) |

### The core problem — scheduler over-commit (correctness, not capacity)
With the **docker driver**, the kubelet advertises node capacity = full host (24 CPU / 49 GB),
but Docker enforces a **32 GB cgroup cap the scheduler never sees**. So Kubernetes will happily
admit pods totalling far more than 32 GB. When real usage crosses 32 GB, the **host kernel
OOM-kills inside the cgroup** — and with **no swap cushion** that manifests as abrupt pod (or whole
node) death mid-request. Daily load is tiny so it rarely fires, but it is exactly what bites during
a concurrent spike.

Secondary waste: **Prometheus ×2 + Alertmanager ×3 (HA replicas) on a single node** (~1 GB RAM for
zero availability benefit) and **Jenkins idling at ~1.9 GB** when no build is running.

### Actions (ordered: highest-leverage / lowest-risk first)

**R1. Add swap — biggest safety win, do first.** Zero swap on a memory-tight box means every
pressure event is an instant OOM. Add 16 GB zram (compressed in RAM, uses spare CPU, no disk wear):
```bash
sudo apt install zram-tools
echo -e "ALGO=zstd\nPERCENT=35" | sudo tee /etc/default/zramswap   # ~16G of 46G
sudo systemctl restart zramswap
```

**R2. Make the scheduler honest (already applied to `start-scratch.sh`).** The new `minikube start`
line adds kubelet reservations + eviction so the kubelet caps/evicts *before* the host kills the
cgroup, and raises CPU burst headroom to 16 (CPU is compressible — it throttles, never OOM-kills —
so this is safe while still leaving ~8 threads for IntelliJ/Chrome):
```
--cpus 16 --memory 32768
--extra-config=kubelet.system-reserved=cpu=1,memory=2Gi
--extra-config=kubelet.kube-reserved=cpu=1,memory=2Gi
--extra-config=kubelet.eviction-hard="memory.available<1Gi,nodefs.available<10%"
```
Requires a cluster restart (`restart-minikube.sh` / cold boot) to take effect.

**R3. Cut single-node HA waste (~1 GB, instant) — in the kube-prometheus manifests:**
- `prometheus-prometheus.yaml`: `replicas: 2 → 1`, set `retention: 7d`
- `alertmanager-alertmanager.yaml`: `replicas: 3 → 1`

**R4. Idle-down Jenkins (~1.5 GB when not building).** It's only needed at build time. Either set
JVM `-Xmx1g` + a 1.5 Gi limit, or scale the deployment to 0 between builds and let the build trigger
scale it up.

**R5. Keep the single shared Ollama as the only GPU claimant (already correct — keep it that way).**
One Ollama pod requests `nvidia.com/gpu: 1`; predictonomy + traderyolo consume it via its API, not
the GPU directly. `nvidia.com/gpu` is whole-GPU-only and the 3080 Ti has just 12 GB VRAM
(the served `quantos`/qwen2.5:7b model ≈ 5 GB; the standalone `deepseek-r1:32b` Modelfile ≈ 20 GB
would partial-offload to RAM) — **no other pod may request the GPU** or it will be unschedulable. If a
second GPU workload ever appears, use the device-plugin time-slicing config rather than a second claim.

**R6. Right-size requests/limits** so the scheduler packs by *request* and bursts to *limit*
(target: sum of requests well under 24 GB; limits may over-subscribe to ~30 GB, now safely backed by
R1+R2). Values derived from observed usage:

| Workload | Replicas | Request (mem / cpu) | Limit (mem / cpu) | Observed | Note |
|----------|----------|---------------------|-------------------|----------|------|
| qcguy (Ghost) | 1 | 256Mi / 200m | 1Gi / 2 | 595Mi, 1252m spike | user-facing |
| ollama (GPU) | 1 | 2Gi / 500m + gpu:1 | 6Gi / 4 + gpu:1 | 1786Mi | shared LLM backend |
| ollama UI | 1 | 256Mi / 100m | 1Gi / 1 | 864Mi | check why so high |
| predictonomy-web | **keep 2** | 100m / 512Mi | 750m / 2Gi | 78Mi | already set; 2 replicas deliberate (anti-502 HA) + HPA min2/max4 — do NOT trim |
| predictonomy-postgres | 1 | 100m / 256Mi | 500m / 512Mi | 465Mi | already set |
| yolo services (each) | 1 | 64–128Mi / 50m | 256–512Mi / 1 | <72Mi idle | mongo → 512Mi limit |
| bestrentaladmin | 1 | 64Mi / 50m | 256Mi / 1 | — | ~5 visitors/day |
| prometheus | **2 → 1** | 512Mi / 200m | 1.5Gi / 1 | ~790Mi×2 | + 7d retention |
| jenkins | 1 (or 0 idle) | 512Mi / 200m | 1.5Gi / 2 | 1872Mi | Xmx1g |
| registry | 1 | 256Mi / 100m | 1Gi / 1 | 694Mi | + run blob GC |

**R7. Disk hygiene.** The `minikube` docker volume lives at `/var/lib/docker/volumes/minikube/_data`
on `/var` (sda7); Jenkins builds + registry blobs fill it. Point Jenkins workspaces / backups at the
roomy `/mnt/minikube-backups` (432 G), not `/var`.

> **✅ PARTLY IMPLEMENTED 2026-06-30.** Two of the three legs are now closed:
> - **Registry blobs off `/var`** — done via **R8** (now on sdb2 `/mnt/kachra`, confirmed live). The
>   registry is no longer a `/var` consumer.
> - **Build cache (the real residual grower)** — measured 2026-06-30: 13 G buildkit cache + dangling
>   layers from Jenkins rebuilding every app image in the node's embedded docker. Dangling images free
>   ~0 B (shared layers); the **build cache** is what creeps `/var` up. Now bounded by
>   **`reduce-node-docker-cache.sh`** — a *surgical* daily prune (`docker builder prune --reserved-space 3GB`
>   + dangling `image prune`, NO `-a`), wired into the **`cloud` crontab @ 04:30 local** (minikube is
>   cloud-owned, so it can't be a root cron). This is the "scheduled" leg R7 always called for but that
>   the empty crontab never actually had. Took `/var` 55% → 45% on first run.
> - `reduce-docker-minikube-space.sh` / `reduce-var-space.sh` stay as the **manual emergency hammer
>   only** — they use `docker system prune -a -f`, which deletes app+base images the node would then
>   re-pull/rebuild. Do NOT schedule those.
> - **Base-image audit (2026-06-30).** Checked the "old" cached bases before deleting. Two looked stale
>   but are **live**, so were KEPT: `golang:1.19` (yolo CI build-agent pod — `IG-Trading-Microservices/
>   Jenkinsfile:110 image: golang:1.19`, ephemeral so it never shows in a workload scan) and
>   `grafana/grafana:9.3.2` (running, `kube-prometheus/.../grafana-deployment.yaml`). Only `node:18`
>   (plain) was genuinely dead — its `FROM node:18` hits were all in the `docker-development-youtube-series`
>   tutorial repo / `node_modules`; real web apps use `node:22`/`node:20`/`node:18-slim`. Removed it.
>   **Method to reuse:** an image is "dead" only if absent from BOTH (a) `kubectl get deploy/sts/ds/cronjob/pod
>   -A -o jsonpath` over container images AND (b) every real-app `Dockerfile`/`Jenkinsfile` `FROM`/`image:`
>   (exclude the tutorial repo + `node_modules`). Ephemeral CI agents live in Jenkinsfiles, not workloads.
>
> **Lesson — manual image deletes are low-value here.** node docker images share base layers, so `rmi`/
> `image prune` of a "1 GB" tag frees ~0 real disk (only the unique top layer); `df /var` didn't budge.
> The build CACHE is the only thing that meaningfully grows `/var`, which is why the daily prune (cache cap)
> — not image hunting — is the durable control. Don't bother hand-deleting cached images for space.
>
> *Remaining (optional, backlog):* bake a buildkit `gc`/`reserved-space` policy into the node docker via
> `start-scratch.sh` at cold boot, so the cache self-trims with no cron at all. The daily prune covers
> ~95% of the benefit, so this is a nicety, not a need.

**R8. Persist the registry on `/mnt/kachra`, off `/var`.** TODO (raised 2026-06-16). The
`kube-system/registry` addon currently has **no volume** — image blobs live on the registry pod's
ephemeral fs (`/var/lib/registry`), which sits on minikube's `/var`-backed disk. Two problems in one:
(a) a node/pod restart **wipes every pushed manifest** → cluster-wide `manifest unknown` ImagePullBackOff
*and* Jenkins agent image gone → 0 executors → builds stuck in queue (this exact outage hit 2026-06-16;
recovered by re-pushing the node's cached images); (b) the blobs bloat `/var`. Fix: back the registry
with a PVC (hostPath) at **`/mnt/kachra/container-registry-images`** (sdb2, 206 G, ~195 G free) so it
survives restarts *and* keeps `/var` lean. Caveat: `/mnt/kachra` is a separate HDD (sdb2) from the
minikube disk, so `docker push`/`pull` blob I/O will be slightly slower — acceptable for durability.
Wrinkle: the addon Deployment is `addonmanager.kubernetes.io/mode: Reconcile`, so a `kubectl patch` is
reverted by minikube's addon-manager — bake the volume into the node addon manifest
(`/etc/kubernetes/addons/`) or disable the addon and run a self-managed registry Deployment+PVC
(checked into `k8s/`). Pre-create `/mnt/kachra/container-registry-images` and mount it into minikube.
Supersedes the ephemeral half of R7 for the registry. Cross-ref: IG-Trading-Microservices memory
`registry-ephemeral-wipe.md`.

> **✅ IMPLEMENTED 2026-06-16 (in `k8s/registry/`) — pending cold-boot activation.** Approach chosen:
> **self-managed registry on sdb2**. Two facts found while building it corrected the sketch above:
> - The minikube docker driver binds exactly **one** host dir into the node
>   (`/mnt/minikube-backups/minikube-mnt → /mnt`, sdb1) and the bind is **`rprivate`**; it takes only
>   one `--mount-string`. So sdb2 (`/mnt/kachra`) cannot be added to a *running* node. `ensure-registry-store.sh`
>   instead bind-mounts (via `/etc/fstab`) sdb2's image dir **into** the minikube-mnt tree on the host;
>   docker's recursive (rbind) bind captures it **at container creation**, so it activates on the next
>   **cold boot** (`minikube delete` + `start-scratch.sh`), not on a warm `stop`/`start`.
> - The addon is replaced (not patched): `start-scratch.sh` now runs `minikube addons disable registry`
>   then `kubectl apply -f k8s/registry/` (PV → PVC → Deployment+Service → registry-proxy DaemonSet,
>   hostPort 5000 preserved so `:5000` / `container-registry.traderyolo.com` are unchanged).
>
> **Activation deferred to the next natural cold rebuild** (operator choice — a recreate-now would be
> as disruptive as the outage). Until then the registry still uses the old ephemeral store, so a warm
> stop still needs the manual re-push (RESTART-RECOVERY triage row 3). Acceptance test + rollback in
> `k8s/registry/README.md`.

### Net effect
Same 32 GB envelope, but: scheduler can no longer silently over-commit; OOM pressure is caught by
kubelet eviction and absorbed by zram instead of killing pods mid-request; ~2.5 GB reclaimed from HA
replicas + idle Jenkins; CPU burst headroom raised to 16 while the host keeps ~8 threads for
IntelliJ/Chrome; GPU cleanly dedicated to the one Ollama that serves everything. Real load
(100 + 100 + 5 visitors/day) fits with large margin.

### Apply order
1. **R1** (zram) — host change, no cluster restart, do anytime.
2. **R2** — already in `start-scratch.sh`; takes effect on next `restart-minikube.sh` / cold boot.
   Mirror the same flags into `restart-minikube.sh`.
3. **R3, R6** — manifest edits, roll out per namespace.
4. **R4, R7, R8** — operability follow-ups (R8 needs a minikube restart to mount `/mnt/kachra`).
