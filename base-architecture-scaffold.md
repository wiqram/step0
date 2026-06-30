# Base Architecture Scaffold — what every NEW project must contain to deploy on this private cloud

> **Read me first when scaffolding a new website/app.** This is the canonical, copy-paste
> contract for getting a brand-new project deployed onto the live production environment
> **without re-discovering anything**. Point Claude here and it knows exactly which files to
> create, how to wire secrets/registry/ingress, and what to register with the platform.
>
> Companion docs: `architecture.md` (full system design; §10 has the original "deploy a new
> app" notes), `RESTART-RECOVERY.md` (recovery), `restore-scratch.sh` (bare-metal DR). The
> Vault side has a worked onboarding script: `~/Ideaprojects/vault/start-scratch-<app>.sh`.

---

## 0. The platform you are deploying onto (fixed facts — do not invent)

| Thing | Value |
|---|---|
| Topology | **Single Ubuntu host** → Docker → one **Minikube** node → Kubernetes |
| Minikube node IP | **`172.16.238.2`** (all NodePorts + registry live here) |
| nginx-proxy-manager (NPM) | **`172.16.238.10`** — public TLS entry, admin UI on `:81`, **MariaDB-backed** |
| Docker network | **`5million`** (gateway `172.16.238.1`) — the *host/platform* network (minikube + NPM) |
| Container registry | **`container-registry.traderyolo.com`** (= `172.16.238.2:5000`) |
| Secrets | **HashiCorp Vault** (in-cluster) + **SOPS/age** for in-repo encrypted secrets |
| CI/CD | **Jenkins** (in-cluster, NodePort `30380`, jobs live on a PV — created in the UI) |
| Repos | `github.com/wiqram/<app>` |
| Public traffic path | DNS → NPM (`:443`) → **NodePort on `172.16.238.2:30xxx`** → app Service |

**Every app owns exactly one of each:** a K8s namespace, a `kv/<app>/*` Vault path (+ `<app>-policy`
+ `<app>-role` + `jenkins-<app>` AppRole), a Jenkins job (+ build token), a unique NodePort, and
one+ NPM proxy host (domain → `172.16.238.2:<nodeport>` + Let's Encrypt cert).

---

## 1. The dev vs prod model

- **dev** = runs **locally, off-cluster** via `docker-compose-dev.yml`. Secrets are decrypted
  locally (`sops -d`) into a gitignored `.env*`; config is inline/`env_file`. Services resolve each
  other by compose service-name on the default bridge. (You do **not** need the `5million` network in
  a new app's dev compose — that's a platform network; only legacy multi-service apps attach to it.)
- **prod** = runs **in the Minikube cluster only**. Images are pulled from
  `container-registry.traderyolo.com`; **all secrets come from Vault** via the agent injector
  (rendered to `/vault/secrets/config`, which the container sources before exec). No `.env` in prod.

`docker-compose-prod.yml` is a **build/push manifest** (it builds `Dockerfile.production` and pushes
registry images); the *runtime* prod definition is the Kubernetes manifest, not the compose file.

---

## 2. Minimal file scaffold (the "new website" template)

Canonical minimal reference: **`~/IdeaProjects/bestrentaladmin`** (Next.js web + Postgres + migrate).
For a multi-service backend, the reference is **`~/IdeaProjects/IG-Trading-Microservices`** ("yolo"),
which splits manifests into `compiled.yaml` + `compiled-deployments.yaml` + `compiled-services.yaml`.

Load-bearing deploy files a new site MUST have (everything else is app code):

```
<app>/
├── Dockerfile                  # dev image (single stage; runs the dev server as root)
├── Dockerfile.production       # multi-stage: base→deps→builder→migrator→runner (non-root)
├── docker-compose-dev.yml      # dev: db + migrate + web, local build, host port maps
├── docker-compose-prod.yml     # prod build/push: registry-tagged web + migrate images
├── Jenkinsfile                 # build/push → vaultSync → kubectl apply
├── namespace.yaml              # Namespace: <app>
├── deployment.yaml             # SA + (PV/)PVC + postgres Deploy+Svc + migrate Job + web Deploy+Svc
└── vault/
    ├── .sops.yaml              # SOPS+age creation_rules
    ├── postgres.env            # non-secret pg config (committed plaintext)  -> kv/<app>/postgres
    ├── postgres.secret.sops.env# encrypted pg secrets                        -> kv/<app>/postgres
    └── web.secret.sops.env     # encrypted web secrets                       -> kv/<app>/web
```

---

## 3. File shapes (copy these skeletons, swap `<app>`)

### 3.1 `Dockerfile` (dev) and `Dockerfile.production`
Dev is one stage running the dev server. Prod is multi-stage and adds: **non-root `USER`**, the
**`migrator` target** (a separate image whose only job is the DB migration), and **sourcing Vault
secrets before exec**. Node/Next example (mirror the language; Go uses `golang:1.x-alpine`→`alpine`):

```dockerfile
# Dockerfile.production  — base -> deps -> builder -> migrator -> runner
FROM node:22-bookworm-slim AS base
WORKDIR /app
RUN apt-get update && apt-get install -y --no-install-recommends ca-certificates openssl && rm -rf /var/lib/apt/lists/*

FROM base AS deps
COPY package.json package-lock.json* ./
RUN npm ci

FROM base AS builder
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npx prisma generate && npm run build           # Next.js: next.config must set output:'standalone'

FROM base AS migrator                               # the migrate-step image
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN npx prisma generate
CMD ["sh","-lc","npx prisma db push"]

FROM base AS runner                                 # the web image
ENV NODE_ENV=production PORT=3000 HOSTNAME=0.0.0.0
RUN groupadd --system --gid 1001 nodejs && useradd --system --uid 1001 --gid nodejs nextjs
COPY --from=builder /app/public ./public
COPY --from=builder /app/.next/standalone ./
COPY --from=builder /app/.next/static ./.next/static
USER nextjs
EXPOSE 3000
CMD ["node","server.js"]
```

### 3.2 `docker-compose-prod.yml` (build/push manifest)
```yaml
services:
  <app>-migrate:
    build: { context: ., dockerfile: Dockerfile.production, target: migrator }
    image: ${REGISTRY_HOST:-container-registry.traderyolo.com}/<app>-migrate:${TAG:-latest}
    env_file: ./.env.production
  <app>-web:
    build: { context: ., dockerfile: Dockerfile.production, target: runner }
    image: ${REGISTRY_HOST:-container-registry.traderyolo.com}/<app>-web:${TAG:-latest}
    ports: ["3000:3000"]
    env_file: ./.env.production
```
> Registry image names are **`container-registry.traderyolo.com/<app>-web`** and **`…/<app>-migrate`**
> (untagged ⇒ `:latest`, which pairs with `imagePullPolicy: Always` in k8s). A single-process app
> just has `<app>` (no `-web`/`-migrate` split) — see yolo's `container-registry.traderyolo.com/<svc>`.

### 3.3 `Jenkinsfile` (3 stages, runs on the `kubernetes` cloud agent)
```groovy
// Stage 1 — Build & push (container: docker-agent)
sh 'docker compose -f docker-compose-prod.yml --env-file .env build <app>-web <app>-migrate'
sh 'docker compose -f docker-compose-prod.yml --env-file .env push  <app>-web <app>-migrate'

// Stage 2 — Refresh Vault secrets (container: jnlp). Self-syncs this repo's vault/ into kv/<app>/*
library identifier: 'vault-tools@main', retriever: modernSCM([
    $class: 'GitSCMSource',
    remote: 'https://github.com/wiqram/vault.git',
    credentialsId: '46f819a6-2a0e-4943-a5ae-49f1dac74f4e'])
vaultSync(app: '<app>')

// Stage 3 — Deploy (container: jnlp). ORDER MATTERS.
sh 'kubectl create -f namespace.yaml --dry-run=client -o yaml | kubectl apply -f -'
sh 'kubectl delete job -n <app> <app>-migrate --ignore-not-found=true --wait=true --timeout=120s'  // Jobs are immutable
sh 'kubectl apply -f deployment.yaml'
sh 'kubectl rollout status deployment -n <app> <app>-postgres --timeout=180s'
// poll the migrate Job to Complete/Failed (~240s) before continuing
sh 'kubectl rollout restart deployment -n <app> <app>-web'   // force :latest re-pull
sh 'kubectl rollout status  deployment -n <app> <app>-web --timeout=240s'
```
> The deploy order is the contract: **push → vaultSync → namespace → delete-old-migrate-Job → apply →
> wait Postgres → wait migrate → rollout web.** The build agent image
> `jenkins-inbound-agent-vik:cloud` already has `kubectl, vault, sops, age, jq, docker`.

### 3.4 `namespace.yaml` + `deployment.yaml`
```yaml
# namespace.yaml
apiVersion: v1
kind: Namespace
metadata: { name: <app> }
```

`deployment.yaml` contains, in order: **ServiceAccount `vault-secrets`** (every pod runs as this so
the Vault injector can auth) → **Postgres PVC** (or durable hostPath PV, below) → **Postgres
Deployment + ClusterIP Service** → **migrate Job** (with a `wait-for-postgres` initContainer) →
**Web Deployment + NodePort Service**. The reusable bits:

```yaml
apiVersion: v1
kind: ServiceAccount
metadata: { name: vault-secrets, namespace: <app> }
---
# --- Vault agent-injector annotations: put these on EVERY pod that needs secrets ---
#   (postgres pod -> kv/<app>/postgres ; web + migrate pods -> kv/<app>/web)
template:
  metadata:
    annotations:
      vault.hashicorp.com/agent-inject: "true"
      vault.hashicorp.com/role: "<app>-role"
      vault.hashicorp.com/agent-pre-populate-only: "true"          # init-only, no sidecar
      vault.hashicorp.com/agent-inject-secret-config: "kv/data/<app>/<group>"
      vault.hashicorp.com/agent-inject-template-config: |
        {{- with secret "kv/data/<app>/<group>" -}}
        {{- range $k, $v := .Data.data }}
        export {{ $k }}={{ $v | toJSON }}
        {{- end }}{{- end }}
  spec:
    serviceAccountName: vault-secrets
    containers:
      - name: <app>-web
        image: container-registry.traderyolo.com/<app>-web   # untagged => :latest
        imagePullPolicy: Always
        command: ["sh","-c",". /vault/secrets/config && exec node server.js"]   # SOURCE secrets first
        ports: [{ containerPort: 3000 }]
        readinessProbe: { httpGet: { path: /api/health, port: 3000 } }
        livenessProbe:  { httpGet: { path: /api/health, port: 3000 } }
        resources: { requests: { cpu: "50m", memory: "128Mi" }, limits: { cpu: "1", memory: "384Mi" } }
---
apiVersion: v1
kind: Service                       # WEB -> NodePort (this is what NPM proxies to)
metadata: { name: <app>-web, namespace: <app> }
spec:
  type: NodePort
  ports: [{ name: http, nodePort: 30XXX, port: 3000, targetPort: 3000 }]   # pick a FREE 30xxx (see §4)
  selector: { app: <app>-web }
```

**Database rules:** Postgres Service is **ClusterIP only — never NodePort** (the DB must not be node-
reachable). For single-node durability use a **hostPath PV** so data survives PVC/namespace deletion:
```yaml
kind: PersistentVolume
spec:
  storageClassName: manual
  persistentVolumeReclaimPolicy: Retain
  accessModes: [ReadWriteOnce]
  capacity: { storage: 5Gi }
  hostPath: { path: /mnt/<app>-postgres }      # lives on the backed-up minikube-mnt volume
# + set PGDATA=/var/lib/postgresql/data/pgdata on the postgres container
```
> hostPath dirs under `/mnt/<app>-*` are on the shared volume that the weekly backup captures and
> `restore-scratch.sh` restores. Add new ones to restore-scratch.sh phase 3 (`mkdir -p`) if you want
> them pre-created on a bare-metal rebuild.

### 3.5 `vault/` (in-repo encrypted secrets)
Per logical secret group (`postgres`, `web`, …): a committed plaintext `<group>.env` for non-secret
config and a committed **SOPS-encrypted** `<group>.secret.sops.env` for secrets. They sync to
`kv/<app>/<group>` via `vaultSync(app:'<app>')` on every deploy. Keys are `UPPER_SNAKE`.

```yaml
# vault/.sops.yaml  — TWO recipients: this app's OWN key + the master recovery key.
# Per-app isolation: this app's Jenkins job decrypts only its own secrets.
creation_rules:
  - path_regex: \.secret(\.sops)?\.env$
    age: "age1<THIS-APP-from-gen-app-age-key>,age1jgqwj4az5kuzhq2m9077cmdr3q22zv60z86wrwql8ehvj4k0qgeskqx4nn"
    unencrypted_regex: "^(#.*)?$"
```
Mint the app's key first: `~/Ideaprojects/vault/gen-app-age-key.sh <app>` (writes it to Vault
`kv/age-keys/<app>` + `~/.vault/age-keys/<app>.txt`), then paste the printed recipient as the **first**
of the two `age:` recipients. Edit a secret with `cd vault && sops <group>.secret.sops.env`.
- **Per-app private key** — in Vault `kv/age-keys/<app>` (read only by `jenkins-<app>` AppRole) +
  offline mirror `~/.vault/age-keys/<app>.txt`. `vaultSync` fetches it at deploy.
- **Master recovery key** (`age1jgqwj4az5…`) — operator-offline at `~/.config/sops/age/keys.txt`,
  the recovery anchor + your local-dev decrypt key. Never in Vault or any repo.
Standard web mapping:

| Vault path (KV v2) | Typical keys | Consumed by |
|---|---|---|
| `kv/<app>/postgres` | `POSTGRES_DB`, `POSTGRES_USER`, `POSTGRES_PASSWORD` | postgres pod |
| `kv/<app>/web` | `DATABASE_URL`, plus app-specific (`ADMIN_*`, API keys, …) | web pod **and** migrate Job |

---

## 4. Platform registration checklist (do these so the app actually deploys)

These are the touch-points OUTSIDE the app repo. Most are scripted in the vault repo's
`start-scratch-<app>.sh`; copy an existing one.

| # | Touch-point | Where | What to add |
|---|---|---|---|
| 1 | **Vault policy** | `~/Ideaprojects/vault/<app>-policy.hcl` (new file) | `read` on `kv/data/<app>/*`, `read,list` on `kv/metadata/<app>/*`. *Its existence also auto-enrolls the `jenkins-<app>` AppRole.* |
| 1b | **App age key** | `~/Ideaprojects/vault` → `./gen-app-age-key.sh <app>` | Mints the app's SOPS age key to `kv/age-keys/<app>` + `~/.vault/age-keys/<app>.txt`; paste the printed recipient into the app's `vault/.sops.yaml` as the **1st of two** `age:` recipients (2nd = master). `jenkins-<app>-policy` auto-gains read on `kv/data/age-keys/<app>` (it's in `jenkins-policy.hcl.tmpl`). `vaultSync` fetches it at deploy. |
| 2 | **Vault K8s-auth + role** | `~/Ideaprojects/vault/start-vault.sh` (mirror an existing app, ~L127–151) | `vault write -namespace <app> auth/kubernetes/config …`; `vault policy write <app>-policy -< <app>-policy.hcl`; `vault write auth/kubernetes/role/<app>-role bound_service_account_names=vault-secrets bound_service_account_namespaces=<app> policies=<app>-policy` |
| 3 | **Jenkins AppRole + creds** | auto | `start-vault.sh`→`setup-jenkins-approle.sh` creates `jenkins-<app>`; `setup-jenkins-credentials.sh` provisions `vault-approle-id-<app>`, `vault-approle-secret-<app>` into Jenkins. The age key is **not** a Jenkins credential — `vaultSync` fetches the per-app key from Vault `kv/age-keys/<app>`. Nothing manual. |
| 4 | **Jenkins job** | Jenkins UI (`:30380`, PV-backed, not in git) | Create a pipeline job named `<app>` → this repo + its `Jenkinsfile`; set a remote-build **token** (e.g. `<app>` short form). |
| 5 | **NodePort** | app `deployment.yaml` Service | Pick a **free** `30000–32767` port. Check taken ports: `~/Ideaprojects/nginx/all proxy hosts.txt` and `grep -rn 'nodePort:' ~/IdeaProjects/*/deployment.yaml ~/IdeaProjects/*/compiled*.yaml`. Record the new one in `architecture.md §3`. |
| 6 | **NPM proxy host** | NPM admin UI on `172.16.238.10:81` (MariaDB-backed — UI/API only, never edit conf files) | New proxy host: `your-domain.com` → forward `172.16.238.2:<nodeport>`, scheme `http`, **SSL forced + request a Let's Encrypt cert** (HTTP-01). `mysqldump -uroot -pnpm npm` first if scripting the DB. |
| 7 | **Cold-boot build trigger** | `~/Ideaprojects/STEP0/trigger-app-builds.sh` | Add `echo "building <app>"` + `curl -X POST "$JENKINS/job/<app>/build?token=<jobtoken>"`. Auth comes from `.env` `JENKINS_CRED` — **never hardcode a token.** |
| 8 | **DNS** | your registrar | Point `your-domain.com` A-record at the host's public IP. |

Host prerequisite for all of it: the **master** age key at `~/.config/sops/age/keys.txt` — the
operator-offline recovery anchor that decrypts every app's `*.secret.sops.env` (each file is also
encrypted to its own per-app key, which lives in Vault). Keep it backed up off-box.

---

## 5. The variables to swap per new site (everything else is identical)

`<app>` (namespace, all object/container names, image names, DB name/user, Vault path/role/policy) ·
registry images `container-registry.traderyolo.com/<app>-{web,migrate}` · a **free NodePort** · the
**dev web host-port** (e.g. `3013:3000`) · the **domain + TLS** + `NEXT_PUBLIC_SITE_URL` · the hostPath
`/mnt/<app>-postgres` (if durable PV) · any app-specific Vault keys beyond `DATABASE_URL`.

---

## 6. End-to-end: deploy a brand-new website from zero

1. **Scaffold the repo** from §2/§3 (swap `<app>`); create `github.com/wiqram/<app>`.
2. **Write secrets**: `cd vault && sops web.secret.sops.env` (+ `postgres.secret.sops.env`); commit the
   encrypted files. Confirm `vault/.sops.yaml` covers them.
3. **Register with the platform** — §4 steps 1–8 (Vault policy/role, Jenkins job, NodePort, NPM host, DNS,
   trigger line).
4. **Deploy**: trigger the Jenkins job (UI, or `curl …/job/<app>/build?token=<tok>`). It builds+pushes,
   `vaultSync`s secrets, then `kubectl apply`s — namespace → migrate → web.
5. **Verify**: `kubectl -n <app> get po` (web `Running`, migrate `Completed`), then `curl -sI https://your-domain.com` → `200`.
6. **Make it survivable**: if it added a `/mnt/<app>-*` hostPath, add the `mkdir -p` to
   `restore-scratch.sh` phase 3 so a bare-metal restore recreates it. The weekly backup already
   captures the new namespace's data on minikube-mnt + the new `vault/<app>-policy.hcl`.

---

## 7. Anti-patterns (things that silently break prod here)
- ❌ Putting secrets in k8s `Secret`/`ConfigMap` or a committed plaintext `.env` → use Vault + SOPS.
- ❌ Exposing the database via NodePort → DB is **ClusterIP only**.
- ❌ Hardcoding the Jenkins credential anywhere → it's `JENKINS_CRED` in the gitignored `.env`.
- ❌ Editing NPM's on-disk `*.conf` files → they're regenerated from MariaDB; use the UI/API.
- ❌ Reusing a NodePort already in `all proxy hosts.txt` → port clash, app unreachable.
- ❌ Tagged images without `imagePullPolicy: Always`, or forgetting `kubectl rollout restart` → stale `:latest`.
- ❌ An app pod not running as `serviceAccountName: vault-secrets` → Vault injector can't auth, no secrets.
- ❌ Forgetting `. /vault/secrets/config` before the app's start command → env vars never loaded.
