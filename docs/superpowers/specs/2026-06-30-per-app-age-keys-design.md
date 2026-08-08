# Design: per-app SOPS age keys with a master recovery key

**Date:** 2026-06-30
**Status:** Approved (design), pending implementation plan
**Scope:** multi-repo — `vault` repo (mechanism), 7 app repos (re-key), `STEP0` (restore + docs)

## 1. Purpose

Today **one shared age recipient** (`age1jgqwj4az5…`) encrypts every app's in-repo SOPS
secrets, and a single `sops-age-key` Jenkins credential decrypts all of them. Any app's
Jenkins deploy job (or anyone with that one key) can decrypt **every** app's secrets — no
isolation. Goal: give each app its **own** age key so a compromise of one app's repo/job
exposes only that app, while keeping a **master recovery key** so the operator can always
decrypt for local dev / break-glass and a lost per-app key is never catastrophic.

## 2. Scope decisions (confirmed)

| Decision | Choice |
|---|---|
| Recovery model | **Per-app key + master recovery key** (two recipients per app) |
| Per-app key storage | **Vault `kv/age-keys/<app>`** (operational) **+ offline mirror `~/.vault/age-keys/<app>.txt`** (backup/re-seed) |
| Migration | **Pilot one app (`bestrentaladmin`) → roll out to the other 6** |
| Master key | **Reuse the existing shared key** as the master recovery key (already a recipient everywhere + already in `~/.config/sops/age/keys.txt`) → migration is purely additive |

## 3. Why this is sound (the chicken-and-egg that isn't)

Storing the age key in Vault does **not** create a circular dependency: Jenkins bootstraps
Vault access via the **AppRole** (a Jenkins credential), *then* fetches the age key from
`kv/age-keys/<app>` as a payload. The age key is data, not an access credential. The age
encryption protects secrets **at rest in git** (the committed `*.secret.sops.env`); the
AppRole governs Vault access. Per-app age keys mean: repo-X compromise + job-X Vault access
exposes only X.

## 4. Architecture

### 4.1 Key model — two recipients per app
Each app's `vault/.sops.yaml` lists **two** age recipients:
- **Per-app key** — unique per app. Private half lives in **Vault `kv/age-keys/<app>`**
  (read only by `jenkins-<app>` AppRole) **and** mirrored offline to
  `~/.vault/age-keys/<app>.txt` (0600). Jenkins job X fetches it from Vault → decrypts only X.
- **Master recovery key** — the existing shared `age1jgqwj4az5…`. Private half stays
  **operator-offline** at `~/.config/sops/age/keys.txt` (+ secure backup). **Never** in Vault
  or Jenkins. The operator can decrypt any app; a lost per-app key is recoverable.

### 4.2 Decrypt flow (`vaultSync`)
After AppRole login, `vaultSync(app)`:
```bash
VAULT_TOKEN="$(vault write -field=token auth/approle/login role_id="$VS_RID" secret_id="$VS_SID")"
umask 077; tmpkey="$(mktemp)"
vault kv get -field=key "kv/age-keys/$VS_APP" > "$tmpkey"   # per-app key, scoped read
export SOPS_AGE_KEY_FILE="$tmpkey"
./.vaultSync/vault-sync.sh --dir "$VS_DIR" "$VS_APP"        # sops -d uses SOPS_AGE_KEY_FILE
rm -f "$tmpkey"
```
It **drops** the `sops-age-key` Jenkins-credential binding. During migration only, it keeps a
**guarded fallback**: if `kv/age-keys/$app` is absent, fall back to the master `sops-age-key`
credential (so not-yet-migrated apps keep working). The fallback is removed at cutover (Phase D).

### 4.3 Authorization
`jenkins-policy.hcl.tmpl` gains one line so each app's AppRole can read **only its own** key:
```hcl
path "kv/data/age-keys/<APP>" { capabilities = ["read"] }
```
(`<APP>` is templated per app by `setup-jenkins-approle.sh`.) The age-keys are written by the
operator/admin (onboarding) and by `seed-age-keys.sh` (bootstrap) using the root token.

## 5. Cross-repo change set

