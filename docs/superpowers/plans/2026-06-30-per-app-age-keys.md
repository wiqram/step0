# Per-App SOPS Age Keys Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give each app its own SOPS age key (in Vault `kv/age-keys/<app>` + offline `~/.vault/age-keys/` mirror) so a Jenkins job can decrypt only its own secrets, keeping the existing shared key as an offline master recovery key (2nd recipient on every `.sops.yaml`).

**Architecture:** Additive, zero-downtime-reversible migration. The vault repo gains `gen-app-age-key.sh` (mint key → mirror + Vault), `seed-age-keys.sh` (reload mirror into a fresh Vault), a `vaultSync` change to fetch the per-app key (with master fallback during migration), and a per-app Vault policy line. Each app's `.sops.yaml` gets the per-app recipient and its secrets are re-encrypted. Pilot `bestrentaladmin` → roll out 6 → cut over (drop the master fallback + shared credential). STEP0's `restore-scratch.sh` rides existing legs (the `~/.vault` mirror is already backed up/restored; `start-vault.sh` re-seeds).

**Tech Stack:** bash, `age-keygen`, `sops`, HashiCorp Vault (via `kubectl exec` host-side; `vault` CLI in the Jenkins agent), Jenkins shared library (Groovy).

**Spec:** `docs/superpowers/specs/2026-06-30-per-app-age-keys-design.md`

**Hard facts (verified):**
- Host has **no `vault` CLI** → host scripts use `kubectl exec vault-0 -n vault -- vault …`. Root token: `jq -r .root_token ~/.vault/cluster-keys.json`, applied via `kubectl exec vault-0 -n vault --stdin -- vault login -`.
- Jenkins agent (`jenkins-inbound-agent-vik:cloud`) **has** `vault, sops, age, kubectl, jq`.
- KV v2 mount is `kv/`; data path is `kv/data/<…>`. Vault NodePort (http, tls_disable) = `http://172.16.238.2:30200`.
- Master/shared recipient = `age1jgqwj4az5kuzhq2m9077cmdr3q22zv60z86wrwql8ehvj4k0qgeskqx4nn` (stays as 2nd recipient + operator-offline at `~/.config/sops/age/keys.txt`).
- App repos with `vault/.sops.yaml`: `bestrentaladmin` (pilot), `Predictonomy`, `Predictonomy-agent`, `dyingpaleblue`, `IG-Trading-Microservices`, `ollama`, `qcguy-ghost`.
- `setup-jenkins-approle.sh` re-renders `jenkins-<app>-policy` from `jenkins-policy.hcl.tmpl` (sed `<APP>`) for every app derived from `*-policy.hcl`.

**Testing note:** This is live-infra bash touching real Vault + real deploys; it can't be unit-tested end-to-end in isolation. Per task: `bash -n` (syntax) + targeted live verification (the pilot deploy IS the integration test). Steps that mutate live Vault / trigger deploys are marked **[LIVE]** — confirm before running.

---

## File Structure

| File | Repo | Responsibility |
|---|---|---|
| `gen-app-age-key.sh` (create) | vault | Mint/rotate an app's age key → `~/.vault/age-keys/<app>.txt` + `kv/age-keys/<app>`; print recipient |
| `seed-age-keys.sh` (create) | vault | Idempotently load `~/.vault/age-keys/*` into a fresh Vault |
| `jenkins-policy.hcl.tmpl` (modify) | vault | Add `read` on `kv/data/age-keys/<APP>` |
| `vars/vaultSync.groovy` (modify) | vault | Fetch per-app key from Vault (master fallback during migration; required after cutover) |
| `start-vault.sh` (modify) | vault | Call `seed-age-keys.sh` after AppRole setup |
| `scripts/setup-jenkins-credentials.sh` (modify, cutover) | vault | Stop provisioning shared `sops-age-key` |
| `<app>/vault/.sops.yaml` (modify ×7) | app repos | Add per-app recipient (now 2) |
| `<app>/vault/*.secret.sops.env` (modify ×7) | app repos | `sops updatekeys` re-encrypt to both |
| `restore-scratch.sh` (modify) | STEP0 | `mkdir ~/.vault/age-keys` (phase 3) + handoff note |
| `base-architecture-scaffold.md`, restore spec §7 (modify) | STEP0 | Document per-app + master model |

