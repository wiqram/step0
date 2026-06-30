# Design: rotation-proof, restore-proof autonomous-deploy triggers for project agents

**Date:** 2026-06-30
**Status:** Approved (design), pending implementation plan
**Scope:** STEP0 (manifest + helper + seed script + trigger-app-builds refactor) and the 3 agent
repos' gitignored deploy config (yolo, predictonomy, dyingpaleblue)

## 1. Purpose

The autonomous project agents (`ops/agent/run-cycle.sh` in yolo, predictonomy, dyingpaleblue)
deploy by `curl -fsS -X POST "$JENKINS_DEPLOY_URL"` after pushing — so the operator doesn't have
to trigger Jenkins manually. Today each stores the **full URL with the Jenkins API token baked in**
(yolo: `Vault-Secrets-NO-GIT-COMMIT/jenkins-deploy-url.txt`; predictonomy: `.env`). Two problems:

1. **The token was rotated 2026-06-30** → every stored URL holds the **dead** token (`117c6b…`) →
   all agent deploys currently 401. (dyingpaleblue has no `.env` at all → it never deploys.)
2. Baking the token into N per-repo files is the same secret-sprawl that made rotation break things.

Goal: each agent always has a **current, correct** trigger URL with zero manual steps — surviving
token rotations and bare-metal restores.

## 2. Approach (confirmed): assemble from the central credential

The per-repo "deploy URL" stops being a baked secret and becomes a **secret-free pointer** that
assembles the URL fresh from the **one** central credential (`STEP0/.env` `JENKINS_CRED`, already
backed up + restored) plus a per-app job/endpoint/token manifest. One token copy; a rotation updates
one place; every agent stays working.

## 3. Components

### 3.1 `STEP0/jenkins-jobs.manifest` (new) — single source of truth
Lines `app job endpoint token` (endpoint is `build` or `buildWithParameters`):
```
qcguy            qcguy                  build                qcguy
predictonomy     predictonomy           build                predict
bestrentaladmin  bestrentaladmin        build                best
dyingpaleblue    dyingpaleblue          build                dying
ollama           ollama                 build                ollama
yolo             trading-microservices  buildWithParameters  yolo
```
This is the only place that knows each app's job/endpoint/token. Non-secret (the `?token=` build
token is a low-value per-job trigger token, not the API credential) → committed.

### 3.2 `STEP0/jenkins-deploy-url.sh <app>` (new) — the assembler
- Reads `JENKINS_CRED` from `STEP0/.env` (same grep pattern `cluster-autostart.sh`/`trigger-app-builds.sh`
  use) and the app's row from `jenkins-jobs.manifest`.
- **Prints** `https://${JENKINS_CRED}@jenkins.traderyolo.com/job/<job>/<endpoint>?token=<token>` to
  stdout — and nothing else. The URL goes only to stdout for capture; the script never logs it.
- Errors (unknown app, missing `JENKINS_CRED`) go to stderr with a non-zero exit, no partial URL.

### 3.3 `STEP0/trigger-app-builds.sh` (refactor) — drive from the manifest
Replace the per-app hardcoded `curl`s with a loop over the manifest that POSTs
`jenkins-deploy-url.sh <app>` per app (or curls the assembled URL). DRY: the `build` vs
`buildWithParameters` distinction now lives once in the manifest (fixes the class of bug that
silently skipped yolo). Behaviour preserved: same apps, same credential source, best-effort.

