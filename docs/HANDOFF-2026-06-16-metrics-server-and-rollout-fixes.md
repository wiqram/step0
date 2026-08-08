# HANDOFF — metrics-server + qcguy/open-webui fixes, 2026-06-16

**Owner project:** STEP0 (cluster lifecycle). Cross-repo changes in `qcguy-ghost`,
`IdeaProjects/ollama`, and `kube-prometheus`. Written by the session that fixed a stuck
qcguy rollout and discovered `kubectl top` was broken. Everything here is **DONE and
pushed** — this is a record + watch-items, not a blocked pickup.

## TL;DR
Three independent fixes, all live and committed:
1. **qcguy** had a stuck rollout (two pods) — readiness probe never passed. Fixed.
2. **open-webui** (ollama ns) was OOMKilling at its 1Gi cap. Bumped to 2Gi.
3. **`kubectl top` returned nothing for pods** — there was no metrics-server; the metrics
   API was served by prometheus-adapter, which can't work on this node. Enabled
   metrics-server and codified it in bootstrap.

## What changed (commit by commit)
| Repo (branch) | Commit | Change |
|---|---|---|
| qcguy-ghost (main) | `7f03488` | Readiness probe: add `X-Forwarded-Proto: https` header |
| ollama (main) | `8e6bcd5` | open-webui memory limit 1Gi→2Gi, request 256Mi→512Mi |
| kube-prometheus (main) | `88c88ce8` | Remove `manifests/prometheusAdapter-apiService.yaml` |
| kube-prometheus (main) | `48f81eaf` | gitignore `.idea/` |
| STEP0 (master) | `9634db5` | Enable `metrics-server` addon in `start-scratch.sh` + `restart-minikube.sh` |
| STEP0 (master) | `2e73c54` | architecture.md: document resource-metrics provider |
| STEP0 (master) | `2327e47` | CLAUDE.md: metrics-server convention + `kubectl top` orientation cmd |

## Why each — the non-obvious bits

### 1. qcguy stuck rollout (two pods)
- Commit `3107454` ("seamless rollouts") added a readiness probe doing a plain **HTTP GET /**
  on :2368. Ghost (`url=https://www.qcguy.com`) **301-redirects HTTP→HTTPS**, and kubelet
  **follows the redirect** onto the plaintext :2368 port → TLS handshake fails
  (`server gave HTTP response to HTTPS client`). Probe never passed.
- With `maxUnavailable:0`, the new NotReady pod was kept alongside the old (probe-less) pod
  → two pods, rollout past its progress deadline.
- **Fix:** `X-Forwarded-Proto: https` header makes Ghost return 200 (no redirect). Probe
  passes; rollout completes to a single Ready pod. Site verified HTTP 200.

### 2. open-webui OOMKills
- Steady usage ~960Mi sat right against the old **1Gi** cap → any spike (embeddings/model
  cache) crossed it → OOMKilled (exit 137), 7x. Node has ample memory (38% of ~43Gi).
- **Fix:** limit→2Gi, request→512Mi. Verified stable ~980Mi, 0 restarts.

### 3. metrics-server / `kubectl top` (the deep one — READ THIS)
- **There was no metrics-server.** `v1beta1.metrics.k8s.io` was served by
  **prometheus-adapter** (kube-prometheus). `top node` worked; `top pod` was empty.
- **Root cause:** on this minikube/docker node the kubelet's cAdvisor series
  (`/metrics/cadvisor`) are emitted **without `pod`/`namespace`/`container` labels**
  (confirmed: 0 pod-labeled lines straight from the kubelet). The adapter's pod
  resource-rules filter `pod!=""`, so they match nothing. No adapter config change fixes
  this — the labels are missing at the source.
- **Fix:** `minikube addons enable metrics-server`. It reads the kubelet **Summary API**
  (keyed by pod/namespace), unaffected by the missing cAdvisor labels, and takes over the
  metrics API. Verified: owner=`kube-system/metrics-server`, `top pod -A` populated (49 pods).
- **Durability — three layers, all closed:**
  - `stop/start`: addon flag persists in `~/.minikube/profiles/minikube/config.json`.
  - Full rebuild: `start-scratch.sh` + `restart-minikube.sh` now enable the addon.
  - kube-prometheus re-apply: the adapter's APIService manifest (which re-claimed the API
    on every `kubectl apply -f manifests/`) is **removed** — so `manifests/` no longer
    fights metrics-server.

## Watch-items / follow-ups (none blocking)
- **Don't re-add** `kube-prometheus/manifests/prometheusAdapter-apiService.yaml` — it
  silently re-breaks `top pod`. (Documented in STEP0 CLAUDE.md + architecture.md.)
- prometheus-adapter still runs (serves *custom* metrics, separate APIService). If it turns
  out nothing uses custom metrics here, the whole adapter Deployment could later be dropped
  to reduce footprint — not done, out of scope.
- A true empirical "survives restart" test (stop/start) was **not** run — it would take
  qcguy.com + all namespaces down briefly. Persistence was verified by config inspection
  instead. If you want the empirical check during a maintenance window, afterward run
  `kubectl get apiservice v1beta1.metrics.k8s.io` and `kubectl top pod -A`.
- cAdvisor missing pod labels is a node/runtime quirk (docker driver, cgroup v1). Not worth
  chasing while metrics-server covers `top`/HPAs — just know Prometheus dashboards that rely
  on per-pod `container_*` cAdvisor metrics may be similarly affected.

## Pointers
- STEP0 `docs/architecture.md` → "Resource metrics — metrics-server" (full rationale + verify).
- STEP0 `CLAUDE.md` → conventions bullet on metrics-server (the guardrail).
- Bootstrap: `start-scratch.sh` step 3 (addons) / `restart-minikube.sh` enable the addon.
