# Secrets & the Vault workflow

This project is part of the private-cloud cluster bootstrap. Application config
and secrets for the cluster's apps are **not** stored as Kubernetes
`Secret`/`ConfigMap` manifests — they live in the single shared **HashiCorp
Vault** and are injected into pods at runtime (`/vault/secrets/config`).

If you need to add or change a secret for any app, follow the **canonical,
always-current workflow**:
**https://github.com/wiqram/vault/blob/main/docs/adding-secrets.md**

In short: edit the app's declarative manifest (config in `<service>.env`,
secrets in the SOPS-encrypted `<service>.secret.sops.env`), commit + push, and
the Jenkins `vault-secrets-sync` job reconciles it into `kv/<app>/*` and restarts
the consumers.

The Vault provisioning + secret-seeding layer (policies, `vault-sync.sh`, the
`vault-secrets-sync` CI job, the cluster bootstrap) lives in the `wiqram/vault`
repo. Never commit plaintext secrets here or there.