### 5.1 vault repo (`~/Ideaprojects/vault`) — the mechanism
1. **`gen-app-age-key.sh`** *(new)* — onboarding helper. `age-keygen` → write private to
   `~/.vault/age-keys/<app>.txt` (0600) and `vault kv put kv/age-keys/<app> key=@<file>`; print
   the `# public key: age1…` recipient for the operator to paste into the app's `.sops.yaml`.
   Idempotent (won't overwrite an existing key unless `--force`).
2. **`seed-age-keys.sh`** *(new)* — for each `~/.vault/age-keys/<app>.txt`, `vault kv put
   kv/age-keys/<app> key=@<file>` **only if absent** (idempotent re-seed on a fresh Vault).
   Standalone + called by `start-vault.sh`.
3. **`vars/vaultSync.groovy`** — implement §4.2 (fetch per-app key from Vault; guarded master
   fallback during migration; drop the unconditional `sops-age-key` binding).
4. **`jenkins-policy.hcl.tmpl`** — add the `kv/data/age-keys/<APP>` read line (§4.3).
5. **`start-vault.sh`** — ensure the `kv` mount has the `age-keys/` path conceptually (KV v2
   needs no pre-create) and **call `seed-age-keys.sh`** after Vault is unsealed/configured.
6. **`scripts/setup-jenkins-credentials.sh`** — after cutover, stop provisioning the shared
   `sops-age-key` (during pilot it stays as the fallback).
7. **`README.md` / onboarding** — document `gen-app-age-key.sh` + the two-recipient `.sops.yaml`.

### 5.2 app repos (×7) — re-key (pilot `bestrentaladmin` first, then the rest)
Apps: `bestrentaladmin` (pilot), then `Predictonomy`, `Predictonomy-agent`, `dyingpaleblue`,
`IG-Trading-Microservices` (yolo), `ollama`, `qcguy-ghost`.
Per app:
- `vault/.sops.yaml` — add the per-app recipient (now **two** recipients: per-app + master).
- `sops updatekeys vault/<group>.secret.sops.env` for each encrypted file → re-encrypts to both
  recipients (no plaintext change). Commit the re-encrypted files + `.sops.yaml`.

### 5.3 STEP0 — restore + docs
- **`restore-scratch.sh`** — `~/.vault/age-keys/` is restored wholesale by phase 4a (it `cp -a`s
  `~/.vault`), so per-app keys' offline mirror returns automatically; `start-vault.sh` (phase 6)
  re-seeds them into a fresh Vault via `seed-age-keys.sh`. Add a phase-3 `mkdir -p
  ~/.vault/age-keys` (belt-and-suspenders) and a phase-9 handoff line noting per-app keys
  re-seed from the offline mirror. No structural change — the design rides existing restore legs.
- **Spec/docs** — `docs/.../2026-06-30-restore-scratch-design.md` §7 gains an age-keys note;
  **`docs/base-architecture-scaffold.md`** vault/ section updated: two-recipient `.sops.yaml`, the
  `gen-app-age-key.sh` onboarding step, and the `kv/data/age-keys/<app>` policy line.

## 6. Implementation sequence (pilot → roll out → cut over)

- **Phase A — mechanism** (vault repo, §5.1 items 1–5,7). Verify scripts with `bash -n` and a
  dry `gen-app-age-key.sh --help`. `vaultSync` keeps the master fallback.
- **Phase B — pilot `bestrentaladmin`**: `gen-app-age-key.sh bestrentaladmin` → add recipient to
  its `.sops.yaml` → `sops updatekeys` → commit → `seed-age-keys.sh` → trigger its Jenkins
  deploy. **Verify:** vaultSync logs "using per-app key"; `kv/bestrentaladmin/*` repopulates;
  pods `Running`; `curl -sI https://<domain>` → `200`. **Isolation test:** with
  `bestrentaladmin`'s AppRole token, `vault kv get kv/age-keys/dyingpaleblue` → **denied**.
- **Phase C — roll out** the other 6 (same per-app steps), one deploy at a time, verifying each.
- **Phase D — cut over**: remove the master fallback from `vaultSync.groovy`; remove the shared
  `sops-age-key` provisioning from `setup-jenkins-credentials.sh` and delete the Jenkins
  credential. Master now lives **only** operator-offline.
- **Phase E — reflect in STEP0**: restore-scratch note + scaffold/spec doc updates; run
  `restore-scratch.sh --dry-run` to confirm it still parses and walks all phases.

## 7. Verification & rollback

- **Per-app correctness:** each migrated app's deploy decrypts via its own key (vaultSync log),
  `kv/<app>/*` repopulates, pods healthy, site returns `200`.
- **Isolation:** app X's AppRole token is **denied** `kv/age-keys/<Y>` (the core property).
- **Restore:** on a normal restore, per-app keys return with Vault storage; on a fresh-Vault
  rebuild, `seed-age-keys.sh` reloads them from the restored `~/.vault/age-keys/` mirror; the
  master key (restored to `~/.config/sops/age/keys.txt`) is the ultimate anchor.
- **Rollback (any point before Phase D):** every `.sops.yaml` still lists the master recipient,
  so reverting `vaultSync.groovy` to the master `sops-age-key` credential instantly restores
  decryption for all apps — zero downtime.

## 8. Known limitations / out of scope
- **Master key compromise** still exposes all apps — it's the recovery anchor by design; keep it
  offline and backed up securely. Per-app keys limit *Jenkins/job/repo* blast radius, not a
  master-key leak.
- **Existing git history** holds secrets encrypted to the old shared key; those ciphertexts stay
  decryptable by the master (= old shared) key. That's intended (the master is the recovery key);
  no history rewrite.
- **Rotating an app's key** later = re-run `gen-app-age-key.sh --force <app>` + `sops updatekeys`
  + redeploy. Documented, not automated here.
- Splunk and any app without a `vault/.sops.yaml` are unaffected.

## 9. Deliverables
1. vault repo: `gen-app-age-key.sh`, `seed-age-keys.sh`, `vaultSync.groovy` change,
   `jenkins-policy.hcl.tmpl` line, `start-vault.sh` seed call, `setup-jenkins-credentials.sh`
   cutover, README.
2. 7 app repos: two-recipient `.sops.yaml` + re-encrypted `*.secret.sops.env`.
3. STEP0: `restore-scratch.sh` note + `docs/base-architecture-scaffold.md` + restore spec §7 update.
4. This design doc.
