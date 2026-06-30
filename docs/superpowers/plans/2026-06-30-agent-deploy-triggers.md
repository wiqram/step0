# Agent Deploy Triggers Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the autonomous project agents (yolo, predictonomy, dyingpaleblue) assemble their Jenkins `JENKINS_DEPLOY_URL` fresh from the central `STEP0/.env` `JENKINS_CRED` + a job manifest, so autonomous deploys survive token rotations and bare-metal restores with zero manual steps.

**Architecture:** A `jenkins-jobs.manifest` (app→job/endpoint/token) + a `jenkins-deploy-url.sh <app>` helper that prints the assembled URL. `trigger-app-builds.sh` is refactored to drive from the manifest. `seed-agent-deploy-urls.sh` writes a **secret-free** pointer (`JENKINS_DEPLOY_URL="$(…/jenkins-deploy-url.sh <app>)"`) into each agent's sourced config file — both the immediate fix and the restore re-arm.

**Tech Stack:** bash, curl, Jenkins remote-build-trigger API.

**Spec:** `docs/superpowers/specs/2026-06-30-agent-deploy-triggers-design.md`

**Hard facts (verified):**
- `JENKINS_CRED` (`user:token`) lives in `STEP0/.env` (gitignored), read by `grep -E '^JENKINS_CRED=' | cut -d= -f2- | tr -d quotes` (same as `cluster-autostart.sh`/`trigger-app-builds.sh`).
- All 3 agents `source` their config: `set -a; . <file> 2>/dev/null; set +a` — so a `JENKINS_DEPLOY_URL="$(cmd)"` line evaluates at load.
- Agent config files (all gitignored `.env`-style): yolo → `IG-Trading-Microservices/Vault-Secrets-NO-GIT-COMMIT/jenkins-deploy-url.txt` (comments + `JENKINS_DEPLOY_URL=`); predictonomy → `Predictonomy/.env` (`JENKINS_DEPLOY_URL`,`AGENT_PERMISSION_MODE`,`NTFY_URL`); dyingpaleblue → `dyingpaleblue/.env` (does **not** exist yet).
- yolo's job `trading-microservices` is **parameterised** → `buildWithParameters`; the others use `build`.
- Agents are **disarmed by default** (`AGENT_PERMISSION_MODE` unset → won't launch). This plan only supplies the deploy URL; arming stays the operator's separate choice.

**Testing note:** bash infra; `shellcheck` is NOT installed (use `bash -n`). The helper is pure enough for a real unit test (overridable env/manifest). Seed + live verification are checked without triggering real deploys (resolve the URL + `whoAmI` auth check, not a POST).

---

## File Structure

| File | Repo | Responsibility |
|---|---|---|
| `jenkins-jobs.manifest` (create) | STEP0 | `app job endpoint token` — single source of truth |
| `jenkins-deploy-url.sh` (create) | STEP0 | print assembled URL for `<app>` from `.env` + manifest |
| `tests/test-jenkins-deploy-url.sh` (create) | STEP0 | unit test for the helper |
| `trigger-app-builds.sh` (modify) | STEP0 | drive from the manifest via the helper |
| `seed-agent-deploy-urls.sh` (create) | STEP0 | write the secret-free pointer into each agent's config |
| `restore-scratch.sh` (modify) | STEP0 | phase 8 calls the seed script; phase 9 note |
| agent config files (written by seed) | app repos | `JENKINS_DEPLOY_URL="$(…)"` pointer |

---

## Task 1: manifest + `jenkins-deploy-url.sh` helper + unit test (TDD)

**Files:** Create `STEP0/jenkins-jobs.manifest`, `STEP0/jenkins-deploy-url.sh`, `STEP0/tests/test-jenkins-deploy-url.sh`

- [ ] **Step 1: Write the manifest** `/home/cloud/Ideaprojects/STEP0/jenkins-jobs.manifest`
```
# app              job                    endpoint             build-token
# (endpoint: build | buildWithParameters — yolo's job is parameterised)
qcguy            qcguy                  build                qcguy
predictonomy     predictonomy           build                predict
bestrentaladmin  bestrentaladmin        build                best
dyingpaleblue    dyingpaleblue          build                dying
ollama           ollama                 build                ollama
yolo             trading-microservices  buildWithParameters  yolo
```

- [ ] **Step 2: Write the failing test** `tests/test-jenkins-deploy-url.sh`
```bash
#!/bin/bash
# Unit test for jenkins-deploy-url.sh (overridable env + manifest, no live Jenkins).
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../jenkins-deploy-url.sh"
tmp="$(mktemp -d)"
printf 'JENKINS_CRED=user:tok123\n' > "$tmp/.env"
printf 'yolo trading-microservices buildWithParameters yolo\npredictonomy predictonomy build predict\n' > "$tmp/m"
run(){ JENKINS_DEPLOY_ENV="$tmp/.env" JENKINS_DEPLOY_MANIFEST="$tmp/m" bash "$SCRIPT" "$1" 2>/dev/null; }
fail=0
[ "$(run yolo)" = "https://user:tok123@jenkins.traderyolo.com/job/trading-microservices/buildWithParameters?token=yolo" ] && echo "ok: yolo" || { echo "FAIL yolo: [$(run yolo)]"; fail=1; }
[ "$(run predictonomy)" = "https://user:tok123@jenkins.traderyolo.com/job/predictonomy/build?token=predict" ] && echo "ok: predictonomy" || { echo "FAIL predictonomy"; fail=1; }
run nope >/dev/null 2>&1 && { echo "FAIL: unknown app should error"; fail=1; } || echo "ok: unknown app errors"
JENKINS_DEPLOY_ENV="$tmp/none" JENKINS_DEPLOY_MANIFEST="$tmp/m" bash "$SCRIPT" yolo >/dev/null 2>&1 && { echo "FAIL: missing cred should error"; fail=1; } || echo "ok: missing cred errors"
rm -rf "$tmp"; exit $fail
```

- [ ] **Step 3: Run it, confirm it FAILS** (no helper yet)
Run: `bash /home/cloud/Ideaprojects/STEP0/tests/test-jenkins-deploy-url.sh; echo "exit=$?"`
Expected: errors / `exit=1` (script not found).

- [ ] **Step 4: Implement** `jenkins-deploy-url.sh`
```bash
#!/bin/bash
# jenkins-deploy-url.sh <app> — print the Jenkins remote-build-trigger URL for <app>,
# assembled from the central credential (STEP0/.env JENKINS_CRED) + jenkins-jobs.manifest.
# Prints ONLY the URL to stdout (for capture into $JENKINS_DEPLOY_URL); never logs it.
# Rotation-proof: the token lives once in .env, so a rotation needs no per-repo edits.
set -eu
app="${1:-}"
[ -n "$app" ] || { echo "usage: $0 <app>" >&2; exit 2; }
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${JENKINS_DEPLOY_ENV:-$SELFDIR/.env}"
MANIFEST="${JENKINS_DEPLOY_MANIFEST:-$SELFDIR/jenkins-jobs.manifest}"
cred="$(grep -E '^JENKINS_CRED=' "$ENV_FILE" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )"
[ -n "$cred" ] || { echo "jenkins-deploy-url: JENKINS_CRED not found in $ENV_FILE" >&2; exit 1; }
# Manifest row: app job endpoint token  (ignore comments/blank lines)
read -r _ job endpoint token < <(awk -v a="$app" '!/^#/ && $1==a {print; exit}' "$MANIFEST" 2>/dev/null)
[ -n "${job:-}" ] && [ -n "${endpoint:-}" ] && [ -n "${token:-}" ] || { echo "jenkins-deploy-url: no manifest entry for '$app'" >&2; exit 1; }
printf 'https://%s@jenkins.traderyolo.com/job/%s/%s?token=%s\n' "$cred" "$job" "$endpoint" "$token"
```

- [ ] **Step 5: Run the test, confirm it PASSES**
Run: `chmod +x /home/cloud/Ideaprojects/STEP0/jenkins-deploy-url.sh && bash /home/cloud/Ideaprojects/STEP0/tests/test-jenkins-deploy-url.sh; echo "exit=$?"`
Expected: all `ok:` lines, `exit=0`.

- [ ] **Step 6: Real-cred smoke (masked — confirms current token, not 117c6b)**
Run: `cd /home/cloud/Ideaprojects/STEP0 && ./jenkins-deploy-url.sh yolo | sed -E 's#//[^@]*@#//<cred>@#'`
Expected: `https://<cred>@jenkins.traderyolo.com/job/trading-microservices/buildWithParameters?token=yolo`. Also: `./jenkins-deploy-url.sh yolo | grep -c 117c6b563ff409adc59ecbfbbd2f795392` → `0`.

- [ ] **Step 7: Commit**
```bash
cd /home/cloud/Ideaprojects/STEP0
git add jenkins-jobs.manifest jenkins-deploy-url.sh tests/test-jenkins-deploy-url.sh
git commit -m "feat: jenkins-jobs.manifest + jenkins-deploy-url.sh (assemble trigger URL from central cred)"
```

---

## Task 2: refactor `trigger-app-builds.sh` to use the manifest

**Files:** Modify `/home/cloud/Ideaprojects/STEP0/trigger-app-builds.sh`

- [ ] **Step 1: Replace the per-app inline curls with manifest-driven triggers**
Replace the body **below the header comment** (from the `SELFDIR=`/`JENKINS_CRED=`/`JENKINS=` block through the final `echo "trigger-app-builds: all app build jobs triggered."`) with:
```bash
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Trigger one app's Jenkins job using the assembled URL (handles build vs
# buildWithParameters per jenkins-jobs.manifest). Best-effort.
trigger() {
  echo "building $1"
  curl -X POST "$("$SELFDIR/jenkins-deploy-url.sh" "$1")"
}

trigger qcguy
trigger predictonomy
trigger bestrentaladmin
trigger dyingpaleblue
trigger ollama

echo "building yolo pipeline but before that sleeping for 1 min"
sleep 1m
trigger yolo

echo "trigger-app-builds: all app build jobs triggered."
```
(Keep the existing top-of-file header comment block. This removes the inline `JENKINS_CRED`/`JENKINS` assembly — it now lives in the helper.)

- [ ] **Step 2: Syntax check + confirm 6 apps + yolo via buildWithParameters**
Run:
```bash
cd /home/cloud/Ideaprojects/STEP0
bash -n trigger-app-builds.sh && echo SYNTAX_OK
grep -c '^trigger ' trigger-app-builds.sh          # expect 6
./jenkins-deploy-url.sh yolo | grep -c buildWithParameters   # expect 1
```
Expected: `SYNTAX_OK`; `6`; `1`.

- [ ] **Step 3: Commit**
```bash
git add trigger-app-builds.sh
git commit -m "refactor(trigger): drive trigger-app-builds.sh from jenkins-jobs.manifest"
```

---

## Task 3: `seed-agent-deploy-urls.sh`

**Files:** Create `/home/cloud/Ideaprojects/STEP0/seed-agent-deploy-urls.sh`

- [ ] **Step 1: Write the script**
```bash
#!/bin/bash
# seed-agent-deploy-urls.sh — write a SECRET-FREE pointer into each autonomous agent's
# sourced config so it assembles JENKINS_DEPLOY_URL fresh from the central credential:
#   JENKINS_DEPLOY_URL="$(STEP0/jenkins-deploy-url.sh <app>)"
# Replaces only the JENKINS_DEPLOY_URL line (preserves AGENT_PERMISSION_MODE/NTFY_URL/comments);
# creates the file if absent. Idempotent. Run after a token rotation is NOT needed (the pointer
# re-assembles), but run it to (a) fix stale baked URLs now and (b) re-arm agents after a restore.
# NOTE: agents stay DISARMED until the operator sets AGENT_PERMISSION_MODE — this only supplies the URL.
set -eu
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$SELFDIR/jenkins-deploy-url.sh"

# app  ->  the config file its run-cycle.sh sources
seed_one() {
  local app="$1" target="$2"
  local pointer="JENKINS_DEPLOY_URL=\"\$($HELPER $app)\""
  mkdir -p "$(dirname "$target")"
  local tmp; tmp="$(mktemp)"
  if [ -f "$target" ]; then grep -v '^JENKINS_DEPLOY_URL=' "$target" > "$tmp" || true; fi
  printf '%s\n' "$pointer" >> "$tmp"
  mv "$tmp" "$target"; chmod 600 "$target"
  echo "  seeded $app -> ${target/#$HOME/\~}"
}

seed_one yolo          "/home/cloud/IdeaProjects/IG-Trading-Microservices/Vault-Secrets-NO-GIT-COMMIT/jenkins-deploy-url.txt"
seed_one predictonomy  "/home/cloud/IdeaProjects/Predictonomy/.env"
seed_one dyingpaleblue "/home/cloud/IdeaProjects/dyingpaleblue/.env"
echo "seed-agent-deploy-urls: done (agents stay disarmed until AGENT_PERMISSION_MODE is set)."
```

- [ ] **Step 2: Syntax check**
Run: `chmod +x /home/cloud/Ideaprojects/STEP0/seed-agent-deploy-urls.sh && bash -n /home/cloud/Ideaprojects/STEP0/seed-agent-deploy-urls.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Commit**
```bash
cd /home/cloud/Ideaprojects/STEP0
git add seed-agent-deploy-urls.sh
git commit -m "feat: seed-agent-deploy-urls.sh — secret-free JENKINS_DEPLOY_URL pointer per agent"
```

---

## Task 4: run the seed (immediate fix) + verify  **[LIVE — writes agent config files]**

**Files:** writes the 3 agent config files (gitignored). No deploy is triggered.

- [ ] **Step 1: Run the seed**
Run: `/home/cloud/Ideaprojects/STEP0/seed-agent-deploy-urls.sh`
Expected: three `seeded …` lines + done.

- [ ] **Step 2: Each agent resolves a CURRENT, correct URL (no deploy POST)**
Run:
```bash
for app in yolo predictonomy dyingpaleblue; do
  case $app in
    yolo) f=/home/cloud/IdeaProjects/IG-Trading-Microservices/Vault-Secrets-NO-GIT-COMMIT/jenkins-deploy-url.txt ;;
    predictonomy) f=/home/cloud/IdeaProjects/Predictonomy/.env ;;
    dyingpaleblue) f=/home/cloud/IdeaProjects/dyingpaleblue/.env ;;
  esac
  ( set -a; . "$f" 2>/dev/null; set +a
    masked=$(printf '%s' "${JENKINS_DEPLOY_URL:-}" | sed -E 's#//[^@]*@#//<cred>@#')
    stale=$(printf '%s' "${JENKINS_DEPLOY_URL:-}" | grep -c 117c6b563ff409adc59ecbfbbd2f795392)
    echo "$app: $masked  (stale-token=$stale)" )
