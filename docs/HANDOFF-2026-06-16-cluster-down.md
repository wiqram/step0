# HANDOFF — minikube down 2026-06-16, finish yolo reconcile Vault durability

**Owner project:** STEP0 (minikube lifecycle + registry). Cross-repo finish in
`IG-Trading-Microservices` (yolo). Written by the yolo session that hit the outage.

## TL;DR
`minikube status` is **Stopped** (host/apiserver/kubelet/kubeconfig all Stopped) — the
whole yolo platform is down. A yolo task (making the `reconcile-positions` sweep's Vault
secret durable) is **blocked** on the cluster being up. This doc is the pickup point.

## What's true right now
- **minikube: Stopped.** `~/.kube/config` was reset to ~90 bytes with no `minikube`
  context. Bring the node back with STEP0's `restart-minikube.sh`.
- **etcd + PVs survive stop/start** — so the k8s Secret `yolo/reconcile-config`, the
  registered service account `reconcile-bot@yolo.local`, and Mongo data all come back
  intact. Only the **ephemeral in-cluster registry** loses data (its pod has no volume —
  see plan.md **R8**), exactly like the 2026-06-16 03:24 wipe.
  - **⚠️ This only holds for `restart-minikube.sh` (preserves the node).** If the cluster
    is instead rebuilt from scratch (`start-scratch.sh` / `minikube delete`), etcd + Mongo
    PV are wiped: `reconcile-config` AND the `reconcile-bot@yolo.local` account are gone, so
    the "read the password back" step below CANNOT work. In that case, first **re-register
    the service account** (the password is unrecoverable — generate a fresh one) via
    `POST /v1/user/registerfollower`, then put the NEW creds in the SOPS manifest. The
    registration payload MUST include a `follower` object or it 409s with
    `Cannot read property 'brokerId' of null` — see yolo memory `reconcile-sweep-auth.md`.
- Because of that, after restart expect cluster-wide **ImagePullBackOff** (`manifest
  unknown`) until the images are re-pushed.

## STEP0 actions (do these here)
1. **Start the node:** run `restart-minikube.sh` (or `minikube start ...` as that script
   does). Wait for `minikube status` = Running and `kubectl -n yolo get pods`.
2. **Re-push the registry from the node's docker cache** (images persist across
   stop/start even though the registry pod's data doesn't):
   ```bash
   minikube ssh -- 'docker push container-registry.traderyolo.com/jenkins-inbound-agent-vik:cloud'  # FIRST — unblocks Jenkins agents
   minikube ssh -- 'for r in api user subscriber brokermiddleware userinterface robinstocks publisher notificationservice; do docker push container-registry.traderyolo.com/$r:latest; done'
   ```
   Verify: `curl -fsS https://container-registry.traderyolo.com/v2/_catalog`. Pods then
   clear ImagePullBackOff on their own (≤5 min backoff). (Full detail: yolo memory
   `registry-ephemeral-wipe.md`.) **Permanent fix is plan.md R8** — persist the registry
   on `/mnt/kachra/container-registry-images` so this stops recurring.

## Then — yolo side (in IG-Trading-Microservices, NOT here)
The reconcile sweep already works end-to-end (auth via service account, commit `aa7afe1b`).
The only remaining piece is **durability**: move its creds from the manual k8s Secret into
Vault so a cluster rebuild restores them. Two files must land **together** (committing the
cronjob alone points the vault sidecar at a non-existent `kv/yolo/reconcile`):