### 3.4 `STEP0/seed-agent-deploy-urls.sh` (new) — arm the agents (immediate fix + restore re-arm)
For each agent app, write a **secret-free pointer** into the file that agent already *sources*,
replacing the `JENKINS_DEPLOY_URL=` line in place (or appending if absent) WITHOUT clobbering other
content:
```
JENKINS_DEPLOY_URL="$(/home/cloud/Ideaprojects/STEP0/jenkins-deploy-url.sh <app>)"
```
Per-agent target files (all are `source`d by their `run-cycle.sh`, so the command substitution
evaluates at load):
| agent app | file it sources | note |
|---|---|---|
| yolo | `IG-Trading-Microservices/Vault-Secrets-NO-GIT-COMMIT/jenkins-deploy-url.txt` | replace whole file (it only holds the deploy URL ± NTFY) — preserve any `NTFY_URL` line |
| predictonomy | `Predictonomy/.env` | replace only the `JENKINS_DEPLOY_URL=` line; keep `AGENT_PERMISSION_MODE`, `NTFY_URL`, etc. |
| dyingpaleblue | `dyingpaleblue/.env` | create the `.env` (or add the line) — it currently lacks one |
Idempotent. Running it **now** is the immediate fix (agents deploy again on the current token);
running it again after any rotation is unnecessary (the pointer re-assembles), and running it on a
restored box re-arms the agents.

## 4. Why this meets the goal

- **Rotation-proof:** the token lives once in `STEP0/.env`; agents assemble at run time, so a
  rotation (just update `.env`, as the rotation runbook already says) keeps every agent working with
  no per-repo edits.
- **Restore-proof (central pieces):** `jenkins-jobs.manifest`, `jenkins-deploy-url.sh`,
  `seed-agent-deploy-urls.sh`, and `.env` `JENKINS_CRED` all live in STEP0, which the weekly backup
  captures and `restore-scratch.sh` restores. After a rebuild, the agent repos are git-cloned and a
  single `seed-agent-deploy-urls.sh` run re-arms their deploy pointers from the restored central
  credential — zero manual URL handling.
- **No secret sprawl / never-printed:** no token in any agent repo; the helper writes the URL only to
  stdout for capture; the agents keep their existing `$JENKINS_DEPLOY_URL` + "value hidden" handling.

## 5. Out of scope
- Full restoration of the agents' *other* gitignored `.env` config (`AGENT_PERMISSION_MODE`,
  `NTFY_URL`, dry-run arming) — that's a separate agent-config concern; this feature only guarantees a
  current `JENKINS_DEPLOY_URL`. (`seed-agent-deploy-urls.sh` won't clobber those lines where present.)
- Changing the agents' `run-cycle.sh` deploy logic — only the *source* of `JENKINS_DEPLOY_URL` changes
  (file content), not how the agent uses it.
- Apps without an autonomous agent (bestrentaladmin, ollama, qcguy) — they're in the manifest for
  `trigger-app-builds.sh`/the helper, but get no agent pointer.

## 6. Verification
- `jenkins-deploy-url.sh yolo` prints a URL ending `/job/trading-microservices/buildWithParameters?token=yolo`
  with the **current** credential (masked check: not `117c6b…`).
- After `seed-agent-deploy-urls.sh`: each agent's sourced file sets `JENKINS_DEPLOY_URL` to the
  assembler one-liner; `set -a; . <file>; set +a; echo "${JENKINS_DEPLOY_URL:+set}"` → `set`, and the
  resolved URL authenticates (HTTP 201 on a real POST, or a dry `whoAmI` with the cred).
- A live agent deploy (or a manual `curl -fsS -X POST "$JENKINS_DEPLOY_URL"`) returns 201 for each of
  yolo / predictonomy / dyingpaleblue.

## 7. Deliverables
1. `STEP0/jenkins-jobs.manifest`
2. `STEP0/jenkins-deploy-url.sh`
3. `STEP0/seed-agent-deploy-urls.sh`
4. `STEP0/trigger-app-builds.sh` refactor to use the manifest
5. The 3 agent repos' deploy pointer written by the seed script (yolo break-glass file,
   predictonomy `.env`, dyingpaleblue `.env`)
6. Restore wiring note (`restore-scratch.sh` / docs): run `seed-agent-deploy-urls.sh` after repos are
   cloned.
7. This design doc.
