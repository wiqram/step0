# Restart Recovery — auto-start, auto-unseal & fast triage

> **Read this FIRST when the cluster is unhealthy after a host reboot or crash.** It maps the two
> recovery paths (warm restart vs cold from-scratch), documents what now recovers **automatically**,
> and gives a symptom → root-cause → fix table so a human or Claude Code can diagnose in under a
> minute. Added 2026-06-16 after a clean minikube stop took prod down for ~hours (the cluster did
> not auto-start and Vault came up sealed).
>
> Scope: this is **foundational minikube/cluster** behaviour, so it lives in STEP0 (not in any app
> repo). The automation is **host-side** — the host crontab + the minikube container's Docker
> restart policy; nothing here runs inside the cluster.

## TL;DR — which recovery path? (the "active vs not-active" question)

| Situation before the reboot/crash | What's needed | Now automatic? |
|---|---|---|
| Cluster was **running** (container exists) | **Warm resume** — Docker restarts the container, `minikube start` reconciles | ✅ **Yes** — see below |
| Cluster was **intentionally `minikube stop`ped** | Leave it down (respect intent) | ✅ Yes — stays down |
| Cluster container is **gone / deleted / corrupt** | **Cold rebuild** — `start-scratch.sh` (+ app redeploys) | ❌ **No — human decision** (it implies re-deploys); the watchdog **alerts**, never auto-rebuilds |

The decision is encoded in **Docker's `unless-stopped` restart policy** on the `minikube` container:
a cluster that was running auto-resumes on reboot; one that was explicitly stopped stays down. So
the container's post-boot state *is* the "was it meant to be running?" signal — no guessing.

Warm path = STEP0 `restart-minikube.sh` semantics (reuse cluster). Cold path = STEP0
`start-scratch.sh` (network → minikube → addons → vault → jenkins → apps). **Never** automate the
cold path — `minikube delete` is destructive (hostPath PVs survive, but in-cluster state + images
do not, and apps must be re-deployed).

## What happens automatically on a host reboot

1. **Docker** starts (`systemctl enable`d). Because the `minikube` container is
   `--restart=unless-stopped`, Docker **auto-resumes the cluster if it was running**.
2. **`cluster-autostart.sh`** (cron `@reboot` + `*/10` watchdog) re-enforces that policy and
   reconciles Kubernetes health:
   - container up + k8s healthy → noop;
   - container up + k8s unhealthy → `minikube start --driver=docker` (fixes kubeconfig/IP drift +
     control plane after an *unclean* crash);
   - container `exited` (after a grace window) → intentional stop, leave it;
   - container **ABSENT** or `minikube start` **fails** → **ntfy alert, never `minikube delete`**.
3. **`vault-auto-unseal.sh`** (cron `@reboot` + `*/5` watchdog) re-unseals Vault within ~10s of it
   being reachable. Vault has **no KMS auto-unseal** — it always boots **sealed**, and until it is
   unsealed every workload's `vault-agent-init` hangs (postgres/web/jobs stuck `Init`/`Error`).
   The unseal key stays on the host (`~/.vault/cluster-keys.json`) — never copied into the cluster.
4. **`check-backup.sh`** (cron `15 1 * * *` UTC) verifies the 01:00 `predictonomy-postgres-backup`
   ran; ntfy-alerts on failure. (App-level, but listed here as part of the post-reboot picture.)

**Healthy end-state to confirm:**
```bash
minikube status                                            # Host/Kubelet/APIServer = Running
kubectl -n vault exec vault-0 -- vault status              # Sealed = false
kubectl -n predictonomy get pods                           # web 2/2, postgres 1/1 Running
curl -s -o /dev/null -w '%{http_code}\n' https://predictonomy.com   # 200
```

## Fast triage — symptom → root cause → check → fix