1. **`vault/reconcile.secret.sops.env`** (yolo repo — per the rule "keep yolo vault secrets
   in yolo"). Build it from the live (now-restored) secret, SOPS-encrypt, never print the
   password:
   ```bash
   cd IG-Trading-Microservices/vault
   EMAIL=$(kubectl -n yolo get secret reconcile-config -o jsonpath='{.data.RECONCILE_LOGIN_EMAIL}'   | base64 -d)
   PW=$(kubectl    -n yolo get secret reconcile-config -o jsonpath='{.data.RECONCILE_LOGIN_PASSWORD}' | base64 -d)
   FOL=$(kubectl   -n yolo get secret reconcile-config -o jsonpath='{.data.RECONCILE_FOLLOWERS}'      | base64 -d)
   umask 077
   { printf 'RECONCILE_FOLLOWERS=%s\n' "$FOL"; printf 'RECONCILE_LOGIN_EMAIL=%s\n' "$EMAIL"; printf 'RECONCILE_LOGIN_PASSWORD=%s\n' "$PW"; } > reconcile.secret.env
   sops -e reconcile.secret.env > reconcile.secret.sops.env && rm -f reconcile.secret.env
   ```
   (`vault/.sops.yaml` already carries the age recipient; `vault-sync.sh` auto-globs
   `vault/*` so this auto-creates `kv/yolo/reconcile` on the next Jenkins deploy. NOTE: run
   kubectl from the repo ROOT, not inside `vault/` — a `cd` into a subdir broke kube
   context during the original session.)

2. **`k8s/reconcile-cronjob.yaml`** — switch the sweep from the manual k8s Secret to
   vault-agent injection (mirrors expert-stats). This edit was reverted in the working tree
   to avoid a half-commit race; re-apply the full file below:

   ```yaml
   ---
   # Read-only broker-vs-DB reconciliation sweep (re-baseline Wave 1).
   # Calls the gateway's /v1/brokermiddleware/reconcile/{email} per follower and
   # exits non-zero on drift, so failed Jobs are the alert signal (Wave 4 wires
   # this into Grafana). NEVER places or closes trades.
   #
   # RECONCILE_FOLLOWERS + the service-account login come from Vault kv/yolo/reconcile,
   # injected by the vault-agent sidecar to /vault/secrets/config (same pattern as the
   # expert-stats / platform-kpi cronjobs). The values are owned declaratively by
   # vault/reconcile.secret.sops.env in this repo and pushed to Vault by the Jenkins
   # 'Refresh Vault secrets' stage (vaultSync) BEFORE this cronjob is applied — so a
   # fresh/restarted cluster restores them automatically, no manual `kubectl create secret`.
   apiVersion: batch/v1
   kind: CronJob
   metadata:
     name: reconcile-positions
     namespace: yolo
   spec:
     schedule: "15 6,18 * * *"   # twice daily, off-peak
     successfulJobsHistoryLimit: 1
     failedJobsHistoryLimit: 3
     jobTemplate:
       spec:
         template:
           metadata:
             annotations:
               vault.hashicorp.com/agent-inject: 'true'
               vault.hashicorp.com/role: 'yolo-role'
               vault.hashicorp.com/agent-pre-populate-only: 'true'
               vault.hashicorp.com/agent-inject-secret-config: 'kv/yolo/reconcile'
               vault.hashicorp.com/agent-inject-template-config: |
                 {{ with secret "kv/yolo/reconcile" -}}
                   export RECONCILE_FOLLOWERS="{{ .Data.data.RECONCILE_FOLLOWERS }}"
                   export RECONCILE_LOGIN_EMAIL="{{ .Data.data.RECONCILE_LOGIN_EMAIL }}"
                   export RECONCILE_LOGIN_PASSWORD="{{ .Data.data.RECONCILE_LOGIN_PASSWORD }}"
                 {{- end }}
             labels:
               app: reconcile-positions
           spec:
             serviceAccountName: vault-secrets
             restartPolicy: Never
             containers:
               - name: reconcile
                 image: python:3.12-alpine
                 imagePullPolicy: IfNotPresent
                 env:
                   - name: GATEWAY
                     value: "http://api-gateway:9090"
                 # Source the Vault-injected creds, then run the read-only sweep.
                 command:
                   - /bin/sh
                   - -c
                   - . /vault/secrets/config && python3 /scripts/run_all.py
                 volumeMounts:
                   - name: reconcile-script
                     mountPath: /scripts
             volumes:
               - name: reconcile-script
                 configMap:
                   name: reconcile-script
   ---
   # The 'reconcile-script' configmap is created automatically by the Jenkins deploy
   # (idempotent: kubectl create configmap ... --dry-run=client | kubectl apply), so a
   # fresh/restarted cluster recreates it before this cronjob runs. To iterate locally:
   # kubectl -n yolo create configmap reconcile-script --from-file=run_all.py=scripts/reconcile/run_all.py --dry-run=client -o yaml | kubectl apply -f -
   ```

3. **Commit both together** on `Claude-agent-update`, push, deploy via Jenkins. After
   deploy, the old manual `reconcile-config` secret is unused — optional cleanup
   `kubectl -n yolo delete secret reconcile-config` (only after `kv/yolo/reconcile` exists
   and a sweep run passes). Verify: `kubectl -n yolo create job recon-check
   --from=cronjob/reconcile-positions` → logs show 3 followers swept (non-zero exit on
   drift is BY DESIGN).

## Pointers
- yolo memory: `reconcile-sweep-auth.md` (the durability TODO), `registry-ephemeral-wipe.md`
  (re-push recovery), `project-boundaries-rule.md` (this STEP0/Vault/yolo split).
- STEP0 `plan.md` **R8** = the permanent registry-persistence fix that prevents recurrence.
