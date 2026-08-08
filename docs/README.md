# STEP0 documentation

Every long-form document for the private-cloud bootstrap lives here. Two files
deliberately stay at the **repo root** and must not be moved into this directory:
`CLAUDE.md` (Claude Code loads project instructions from the root) and `README.md`
(GitHub renders the root README as the repo landing page).

> Moved here on 2026-08-08. If an older note, commit message or agent memory points at
> `STEP0/architecture.md`, `STEP0/plan.md` or any sibling, the file is not missing — it is
> under `docs/`.

## Start here

| If you are… | Read |
|---|---|
| Understanding how the whole thing fits together | [`architecture.md`](./architecture.md) — the system design, incl. §10 "deploy a new app" scaffolding |
| Looking for what still needs doing | [`plan.md`](./plan.md) — the improvement backlog |
| Staring at a cluster that came back unhealthy | [`RESTART-RECOVERY.md`](./RESTART-RECOVERY.md) — warm-vs-cold decision, what auto-recovers, symptom→fix triage |
| Adding a brand-new website/app to this cloud | [`base-architecture-scaffold.md`](./base-architecture-scaffold.md) — the copy-paste contract for a new project |

## Runbooks

| Document | Covers |
|---|---|
| [`GM9000-MIGRATION.md`](./GM9000-MIGRATION.md) | Prod OS-disk swap to a 4TB NVMe: partition plan, pre-shutdown quiesced backup, phase-by-phase `restore-scratch.sh` walkthrough |
| [`DEVBOX-9100PRO-MIGRATION.md`](./DEVBOX-9100PRO-MIGRATION.md) | The dev box's equivalent M.2 swap (Samsung 9100 PRO, dual-boot Windows/Ubuntu, ollama + 10GbE rewiring) |
| [`UBUNTU-UPGRADE.md`](./UBUNTU-UPGRADE.md) | The `private-cloud` host 24.04 LTS → 26.04 LTS upgrade |
| [`VAULT-SECRETS.md`](./VAULT-SECRETS.md) | Secrets and the Vault workflow (the vault repo owns the detail) |

## Design records

`superpowers/` holds the plan + spec pairs written before each significant change —
useful for *why* something is shaped the way it is, not as current-state documentation.

- `superpowers/plans/` — the executable plans (restore-scratch, per-app age keys, agent deploy triggers, WD Cloud NFS off-site backup)
- `superpowers/specs/` — their design docs, plus dev-box kube access and platform alerting

## Historical handoffs

Point-in-time notes kept for the reasoning they contain. They describe a cluster state that
no longer exists — do not follow them as instructions.

- [`HANDOFF-2026-06-16-cluster-down.md`](./HANDOFF-2026-06-16-cluster-down.md)
- [`HANDOFF-2026-06-16-metrics-server-and-rollout-fixes.md`](./HANDOFF-2026-06-16-metrics-server-and-rollout-fixes.md)
