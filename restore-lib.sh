#!/bin/bash
# restore-lib.sh — pure, sourceable helpers for restore-scratch.sh. No side effects.
# Sourcing this file must not execute anything except function definitions.

# pick_latest_archive: read candidate gs:// URIs on stdin, print the single newest
# private-cloud-MM-DD-YY.tgz by the date EMBEDDED IN THE FILENAME (not lexical order,
# not GCS listing order). Mirrors the date parse in backup-minikube-mnt.sh's prune.
pick_latest_archive() {
  sed -E 's#.*/private-cloud-([0-9]{2})-([0-9]{2})-([0-9]{2})\.tgz$#20\3-\1-\2 &#' \
    | grep -E '^[0-9]{4}-[0-9]{2}-[0-9]{2} ' \
    | sort \
    | tail -1 \
    | awk '{print $2}'
}

# restore_repo_manifest: emit "<target_dir> <git_url> <branch>" per infra/app repo to
# clone on a fresh box. STEP0 is cloned by hand (bootstrap) and is intentionally absent.
# Branches captured 2026-06-30, ollama corrected 2026-08-04; update when prod's deployed
# branches change. THIS IS EASY TO GET SILENTLY WRONG: a stale branch here clones a repo
# that builds and deploys fine but is missing whatever prod actually runs. ollama was
# pinned to `main` while prod had been deploying `Claude-agent-update` — a bare-metal
# restore would have come back with no ollama metrics shim, no router metrics and no
# ServiceMonitors, all without a single error. Check with:
#   for d in <dirs>; do git -C $d rev-parse --abbrev-ref HEAD; done
#
# A WRONG BRANCH IS THE LOUD VERSION OF THIS BUG. The quiet one is a repo that is not
# listed AT ALL: nothing clones it, so there is no branch to diff and the audit above
# cannot see it. aisucks and propinvestech were both missing until 2026-08-18 — two live
# public sites (namespaces `aisucks` and `prop-investech`, both with Jenkins jobs) that a
# bare-metal restore would simply never have brought back. Re-audit by diffing this list
# against every local git repo that has a Jenkinsfile/deployment.yaml, not just by
# checking the branches of the repos already named here:
#   source ./restore-lib.sh
#   for d in /home/cloud/Ideaprojects/*/ /home/cloud/IdeaProjects/*/; do
#     p=${d%/}; [ -d "$p/.git" ] || continue
#     [ -f "$p/Jenkinsfile" ] || [ -f "$p/deployment.yaml" ] || continue   # deployable only
#     restore_repo_manifest | grep -q "^$p " || echo "NOT IN MANIFEST: $p"
#   done
# Use the PIPE, not `grep ... <(restore_repo_manifest)` — the process-substitution form
# silently matches nothing here and reports every repo as missing, which reads like a
# catastrophe and is purely an artefact of the command.
# Deliberately absent after that audit, both verified not deployed on 2026-08-18:
#   splunk-hsbc-demo — start-scratch.sh's splunk block is commented out and prints
#                      "End - NOT deploying splunk"; no splunk namespace exists.
#   tatesremedies    — no namespace, no Jenkins job, no registry repo.
# If either is ever actually deployed, it has to be added here at the same time.
restore_repo_manifest() {
  cat <<'EOF'
/home/cloud/Ideaprojects/vault https://github.com/wiqram/vault.git main
/home/cloud/Ideaprojects/jenkins https://github.com/wiqram/jenkins.git master
/home/cloud/Ideaprojects/kube-prometheus https://github.com/wiqram/kube-prometheus.git main
/home/cloud/Ideaprojects/nginx https://github.com/wiqram/nginx.git master
/home/cloud/Ideaprojects/qcguy-ghost https://github.com/wiqram/qcguy-ghost.git main
/home/cloud/IdeaProjects/aisucks https://github.com/wiqram/aisucks.git main
/home/cloud/IdeaProjects/bestrentaladmin https://github.com/wiqram/bestrentaladmin.git main
/home/cloud/IdeaProjects/dyingpaleblue https://github.com/wiqram/dyingpaleblue.git main
/home/cloud/IdeaProjects/propinvestech https://github.com/wiqram/propinvestech.git main
/home/cloud/IdeaProjects/ollama https://github.com/wiqram/ollama.git Claude-agent-update
/home/cloud/IdeaProjects/Predictonomy https://github.com/wiqram/Predictonomy.git Claude-agent-updates
/home/cloud/IdeaProjects/IG-Trading-Microservices https://github.com/wiqram/IG-Trading-Microservices.git Claude-agent-update
/home/cloud/IdeaProjects/qcx https://github.com/wiqram/qcx.git main
/home/cloud/IdeaProjects/radcliffe https://github.com/wiqram/radcliffe.git main
EOF
}
