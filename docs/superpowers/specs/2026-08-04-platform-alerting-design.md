# Platform alerting: Alertmanager → ntfy — design

**Date:** 2026-08-04
**Status:** approved (design), implementation in progress
**Touches:** `ntfy-lib.sh`, `ntfy-topic-check.sh`, `resource-crunch-watch.sh` → `alerting-pipeline-watch.sh`,
`install-cron.sh`, `verify-recovery.sh`, `CLAUDE.md`, `docs/RESTART-RECOVERY.md`, `tests/`,
kube-prometheus `manifests/alertmanager-secret.yaml`, `manifests/platform-hardware-prometheusRule.yaml`,
`manifests/grafana-datasources.yaml`

## Goal

Get infrastructure alerts — CPU/GPU temperature, cluster resource pressure, critical
platform health — onto the phone via ntfy.

## What the survey found (2026-08-04)

The starting assumption was "build alert rules". That was wrong. The rules already exist:

- **138 alerting rules** are already deployed as `PrometheusRule` CRs across eight
  kube-prometheus groups (`node-exporter-rules`, `kubernetes-monitoring-rules`,
  `kube-state-metrics-rules`, `alertmanager-main-rules`, …). They cover `TargetDown`,
  node filesystem/memory/CPU, kubelet health, pod crashloops, PV filling, and a
  `Watchdog` dead-man's-switch rule.
- **Alertmanager's four receivers — `Default`, `Watchdog`, `Critical`, `null` — are bare
  names with no configuration.** Every one of those 138 rules has been firing into a void.
- At survey time **6 alerts were firing**, including two `critical`.

So the work is not authoring rules. It is connecting a pipeline that was never plugged in.

### The two critical alerts are false positives

`KubeSchedulerDown` and `KubeControllerManagerDown` have been firing continuously.
Both components are healthy — `kube-scheduler-minikube` and `kube-controller-manager-minikube`
have been `1/1 Running` for 6d11h. Neither has a Service, so kube-prometheus's ServiceMonitors
find no targets and the rules' `absent()` clause fires forever. This is the standard
kube-prometheus-on-minikube artifact: minikube binds both components to `127.0.0.1`.

**Deleting the ServiceMonitors would not fix it** — the rules are `absent(up{job=...} == 1)`,
so removing the scrape target makes them fire harder. Either the components must become
scrapable (a minikube restart with `--extra-config=scheduler.bind-address=0.0.0.0` and the
same for the controller manager), or the two alerts must be routed away.

Wiring ntfy without handling this means two permanent critical pages from hour one, which
is precisely how an alert channel gets muted.

### Metrics available (verified against Prometheus, not assumed)

| Indicator | Series | Reading at survey |
|---|---|---|
| CPU package temp | `node_thermal_zone_temp{type="x86_pkg_temp"}` | 72 °C |
| GPU temp | `DCGM_FI_DEV_GPU_TEMP` | 47 °C |
| GPU utilisation | `DCGM_FI_DEV_GPU_UTIL` | 0 % |
| GPU framebuffer | `DCGM_FI_DEV_FB_USED` / `DCGM_FI_DEV_FB_FREE` | 9408 / 2501 MiB |
| Scrape health | `up` | 20 jobs, none down |

`node-exporter` runs with `--no-collector.hwmon`, so `node_hwmon_temp_celsius` does **not**
exist. It does not need to: the `x86_pkg_temp` thermal zone carries the package temperature,
which is the same kernel source `resource-crunch-watch.sh` already falls back to. No
node-exporter change is required.

`dcgm-exporter` is present in `monitoring` and scraping cleanly.

## Decisions (locked)

- **Alertmanager is the alerting engine**, not Grafana alerting. It activates the 138
  existing rules, is owned entirely by kube-prometheus, and has zero coupling to the yolo
  app repo.
- **New ntfy topic `yolo-private-cloud-platform`** for infrastructure alerts, registered in
  `ntfy-lib.sh`. Kept separate from `yolo-grafana` (yolo app alerts) so one can be muted
  without the other.
- **`resource-crunch-watch.sh` is demoted, not retired.** It becomes the alerting-pipeline
  watchdog — the only alerting that runs *outside* the cluster, and therefore the only thing
  that can still speak when Prometheus or Alertmanager is the component that died.
- **No duplicate notifications.** Upstream rules already cover node CPU/memory/disk/PV/pods,
  so the new PrometheusRule adds only what upstream cannot know about: this box's thermal
  sensors and GPU.
- Grafana's own alerting (the `grafana-alerting-yolo` ConfigMap, owned by the yolo repo) is
  **not touched**.

## Why not Grafana alerting

Grafana's entire `/etc/grafana/provisioning/alerting` directory is mounted from the
`grafana-alerting-yolo` ConfigMap, which the **yolo app repo's** Jenkins build regenerates.
Platform alert rules placed there would be destroyed on yolo's next deploy and would not
belong to yolo in the first place. Working around that needs a projected volume merging two
ConfigMaps, plus per-rule `notification_settings` to avoid colliding with Grafana
provisioning's singleton root notification policy — significant machinery to hand-write
rules that already exist and work.

## Design

### A. Channel registration — STEP0

`ntfy-lib.sh` gains:

```sh
NTFY_TOPIC_PLATFORM="${NTFY_TOPIC_PLATFORM:-yolo-private-cloud-platform}"   # Alertmanager infra alerts
NTFY_TOPIC_GRAFANA="${NTFY_TOPIC_GRAFANA:-yolo-grafana}"                    # yolo app alerts (Grafana alerting)
```

both appended to `NTFY_TOPICS`.