---

## Task 1: `gen-app-age-key.sh` (vault repo)

**Files:** Create `/home/cloud/Ideaprojects/vault/gen-app-age-key.sh`

- [ ] **Step 1: Write the script**
```bash
#!/usr/bin/env bash
# gen-app-age-key.sh — mint (or rotate) an app's SOPS age key for per-app secret isolation.
# Writes the PRIVATE key to ~/.vault/age-keys/<app>.txt (0600, offline backup + re-seed source)
# AND to Vault kv/age-keys/<app> (field 'key'; operational read path for vaultSync). Prints the
# PUBLIC recipient to add (as a 2nd recipient, alongside the master) to the app's vault/.sops.yaml.
#
# Host has no vault CLI -> writes to Vault via `kubectl exec vault-0`. Idempotent unless --force.
# Usage: ./gen-app-age-key.sh <app> [--force]
set -euo pipefail

APP="${1:-}"; FORCE="${2:-}"
[ -n "$APP" ] || { echo "usage: $0 <app> [--force]" >&2; exit 2; }
command -v age-keygen >/dev/null || { echo "age-keygen not found" >&2; exit 1; }
command -v kubectl    >/dev/null || { echo "kubectl not found" >&2; exit 1; }
KEYS_FILE="${VAULT_KEYS_FILE:-$HOME/.vault/cluster-keys.json}"
[ -s "$KEYS_FILE" ] || { echo "no root token at $KEYS_FILE" >&2; exit 1; }

KEYDIR="$HOME/.vault/age-keys"; KEYFILE="$KEYDIR/$APP.txt"
mkdir -p "$KEYDIR"; chmod 700 "$KEYDIR"
if [ -f "$KEYFILE" ] && [ "$FORCE" != "--force" ]; then
  echo "key already exists: $KEYFILE (use --force to rotate)" >&2; exit 1
fi

age-keygen -o "$KEYFILE" >/dev/null 2>&1
chmod 600 "$KEYFILE"
RECIPIENT="$(age-keygen -y "$KEYFILE")"

# Authenticate the pod as root, then store the whole key file as field 'key'.
jq -r .root_token "$KEYS_FILE" | kubectl exec -i vault-0 -n vault -- vault login - >/dev/null
cat "$KEYFILE" | kubectl exec -i vault-0 -n vault -- vault kv put "kv/age-keys/$APP" key=-  >/dev/null

echo "OK: wrote private key -> $KEYFILE and kv/age-keys/$APP"
echo "Add this PUBLIC recipient to $APP's vault/.sops.yaml (alongside the master recipient):"
echo "  $RECIPIENT"
```

- [ ] **Step 2: Syntax check**
Run: `chmod +x /home/cloud/Ideaprojects/vault/gen-app-age-key.sh && bash -n /home/cloud/Ideaprojects/vault/gen-app-age-key.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Arg-guard smoke test (no Vault mutation)**
Run: `/home/cloud/Ideaprojects/vault/gen-app-age-key.sh 2>&1; echo "exit=$?"`
Expected: `usage: …` and `exit=2`.

- [ ] **Step 4: Commit** (commit at the end of Task 5 with the other mechanism files — see Task 6.)

---

## Task 2: `seed-age-keys.sh` (vault repo)

**Files:** Create `/home/cloud/Ideaprojects/vault/seed-age-keys.sh`

- [ ] **Step 1: Write the script**
```bash
#!/usr/bin/env bash
# seed-age-keys.sh — load per-app age private keys from the offline mirror
# (~/.vault/age-keys/<app>.txt) into Vault kv/age-keys/<app>. Idempotent: writes only if the
# Vault entry is ABSENT (won't clobber a rotated in-Vault key). Run on a fresh/restored Vault so
# vaultSync can fetch each app's own key. Host has no vault CLI -> uses kubectl exec vault-0.
set -euo pipefail
KEYDIR="$HOME/.vault/age-keys"
KEYS_FILE="${VAULT_KEYS_FILE:-$HOME/.vault/cluster-keys.json}"
[ -d "$KEYDIR" ] || { echo "no $KEYDIR — nothing to seed"; exit 0; }
[ -s "$KEYS_FILE" ] || { echo "no root token at $KEYS_FILE" >&2; exit 1; }
command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }

jq -r .root_token "$KEYS_FILE" | kubectl exec -i vault-0 -n vault -- vault login - >/dev/null
shopt -s nullglob
for f in "$KEYDIR"/*.txt; do
  app="$(basename "$f" .txt)"
  if kubectl exec -i vault-0 -n vault -- vault kv get "kv/age-keys/$app" >/dev/null 2>&1; then
    echo "  kv/age-keys/$app already present — skip"
  else
    cat "$f" | kubectl exec -i vault-0 -n vault -- vault kv put "kv/age-keys/$app" key=- >/dev/null \
      && echo "  seeded kv/age-keys/$app"
  fi
done
echo "seed-age-keys: done"
```

- [ ] **Step 2: Syntax check**
Run: `chmod +x /home/cloud/Ideaprojects/vault/seed-age-keys.sh && bash -n /home/cloud/Ideaprojects/vault/seed-age-keys.sh && echo OK`
Expected: `OK`

- [ ] **Step 3: Empty-dir smoke test** (rename guard — do NOT delete a real keydir)
Run: `HOME=/tmp/nokeys bash /home/cloud/Ideaprojects/vault/seed-age-keys.sh; echo "exit=$?"`
Expected: `no /tmp/nokeys/.vault/age-keys — nothing to seed` and `exit=0`.

---

## Task 3: `jenkins-policy.hcl.tmpl` — per-app age-key read (vault repo)

**Files:** Modify `/home/cloud/Ideaprojects/vault/jenkins-policy.hcl.tmpl`

- [ ] **Step 1: Append the age-key read stanza**
Add to the END of the file:
```hcl

# Read ONLY this app's own SOPS age private key (vaultSync fetches it to decrypt this
# app's secrets). Per-app isolation: jenkins-<APP> cannot read any other app's key.
path "kv/data/age-keys/<APP>" {
  capabilities = ["read"]
}
```

- [ ] **Step 2: Verify the template renders correctly for a sample app**
Run: `sed 's/<APP>/bestrentaladmin/g' /home/cloud/Ideaprojects/vault/jenkins-policy.hcl.tmpl | grep -A2 'age-keys'`
Expected: shows `path "kv/data/age-keys/bestrentaladmin" {` with `capabilities = ["read"]`.

---

## Task 4: `vaultSync.groovy` — fetch per-app key (master fallback) (vault repo)

**Files:** Modify `/home/cloud/Ideaprojects/vault/vars/vaultSync.groovy`

- [ ] **Step 1: Replace the `sh '''…'''` body (lines 39–47) to fetch the per-app key**
Replace exactly this block:
```groovy
      sh '''
        set -eu
        chmod +x .vaultSync/vault-sync.sh
        # Authenticate with this app's scoped AppRole (can only write kv/$VS_APP/*).
        VAULT_TOKEN="$(vault write -field=token auth/approle/login role_id="$VS_RID" secret_id="$VS_SID")"
        export VAULT_TOKEN
        ./.vaultSync/vault-sync.sh ${VS_PRUNE:-} --dir "$VS_DIR" "$VS_APP"
        unset VAULT_TOKEN
      '''
```
with:
```groovy
      sh '''
        set -eu
        chmod +x .vaultSync/vault-sync.sh
        # Authenticate with this app's scoped AppRole (can only write kv/$VS_APP/* and read
        # its own kv/age-keys/$VS_APP).
        VAULT_TOKEN="$(vault write -field=token auth/approle/login role_id="$VS_RID" secret_id="$VS_SID")"
        export VAULT_TOKEN
        # Per-app isolation: fetch THIS app's age key from Vault and point sops at it. During
        # migration, fall back to the master SOPS_AGE_KEY credential if the per-app key isn't
        # seeded yet. (At cutover the fallback + master credential are removed.)
        if vault kv get -field=key "kv/age-keys/$VS_APP" > .vaultSync/age.key 2>/dev/null \
           && [ -s .vaultSync/age.key ]; then
          chmod 600 .vaultSync/age.key
          export SOPS_AGE_KEY_FILE="$PWD/.vaultSync/age.key"
          echo "vaultSync: using per-app age key for $VS_APP"
        else
          echo "vaultSync: per-app key for $VS_APP not in Vault; using master sops-age-key (migration fallback)"
        fi
        ./.vaultSync/vault-sync.sh ${VS_PRUNE:-} --dir "$VS_DIR" "$VS_APP"
        rm -f .vaultSync/age.key
        unset VAULT_TOKEN
      '''
```

- [ ] **Step 2: Update the header comment (lines 9–13) to reflect the per-app key source**
Replace:
```groovy
//   - sops-age-key                (Secret text) — the age private key for sops
```
with:
```groovy
//   - sops-age-key                (Secret text) — MASTER age key, migration fallback only.
//     The per-app age key is fetched at runtime from Vault kv/age-keys/<app> (the app's own
//     AppRole can read only its own). After cutover, this shared credential is removed.
```

- [ ] **Step 3: Syntax sanity (Groovy isn't locally runnable; check the sh block parses as bash)**
Run: `awk "/sh '''/{f=1;next} /'''/{f=0} f" /home/cloud/Ideaprojects/vault/vars/vaultSync.groovy | bash -n - && echo BASH_OK`
Expected: `BASH_OK` (the extracted shell body is valid bash).

---

## Task 5: `start-vault.sh` — re-seed age keys (vault repo)

**Files:** Modify `/home/cloud/Ideaprojects/vault/start-vault.sh`

- [ ] **Step 1: Add the seed call after the AppRole-setup block**
Find the block that ends with (around line 161–162):
```bash
"$(dirname "$0")/scripts/setup-jenkins-approle.sh" || \
  echo "WARN: Jenkins AppRole setup failed; sync pipeline auth will be unavailable until re-run." >&2
```
Immediately AFTER it, add:
```bash

# Re-seed per-app SOPS age keys into Vault from the offline mirror (~/.vault/age-keys/) so
# vaultSync can fetch each app's own key. Idempotent (only writes absent entries). Best-effort:
# a failure must not abort the cluster bootstrap. (The master key in ~/.config/sops/age/keys.txt
# remains the recovery anchor and the migration fallback.)
"$(dirname "$0")/seed-age-keys.sh" || \
  echo "WARN: age-key seeding failed; per-app vaultSync falls back to the master key until re-run." >&2
```

- [ ] **Step 2: Syntax check**
Run: `bash -n /home/cloud/Ideaprojects/vault/start-vault.sh && echo OK`
Expected: `OK`

---

## Task 6: Commit + push the vault-repo mechanism

**Files:** vault repo (all of Tasks 1–5)

- [ ] **Step 1: Confirm all parse**
Run:
```bash
cd /home/cloud/Ideaprojects/vault
for f in gen-app-age-key.sh seed-age-keys.sh start-vault.sh; do bash -n "$f" && echo "OK $f"; done
sed 's/<APP>/x/g' jenkins-policy.hcl.tmpl | grep -c age-keys
```
Expected: `OK` for all three; the grep prints `1`.

- [ ] **Step 2: Commit + push**
```bash
cd /home/cloud/Ideaprojects/vault
git add gen-app-age-key.sh seed-age-keys.sh jenkins-policy.hcl.tmpl vars/vaultSync.groovy start-vault.sh
git commit -m "feat(age-keys): per-app SOPS age keys with master fallback

gen-app-age-key.sh mints an app key to ~/.vault/age-keys + kv/age-keys/<app>;
seed-age-keys.sh re-seeds a fresh Vault from the offline mirror (called by
start-vault.sh). vaultSync fetches the per-app key from Vault (master credential
fallback during migration). jenkins-<app> policy gains read on kv/data/age-keys/<app>."
git push origin "$(git branch --show-current)"
```
Expected: clean commit + push (vault repo's default branch is `main`).

---

## Task 7: PILOT — mint the `bestrentaladmin` key  **[LIVE Vault write]**

**Files:** none in git (writes `~/.vault/age-keys/bestrentaladmin.txt` + Vault). Confirm before running.

- [ ] **Step 1: Run the generator**
Run: `/home/cloud/Ideaprojects/vault/gen-app-age-key.sh bestrentaladmin`
Expected: `OK: wrote private key …` and a `age1…` recipient line. Copy the recipient.

- [ ] **Step 2: Verify both copies exist**
Run:
```bash
ls -l ~/.vault/age-keys/bestrentaladmin.txt
kubectl exec -i vault-0 -n vault -- vault kv get -field=key kv/age-keys/bestrentaladmin | grep -c 'AGE-SECRET-KEY-'
```
Expected: the file exists (mode `-rw-------`); the grep prints `1` (Vault holds the key).

---

## Task 8: PILOT — re-key `bestrentaladmin` secrets (app repo)

**Files:** Modify `/home/cloud/IdeaProjects/bestrentaladmin/vault/.sops.yaml` and re-encrypt `vault/*.secret.sops.env`

- [ ] **Step 1: Add the per-app recipient to `.sops.yaml`**
Edit `/home/cloud/IdeaProjects/bestrentaladmin/vault/.sops.yaml` — change the `age:` line from:
```yaml
    age: "age1jgqwj4az5kuzhq2m9077cmdr3q22zv60z86wrwql8ehvj4k0qgeskqx4nn"
```
to (replace `age1PERAPP…` with the recipient printed in Task 7; master stays second):
```yaml
    age: "age1PERAPP_FROM_TASK7,age1jgqwj4az5kuzhq2m9077cmdr3q22zv60z86wrwql8ehvj4k0qgeskqx4nn"
```

- [ ] **Step 2: Re-encrypt every secret file to BOTH recipients** (master key decrypts to re-encrypt)
Run:
```bash
cd /home/cloud/IdeaProjects/bestrentaladmin/vault
export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"   # master key, decrypts existing
for f in *.secret.sops.env; do sops updatekeys -y "$f"; done
```
Expected: each file reports keys updated (adds the per-app recipient).

- [ ] **Step 3: Verify both recipients are now on the file AND it still decrypts**
Run:
```bash
cd /home/cloud/IdeaProjects/bestrentaladmin/vault
grep -c 'recipient:' web.secret.sops.env          # age recipients block
SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt" sops -d web.secret.sops.env >/dev/null && echo DECRYPT_OK
SOPS_AGE_KEY_FILE=~/.vault/age-keys/bestrentaladmin.txt sops -d web.secret.sops.env >/dev/null && echo PERAPP_DECRYPT_OK
```
Expected: recipient count `2`; `DECRYPT_OK` (master) **and** `PERAPP_DECRYPT_OK` (per-app key) — both work.

- [ ] **Step 4: Commit (app repo)**
```bash
cd /home/cloud/IdeaProjects/bestrentaladmin
git add vault/.sops.yaml vault/*.secret.sops.env
git commit -m "secrets: add per-app age recipient (master retained for recovery)"
git push origin "$(git branch --show-current)"
```

---

## Task 9: PILOT — apply policy, deploy, verify, isolation-test  **[LIVE policy + deploy]**

**Files:** none in git (live Vault policy + Jenkins deploy). Confirm before running.

- [ ] **Step 1: Re-render the Jenkins policies so `jenkins-bestrentaladmin-policy` gains the age-key read**
Run: `cd /home/cloud/Ideaprojects/vault && ./scripts/setup-jenkins-approle.sh bestrentaladmin`
Expected: it writes `jenkins-bestrentaladmin-policy` (idempotent; reuses the secret_id).

- [ ] **Step 2: Confirm the policy includes the age-key read**
Run:
```bash
jq -r .root_token ~/.vault/cluster-keys.json | kubectl exec -i vault-0 -n vault -- vault login - >/dev/null
kubectl exec -i vault-0 -n vault -- vault policy read jenkins-bestrentaladmin-policy | grep -A2 age-keys
```
Expected: `path "kv/data/age-keys/bestrentaladmin"` with `read`.

- [ ] **Step 3: Trigger the deploy**
Run: `cd /home/cloud/Ideaprojects/STEP0 && JC="$(grep -E '^JENKINS_CRED=' .env | cut -d= -f2- | tr -d '"'"'"'' )"; curl -s -X POST "https://${JC}@jenkins.traderyolo.com/job/bestrentaladmin/build?token=best" -o /dev/null -w '%{http_code}\n'`
Expected: `201` (build queued).

- [ ] **Step 4: Verify the build used the per-app key + secrets synced**
Wait for the build, then check its console log for `vaultSync: using per-app age key for bestrentaladmin` (Jenkins UI), and:
```bash
kubectl -n bestrentaladmin get po
kubectl exec -i vault-0 -n vault -- vault kv get kv/bestrentaladmin/web >/dev/null && echo KV_OK
curl -sI https://admin.bestrentalltd.com | head -1
```
Expected: web pod `Running`, migrate `Completed`; `KV_OK`; HTTP `200`.

- [ ] **Step 5: Isolation test — the app's AppRole CANNOT read another app's key**
Run:
```bash
cd /home/cloud/Ideaprojects/vault
rid=$(sed -n 's/^VAULT_ROLE_ID=//p' ~/.vault/jenkins-approle/bestrentaladmin.env)
sid=$(sed -n 's/^VAULT_SECRET_ID=//p' ~/.vault/jenkins-approle/bestrentaladmin.env)
tok=$(kubectl exec -i vault-0 -n vault -- vault write -field=token auth/approle/login role_id="$rid" secret_id="$sid")
echo "own key:"   ; kubectl exec -i vault-0 -n vault -- env VAULT_TOKEN="$tok" vault kv get -field=key kv/age-keys/bestrentaladmin >/dev/null 2>&1 && echo "  READ (expected)"
echo "other key:" ; kubectl exec -i vault-0 -n vault -- env VAULT_TOKEN="$tok" vault kv get kv/age-keys/dyingpaleblue >/dev/null 2>&1 && echo "  READ (BAD!)" || echo "  DENIED (expected)"
```
Expected: own key `READ (expected)`; other key `DENIED (expected)`. **This is the core property — if `other key` reads, stop and fix the policy.**

---

## Task 10: ROLL OUT — the remaining 6 apps  **[LIVE per app]**

**Files:** per app: `<app>/vault/.sops.yaml` + `vault/*.secret.sops.env` (in each app repo)

Apps + repo paths + Jenkins build tokens:
| app (Vault/key name) | repo path | job token |
|---|---|---|
| `predictonomy` | `/home/cloud/IdeaProjects/Predictonomy` | `predict` |
| `predictonomy-agent` | `/home/cloud/IdeaProjects/Predictonomy-agent` | *(see its Jenkinsfile / job)* |
| `dyingpaleblue` | `/home/cloud/IdeaProjects/dyingpaleblue` | `dying` |
| `yolo` | `/home/cloud/IdeaProjects/IG-Trading-Microservices` | `yolo` |
| `ollama` | `/home/cloud/IdeaProjects/ollama` | `ollama` |
| `qcguy` | `/home/cloud/Ideaprojects/qcguy-ghost` | `qcguy` |

> **Note on names:** the Vault app name / `kv/<app>/` / key name must match what each Jenkinsfile passes to `vaultSync(app: '…')` (e.g. yolo's is `yolo`, not `IG-Trading-Microservices`). Confirm each repo's `Jenkinsfile` `vaultSync(app:…)` value before minting its key, and use that exact name for `gen-app-age-key.sh <name>`.

- [ ] **Step 1: For EACH app, repeat the pilot steps** (Tasks 7→8→9) with that app's name/repo/token:
  1. `gen-app-age-key.sh <app>` → copy recipient.
  2. Edit `<repo>/vault/.sops.yaml` `age:` → `"<perapp>,<master>"`; `for f in <repo>/vault/*.secret.sops.env; do SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt sops updatekeys -y "$f"; done`; verify 2 recipients + both decrypt; commit+push in that repo.
  3. `./scripts/setup-jenkins-approle.sh <app>`; confirm policy has the age-key read.
  4. Trigger its job; verify `using per-app age key`, pods healthy, site `200`.
  5. Isolation test (its AppRole denied another app's `kv/age-keys/*`).

- [ ] **Step 2: After all 6, confirm every app has its key in Vault**
Run:
```bash
jq -r .root_token ~/.vault/cluster-keys.json | kubectl exec -i vault-0 -n vault -- vault login - >/dev/null
for a in bestrentaladmin predictonomy predictonomy-agent dyingpaleblue yolo ollama qcguy; do
  printf "%-20s " "$a"
  kubectl exec -i vault-0 -n vault -- vault kv get kv/age-keys/$a >/dev/null 2>&1 && echo present || echo MISSING
done
ls ~/.vault/age-keys/
```
Expected: all 7 `present`; the mirror dir lists all 7 `.txt` files.

---

## Task 11: CUTOVER — remove the master fallback  **[LIVE]**

**Files:** Modify `vars/vaultSync.groovy`, `scripts/setup-jenkins-credentials.sh` (vault repo)

- [ ] **Step 1: Make the per-app key REQUIRED in `vaultSync.groovy`**
Remove the master credential binding — delete this line (was line 36):
```groovy
    string(credentialsId: 'sops-age-key',                variable: 'SOPS_AGE_KEY'),
```
And replace the per-app fetch's `else` fallback branch with a hard failure:
```groovy
        if vault kv get -field=key "kv/age-keys/$VS_APP" > .vaultSync/age.key 2>/dev/null \
           && [ -s .vaultSync/age.key ]; then
          chmod 600 .vaultSync/age.key
          export SOPS_AGE_KEY_FILE="$PWD/.vaultSync/age.key"
          echo "vaultSync: using per-app age key for $VS_APP"
        else
          echo "vaultSync: FATAL — no per-app age key at kv/age-keys/$VS_APP" >&2
          exit 1
        fi
```

- [ ] **Step 2: Stop provisioning the shared `sops-age-key` credential**
In `scripts/setup-jenkins-credentials.sh`, replace the block (lines ~64–70):
```bash
if [ -r "$AGE_KEY_FILE" ] && AGE_KEY=$(grep '^AGE-SECRET-KEY-' "$AGE_KEY_FILE") && [ -n "$AGE_KEY" ]; then
  put_string_cred "sops-age-key" "age private key for SOPS (vaultSync)" "$AGE_KEY"
else
  echo "  WARN: no age key at $AGE_KEY_FILE — skipping sops-age-key credential"
fi
```
with:
```bash
# Per-app age keys (post-cutover): vaultSync fetches each app's key from Vault kv/age-keys/<app>.
# The shared sops-age-key credential is intentionally NOT provisioned anymore; the master key
# stays operator-offline at ~/.config/sops/age/keys.txt as the recovery anchor only.
echo "  (per-app age keys in Vault — not provisioning the shared sops-age-key credential)"
```

- [ ] **Step 3: Delete the now-unused Jenkins credential**
Run (via the Jenkins API, like the rotation did):
```bash
cd /home/cloud/Ideaprojects/STEP0
JC="$(grep -E '^JENKINS_CRED=' .env | cut -d= -f2- | tr -d '"'"'"'' )"; JURL="http://172.16.238.2:30380"
CR=$(curl -s -u "$JC" "$JURL/crumbIssuer/api/json"); CB=$(echo "$CR"|jq -r .crumb); FD=$(echo "$CR"|jq -r .crumbRequestField)
curl -s -u "$JC" -H "$FD:$CB" -X POST "$JURL/credentials/store/system/domain/_/credential/sops-age-key/doDelete" -o /dev/null -w '%{http_code}\n'
```
Expected: `302`/`200` (deleted). (If the credential id differs, list with `…/credentials/store/system/domain/_/api/json?tree=credentials[id]`.)

- [ ] **Step 4: Syntax + verify a deploy still works on per-app key only**
Run: `cd /home/cloud/Ideaprojects/vault && awk "/sh '''/{f=1;next} /'''/{f=0} f" vars/vaultSync.groovy | bash -n - && echo BASH_OK && bash -n scripts/setup-jenkins-credentials.sh && echo SH_OK`
Then re-trigger one app (e.g. bestrentaladmin) and confirm the build logs `using per-app age key` and the site stays `200`. Expected: `BASH_OK`, `SH_OK`, build green.

- [ ] **Step 5: Commit + push (vault repo)**
```bash
cd /home/cloud/Ideaprojects/vault
git add vars/vaultSync.groovy scripts/setup-jenkins-credentials.sh
git commit -m "feat(age-keys): cut over to per-app keys only (drop shared sops-age-key)

vaultSync now requires the per-app key from Vault (no master fallback); the shared
sops-age-key Jenkins credential is no longer provisioned and was deleted. Master key
remains operator-offline at ~/.config/sops/age/keys.txt as the recovery anchor."
git push origin "$(git branch --show-current)"
```

---

## Task 12: Reflect in STEP0 (restore + docs)

**Files:** Modify `restore-scratch.sh`, `base-architecture-scaffold.md`, `docs/superpowers/specs/2026-06-30-restore-scratch-design.md` (STEP0)

- [ ] **Step 1: `restore-scratch.sh` phase 3 — pre-create the mirror dir**
In `restore-scratch.sh`, in `phase3_dirs()`, after the existing `mkdir` lines add:
```bash
  run "mkdir -p '$HOME/.vault/age-keys' && chmod 700 '$HOME/.vault/age-keys'"
```
(It's normally restored by phase 4a, but pre-creating it makes the seed path robust even if the backup predates per-app keys.)

- [ ] **Step 2: `restore-scratch.sh` phase 9 — handoff note**
In the phase-9 `DONE` banner, after the Jenkins-credential note, add a line:
```
  Per-app SOPS age keys: restored with Vault storage; on a fresh Vault, start-vault.sh
  re-seeds them from ~/.vault/age-keys/. Master key (~/.config/sops/age/keys.txt) is the
  recovery anchor — keep it backed up off-box.
```

- [ ] **Step 3: Update `base-architecture-scaffold.md` §3.5 (vault/) for the new model**
Replace the single-recipient `.sops.yaml` example with the two-recipient form and add the onboarding step:
```markdown
# vault/.sops.yaml — TWO recipients: this app's own key + the master recovery key
creation_rules:
  - path_regex: \.secret(\.sops)?\.env$
    age: "age1<this-app>,age1jgqwj4az5kuzhq2m9077cmdr3q22zv60z86wrwql8ehvj4k0qgeskqx4nn"
    unencrypted_regex: "^(#.*)?$"
```
And in the §4 platform-registration table, add a row before the NodePort row:
```markdown
| **App age key** | `~/Ideaprojects/vault` → `./gen-app-age-key.sh <app>` | Mints the app's key to `~/.vault/age-keys/<app>.txt` + `kv/age-keys/<app>`; paste the printed recipient into the app's `vault/.sops.yaml` (as the 1st of two recipients). `jenkins-<app>` policy auto-gains read on `kv/data/age-keys/<app>`. |
```

- [ ] **Step 4: Update restore spec §7** — change the existing Jenkins/age note to mention per-app keys ride Vault storage + the `~/.vault/age-keys` mirror + `seed-age-keys.sh`.

- [ ] **Step 5: Verify + commit + push (STEP0)**
```bash
cd /home/cloud/Ideaprojects/STEP0
bash -n restore-scratch.sh && echo OK
./restore-scratch.sh --dry-run --from-phase 0 2>&1 | grep -cE 'PHASE [0-9]'   # expect 10
git add restore-scratch.sh base-architecture-scaffold.md docs/superpowers/specs/2026-06-30-restore-scratch-design.md
git commit -m "docs+restore: reflect per-app age keys (mirror re-seed, scaffold, restore note)"
git push origin master
```
Expected: `OK`, phase count `10`, clean push.

---

## Self-Review (completed by plan author)

- **Spec coverage:** mechanism (spec §5.1) → Tasks 1–6; per-app key model + decrypt flow (§4.1–4.2) → Tasks 4,7,8; authorization (§4.3) → Task 3,9; migration pilot/rollout/cutover (§6) → Tasks 7–11; restore + docs (§5.3) → Task 12. Master-fallback-then-remove (§4.2) → Tasks 4 + 11. ✔
- **Placeholder scan:** all code is concrete; `<app>`/`<APP>`/`age1PERAPP…`/`age1<this-app>` are intentional per-app substitution markers explained in-place. `predictonomy-agent`'s job token is marked to confirm from its Jenkinsfile (not invented). ✔
- **Naming consistency:** `kv/age-keys/<app>` (data path `kv/data/age-keys/<app>`), field `key`, `~/.vault/age-keys/<app>.txt`, `SOPS_AGE_KEY_FILE`, `gen-app-age-key.sh`, `seed-age-keys.sh` used identically across tasks. The Vault app name = the `vaultSync(app:…)` value (flagged for yolo). ✔
- **Reversibility:** every `.sops.yaml` keeps the master recipient through Task 10; cutover (Task 11) is the only point isolation completes, and is itself revertible by re-adding the `sops-age-key` binding. ✔
- **Restore:** Task 12 ties the mirror into phase 3/9; `seed-age-keys.sh` (Task 2) is called by `start-vault.sh` (Task 5) which restore runs in phase 6. ✔