| Symptom | Likely root cause | Check | Fix |
|---|---|---|---|
| `kubectl`/all sites down after reboot | cluster didn't resume | `docker ps -a \| grep minikube`; `tail ~/Ideaprojects/STEP0/logs/cluster-autostart.log` | container `exited` = intentionally stopped → `minikube start --driver=docker`; `running` but k8s down → let the `*/10` watchdog reconcile, or run `minikube start` |
| Pods stuck `Init`/`Error`, "secret not found" across **all** namespaces | **Vault sealed** (boots sealed, no KMS) | `kubectl -n vault exec vault-0 -- vault status` → `Sealed true`; `tail ~/Ideaprojects/STEP0/logs/vault-auto-unseal.log` | unsealer fixes in ~10s; if its loop died the `*/5` watchdog restarts it; manual: `restart-minikube.sh` calls `restart-vault.sh`, or unseal from `~/.vault/cluster-keys.json` |
| A web pod `ImagePullBackOff` / `manifest unknown` | **registry lost images** on stop — registry on ephemeral storage (**plan.md R8 / N-0006 #2, OPEN**) | `kubectl -n <ns> describe pod <pod>` | re-push the node's cached image, e.g. `minikube ssh -- docker push container-registry.traderyolo.com/predictonomy-web:latest`, then delete the pod. **Re-push the `*-migrate` image too** or data CronJobs stay broken |
| Site is fine but **data CronJobs** `ImagePullBackOff` | same #2 — only the web image was re-pushed | `kubectl -n predictonomy get pods \| grep -E 'refresh\|backup\|loaders'` | re-push the `predictonomy-migrate:latest` image too. A healthy site does NOT imply healthy jobs |
| Nightly backup skipped | Vault sealed at 01:00, or cluster down | `tail ~/IdeaProjects/Predictonomy/ops/agent/logs/backup-check.log` (this check stays app-side) | now backstopped by auto-unseal; one-off: `kubectl -n predictonomy create job --from=cronjob/predictonomy-postgres-backup backup-manual-$(date +%s)` |
| minikube container **gone** | unclean crash wiped it / `minikube delete` ran | `cluster-autostart.log` shows "ABSENT" + ntfy alert | **human decision** — run STEP0 `start-scratch.sh` (cold) then re-deploy apps; hostPath PVs (`/mnt/predictonomy-postgres`, `/mnt/predictonomy-backups`, `/mnt/minikube-backups`) survive |

## Where the automation lives

- **Scripts:** `cluster-autostart.sh` + `vault-auto-unseal.sh` live **here in STEP0** (repo root),
  logs in `STEP0/logs/`. The ntfy topic is in the gitignored `STEP0/.env` (`NTFY_URL`). The
  app-specific `check-backup.sh` stays in the **Predictonomy** repo (`ops/agent/`, logs in
  `ops/agent/logs/`) because it checks a Predictonomy CronJob.
- **Schedule:** host crontab (`crontab -l`) — `@reboot` + watchdog for each. Idempotent
  (flock-guarded, re-enforce drift). The crontab is host state, not in any repo.
- **Docker restart policy:** `docker update --restart=unless-stopped minikube` (re-apply after any
  `minikube delete`+recreate — the watchdog does this automatically).
- **Vault unseal key:** `~/.vault/cluster-keys.json` (0600, host only — never in cluster/git).
- **Fixed IPs / ports:** minikube node `172.16.238.2`; Vault NodePort `30200` (http, `tls_disable`),
  Predictonomy web NodePort `30072`.

## N-0006 cluster-fragility status (the 3 SPOFs from the 2026-06-16 outage)

1. **Vault no auto-unseal** → ✅ **mitigated** by `vault-auto-unseal.sh` (host-side; drill-proven:
   sealed → auto-recovered ~6s).
2. **Registry on ephemeral storage** (images vanish on stop) → 🟡 **FIX BUILT, NOT YET ACTIVE** —
   the durable self-managed registry on sdb2 is implemented in `k8s/registry/` and wired into
   `start-scratch.sh` (**plan.md R8**), but it only takes effect on the **next cold boot** (the sdb2
   bind is captured at minikube-container creation; see `k8s/registry/README.md`). **Until that cold
   boot, the registry is still ephemeral** — so after any warm stop you must still re-push cached
   images (web **and** `*-migrate`), per the triage row above.
3. **No cluster auto-start** → ✅ **mitigated** by `unless-stopped` + `cluster-autostart.sh`.

## Manual recovery (if the automation is gone or the host is rebuilt)

- **Warm** (cluster exists): `cd ~/Ideaprojects/STEP0 && ./restart-minikube.sh`, or just
  `minikube start --driver=docker`.
- **Cold** (from scratch): `cd ~/Ideaprojects/STEP0 && ./start-scratch.sh`, then re-deploy apps via
  Jenkins.
- **Re-arm the automation:** `docker update --restart=unless-stopped minikube`, then re-add the
  `@reboot` + watchdog cron lines pointing at the STEP0 scripts:
  ```cron
  @reboot            ~/Ideaprojects/STEP0/vault-auto-unseal.sh  >> ~/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1
  */5 * * * *        ~/Ideaprojects/STEP0/vault-auto-unseal.sh  >> ~/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1
  @reboot sleep 30 && ~/Ideaprojects/STEP0/cluster-autostart.sh >> ~/Ideaprojects/STEP0/logs/cluster-autostart.log 2>&1
  */10 * * * *       ~/Ideaprojects/STEP0/cluster-autostart.sh  >> ~/Ideaprojects/STEP0/logs/cluster-autostart.log 2>&1
  ```
  Start the unseal loop immediately without waiting for a reboot:
  `setsid ~/Ideaprojects/STEP0/vault-auto-unseal.sh >> ~/Ideaprojects/STEP0/logs/vault-auto-unseal.log 2>&1 </dev/null &`.

## Ownership

`cluster-autostart.sh` + `vault-auto-unseal.sh` were relocated from Predictonomy into STEP0 on
2026-06-16 (they are foundational cluster concerns — shared minikube lifecycle + shared Vault for
*all* namespaces). They read `NTFY_URL` from `STEP0/.env`. The app-specific `check-backup.sh` stays
in Predictonomy. **Caveat:** the ntfy topic now lives in two gitignored `.env` files (STEP0 +
Predictonomy) — if it is ever rotated, update both.