`yolo-grafana` is registered because it is **already live** — the Grafana contact point
`yolo-ntfy` has been publishing to it — while being absent from the registry that CLAUDE.md
designates as the source of truth. The registry should describe reality.

### B. Gate extension — `ntfy-topic-check.sh`

The existing gate only inspects bash publishers, which is why `yolo-grafana` went
unregistered without anything failing. A new check scans **non-bash publishers** — the
Alertmanager secret manifest and the Grafana alerting ConfigMap — for `ntfy.sh/<topic>`
URLs and fails on any topic not in `NTFY_TOPICS`.

This is the check that would have caught the existing gap, which is the argument for it.

### C. Alertmanager receivers — `manifests/alertmanager-secret.yaml`

| Receiver | Change |
|---|---|
| `Default` | `webhook_configs` → ntfy platform topic, `max_alerts: 5` |
| `Critical` | same topic, templated priority 5 (urgent) |
| `Watchdog` | left as a no-op — it fires *continuously* by design; its **absence** is the signal |
| `null` | unchanged |

Alertmanager's webhook payload is fixed and cannot be templated, so formatting is done by
**ntfy's own templating** (`?tpl=yes`), which renders Go templates against the posted JSON:

```
t = [{{.status | upper}}] {{.commonLabels.alertname}}
m = {{range .alerts}}{{.labels.severity}} {{.labels.alertname}} {{.annotations.summary}}{{end}}
p = {{if eq .status "resolved"}}2{{else if eq .commonLabels.severity "critical"}}5{{else}}3{{end}}
```

ASCII hyphens only, no em dash — the `ntfy_header_safe` lesson (BUG-CANARY-NTFY-EM-DASH)
applies to anything that ends up in a notification header.

**New route:** `alertname =~ KubeSchedulerDown|KubeControllerManagerDown` → `null`, commented
with the minikube cause and the real fix, so the suppression is visibly deliberate rather
than looking like an oversight.

### D. Hardware rules — `manifests/platform-hardware-prometheusRule.yaml` (new)

| Alert | Expression | For | Severity |
|---|---|---|---|
| `HostCPUPackageTempHigh` | `node_thermal_zone_temp{type="x86_pkg_temp"} > 90` | 15m | warning |
| `HostCPUPackageTempCritical` | same `> 95` | 5m | critical |
| `GPUTempHigh` | `DCGM_FI_DEV_GPU_TEMP > 85` | 15m | warning |
| `GPUTempCritical` | same `> 90` | 5m | critical |
| `GPUMemoryAlmostFull` | `FB_USED/(FB_USED+FB_FREE) > 0.90` | 15m | warning |

Thresholds are copied from the existing `RC_*` defaults (i9-12900K Tjmax 100 °C, 3080 Ti
throttles ~93 °C) so behaviour does not silently shift. `for: 15m` reproduces the
3-consecutive-sample debounce `resource-crunch-watch.sh` deliberately implemented.

### E. Alertmanager as a Grafana datasource — `manifests/grafana-datasources.yaml`

Adds an `alertmanager` datasource (`uid: platform-alertmanager`, implementation
`prometheus`) pointing at `http://alertmanager-main.monitoring.svc:9093`, so these alerts
remain visible in Grafana's UI despite not being Grafana-managed alerts.

The existing `prometheus` datasource has **no explicit `uid`** (Grafana generated
`P1809F7CD0C75ACF3`). Pinning it is *out of scope* — existing dashboards reference the
generated value, and changing it would break them.

### F. `resource-crunch-watch.sh` → `alerting-pipeline-watch.sh`

Renamed to match what it now does. Watches:

1. Prometheus reachable (`/-/healthy`)
2. Alertmanager reachable (`/-/healthy`)
3. The `Watchdog` alert present and firing — proves rule evaluation is actually running,
   not merely that the process is up
4. `alertmanager_notifications_failed_total` not climbing — proves the ntfy webhook works

Pushes **only** when the pipeline is broken, so it produces no duplicate pages. It keeps its
existing registered topic `yolo-private-cloud-resource-crunch`: when the platform channel's
own pipeline is dead, the warning has to arrive by a different path.

Retains the debounce/cooldown/recovery state machine already proven in that script, and the
`--status` flag.

## Rebuild durability

Every change sits on a path that survives a rebuild, per CLAUDE.md's three-path rule:

- **(a)** `kube-prometheus/manifests/` — C, D, E, applied wholesale by `start-scratch.sh`
- **(b)** STEP0 scripts — A, B, F

Nothing lives in an app repo, so nothing can silently vanish. `restore-scratch.sh` calls
`start-scratch.sh`, so the bare-metal path inherits all of it.

## Non-goals

- Grafana alerting and the yolo `grafana-alerting-yolo` ConfigMap — untouched.
- Repinning the prometheus datasource UID.
- Properly fixing scheduler/controller-manager scraping — needs a minikube restart with
  `--extra-config`; recorded as a follow-up, suppressed via routing for now.
- Enabling node-exporter's `hwmon` collector — unnecessary, `x86_pkg_temp` suffices.

## Verification

1. `./ntfy-topic-check.sh` green, including the new manifest scan.
2. Synthetic Alertmanager JSON POSTed to the platform topic to prove ntfy's template
   renders (public, secret-free topic).
3. Alertmanager config reload confirmed via its API after apply.
4. `KubeSchedulerDown` / `KubeControllerManagerDown` confirmed routed to `null`.
5. A real alert observed arriving on the phone.
6. `./alerting-pipeline-watch.sh --status` clean; `./verify-recovery.sh` no new FAIL.