done
```
Expected: each prints the assembled URL (predictonomy `…/predictonomy/build?token=predict`, dyingpaleblue `…/dyingpaleblue/build?token=dying`, yolo `…/trading-microservices/buildWithParameters?token=yolo`), all with `stale-token=0`.

- [ ] **Step 3: Confirm the credential authenticates (whoAmI, not a build POST)**
Run:
```bash
JC="$(grep -E '^JENKINS_CRED=' /home/cloud/Ideaprojects/STEP0/.env | cut -d= -f2- | tr -d '"'"'"'' )"
curl -s -u "$JC" "http://172.16.238.2:30380/whoAmI/api/json?tree=authenticated,name"
```
Expected: `{"_class":"hudson.security.WhoAmI","authenticated":true,"name":"private-cloud"}`.

- [ ] **Step 4: Preserved other config (predictonomy keeps its other keys)**
Run: `sed -E 's/=.*/=<redacted>/' /home/cloud/IdeaProjects/Predictonomy/.env`
Expected: still lists `AGENT_PERMISSION_MODE` and `NTFY_URL` plus the new `JENKINS_DEPLOY_URL` line.

(No commit — the seeded files are gitignored. The agents will now self-deploy on their next cycle.)

---

## Task 5: restore wiring + docs

**Files:** Modify `/home/cloud/Ideaprojects/STEP0/restore-scratch.sh`; brief note in `base-architecture-scaffold.md`

- [ ] **Step 1: Call the seed in restore phase 8 (after repos are cloned in phase 5)**
In `restore-scratch.sh` `phase8_automation()`, just before its `mark_phase 8`, add:
```bash
  # Re-arm autonomous agents' deploy URL pointers from the restored central credential
  # (the agent repos were cloned in phase 5; their gitignored .env is not in the backup).
  run "'$SCRIPT_DIR/seed-agent-deploy-urls.sh' || true"
```

- [ ] **Step 2: Phase 9 handoff note**
In the phase-9 `DONE` banner, after the per-app age-keys line, add:
```
  6. Autonomous agents (yolo/predictonomy/dyingpaleblue): deploy URLs were re-armed from the
     central JENKINS_CRED. They stay DISARMED until you set AGENT_PERMISSION_MODE in each
     agent's .env. To re-arm manually: ./seed-agent-deploy-urls.sh
```

- [ ] **Step 3: Syntax + dry-run still walks 10 phases**
Run: `cd /home/cloud/Ideaprojects/STEP0 && bash -n restore-scratch.sh && echo OK && ./restore-scratch.sh --dry-run --from-phase 0 2>&1 | grep -cE 'PHASE [0-9]'`
Expected: `OK`, `10`.

- [ ] **Step 4: Note in base-architecture-scaffold.md §4 (cold-boot trigger row)**
Append to the "Cold-boot build trigger" row's cell: ` New apps: add a line to STEP0/jenkins-jobs.manifest (app job endpoint token); agents assemble JENKINS_DEPLOY_URL via STEP0/jenkins-deploy-url.sh — never store the token per-repo.`

- [ ] **Step 5: Commit + push everything**
```bash
cd /home/cloud/Ideaprojects/STEP0
git add restore-scratch.sh base-architecture-scaffold.md
git commit -m "restore+docs: re-arm agent deploy URLs on restore; manifest onboarding note"
git push origin master
```

---

## Self-Review (completed by plan author)

- **Spec coverage:** manifest (§3.1)→T1; helper (§3.2)→T1; trigger-app-builds refactor (§3.3)→T2; seed script (§3.4)→T3; immediate fix (§1, §6)→T4; restore wiring (§4, §7.6)→T5; onboarding doc→T5. ✔
- **Placeholder scan:** all code complete; `<app>`/`<cred>` are intentional masks/markers. No TBD. ✔
- **Naming consistency:** `jenkins-jobs.manifest`, `jenkins-deploy-url.sh`, `JENKINS_DEPLOY_ENV`/`JENKINS_DEPLOY_MANIFEST` (test overrides), `seed-agent-deploy-urls.sh`, `JENKINS_DEPLOY_URL` used identically across tasks; manifest columns `app job endpoint token` consistent. ✔
- **Safety:** verification never POSTs a build (resolve URL + whoAmI only); agents stay disarmed (no `AGENT_PERMISSION_MODE`); seeded files are gitignored + secret-free. ✔
- **Rotation/restore:** token only in `STEP0/.env`; helper/manifest/seed in STEP0 (backed up + restored); phase-8 re-arm covers a fresh box. ✔
