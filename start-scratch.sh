#!/bin/bash

set -e
# Absolute path to this script, captured BEFORE any cd below (lines ~68/77 cd
# into kube-prometheus/ then vault/). Later steps grep this file for the inline
# Jenkins credential; a relative $0 would no longer resolve after those cds.
SCRIPT_PATH="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/$(basename "${BASH_SOURCE[0]}")"

##############################################
# Push notifications -> ntfy `yolo-private-cloud-start-scratch`.
#
# A cold bring-up is the single most consequential thing that happens on this host: it
# rebuilds the cluster, and it is sometimes started by someone (or something) other
# than the person watching. So the channel answers "did start-scratch run, and how did
# it end" without anyone tailing a terminal for the ~30 minutes it takes.
#
# `set -e` is on, so ANY failing command aborts mid-bootstrap and would otherwise be
# silent. The ERR trap records where, and the EXIT trap turns that into the failure
# push — one notification per run either way. `set -E` (errtrace) is added so the ERR
# trap is still inherited inside the functions/subshells this script uses; it changes
# nothing about which commands abort the run.
##############################################
set -E
# shellcheck source=/dev/null
if [ -r "$(dirname "$SCRIPT_PATH")/ntfy-lib.sh" ]; then source "$(dirname "$SCRIPT_PATH")/ntfy-lib.sh"; else
  echo "WARN: ntfy-lib.sh not found — this bring-up will send no notification." >&2
  ntfy_push() { :; }; NTFY_TOPIC_START_SCRATCH=""
fi
SS_START=$(date +%s)
SS_ERR_LINE=""; SS_ERR_CMD=""
# Resolved once so both the start and the end message agree about what this run did.
if [ -n "${SKIP_APP_BUILDS:-}" ]; then
  SS_APPS_PLAN="will be SKIPPED (SKIP_APP_BUILDS set)"
  SS_APPS_DONE="SKIPPED - run ./trigger-app-builds.sh once DNS is confirmed"
else
  SS_APPS_PLAN="will be deployed via Jenkins at the end"
  SS_APPS_DONE="Jenkins build triggers fired"
fi
trap 'SS_ERR_LINE=$LINENO; SS_ERR_CMD=$BASH_COMMAND' ERR
ss_finish() {
  local rc=$? elapsed=$(( $(date +%s) - SS_START ))
  local mins=$(( elapsed / 60 )) secs=$(( elapsed % 60 ))
  if [ "$rc" -eq 0 ]; then
    ntfy_push "$NTFY_TOPIC_START_SCRATCH" "start-scratch COMPLETED (${mins}m ${secs}s)" \
"Cold bring-up finished on $(hostname -s).
apps: $SS_APPS_DONE
Check: minikube status / kubectl get po -A / ./verify-recovery.sh" \
      "default" "rocket,cloud"
  else
    ntfy_push "$NTFY_TOPIC_START_SCRATCH" "start-scratch FAILED (rc=$rc) after ${mins}m ${secs}s" \
"Aborted on $(hostname -s) at line ${SS_ERR_LINE:-?} of start-scratch.sh:
  ${SS_ERR_CMD:-unknown command}

set -e means the cluster is HALF-BUILT - it is not safe to assume anything past that
line ran. Re-run after fixing; see RESTART-RECOVERY.md before reaching for a delete." \
      "urgent" "rotating_light,cloud"
  fi
}
trap ss_finish EXIT
ntfy_push "$NTFY_TOPIC_START_SCRATCH" "start-scratch STARTED" \
"Cold bring-up beginning on $(hostname -s) as $(whoami).
apps: $SS_APPS_PLAN
Expect a COMPLETED or FAILED note on this channel when it ends." \
  "default" "hourglass_flowing_sand,cloud"
#echo "in UP.sh >>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>>"-e url=https://www.qcguy.com
#./build.sh
#setup the 5million external network on docker
if docker network inspect 5million; then
  echo "5million docker network present"
  #    minikube delete
else
  echo "Command failed"
  docker network create \
    --driver=bridge \
    --subnet=172.16.0.0/16 \
    --ip-range=172.16.240.0/24 \
    --gateway=172.16.238.1 \
    5million
fi
#check if minikube is installed, if not install it with appropriate memory and cpus
if kubectl version; then
  echo "Minikube running"
  #    minikube delete
else
  echo "Minikube NOT running - Creating one now"
  # R8 (plan.md): establish the sdb2 registry-blob bind BEFORE the node is created, so the docker
  # rbind captures it at container-creation time (durable registry store; see k8s/registry/README.md).
  "$(dirname "$SCRIPT_PATH")/k8s/registry/ensure-registry-store.sh"
  #minikube start --cpus 4 --memory 16384 --nodes 2 #--driver=none--driver=docker --alsologtostderr -v=4
  #---------------------------------------------------------------------------------------------------------
  # Resource-efficient start (see plan.md "Cluster resource efficiency" section). Key changes vs the old line:
  #   --cpus 16            : CPU is compressible (throttles, never OOM-kills) so we give burst headroom while
  #                          still leaving ~8 threads for the host (IntelliJ + Chrome). Mem is the hard limit, not CPU.
  #   --memory 65536       : 64G envelope on the 96G DDR5 host (2x32G + 2x16G; was 32768/32G on the old 48G host).
  #                          Reserves ~32G for OS/Docker/nginx-proxy-manager/IntelliJ/Chrome + Jenkins build
  #                          spikes. NOTE: ollama runs as a pod INSIDE this cgroup, so the 32b model's CPU offload
  #                          (~8-10G) is charged against this 64G, not the host reserve. 64G still leaves ample room.
  #   kubelet system-reserved=31Gi : the docker driver reports the FULL host (24CPU/96G) as node capacity (kubelet
  #                          reads the host /proc/meminfo, NOT the cgroup) while Docker hard-caps the container at
  #                          16CPU/64G via cgroups. The reservation must therefore bridge the ENTIRE host->cgroup gap:
  #                          94Gi capacity - 31Gi system-reserved - 2Gi kube-reserved - 1Gi eviction => ~60Gi
  #                          Allocatable, i.e. ~4Gi UNDER the 64G cgroup so the scheduler can't place pods the cgroup
  #                          won't grant. (Was memory=2Gi, which left Allocatable ~89Gi -> 25Gi of silent over-commit;
  #                          only the eviction-hard backstop saved it, and only by thrashing at the very edge.)
  #                          CPU stays over-advertised (24 cap vs 16 cgroup) on purpose: CPU is compressible (throttles,
  #                          never OOM-kills), so the burst headroom is free. zram swap stays on as a cheap net (plan.md).
  # ---- Host-adaptive sizing (2026-08-07) --------------------------------------------------
  # --memory and system-reserved USED TO BE hardcoded for the 96G host (65536 / 31Gi). That
  # is fatal on a box with less RAM: `minikube start --memory 65536` on a 32G host refuses to
  # start, and a hardcoded system-reserved silently mis-sizes Allocatable either way. This
  # box is running on reduced RAM after the 2026-08-06 memory-corruption crash, so the two
  # numbers are DERIVED. The reference case is preserved exactly: a 96G host still computes
  # --memory 65536 and system-reserved 31Gi, so nothing changes when the RAM goes back in.
  #
  # The invariant is the one reasoned out above, unchanged:
  #   Allocatable = HOST_GI - SYS_RES - KUBE_RES(2Gi) - EVICT(1Gi)  ==  MK_GI - 4
  #   => SYS_RES  = HOST_GI - MK_GI + 1
  # Check against the hand-tuned values it replaces: 94 - 64 + 1 = 31Gi. Exact.
  #
  # Override either with MINIKUBE_MEM_GI / MINIKUBE_CPUS in the environment.
  HOST_GI=$(( $(awk '/^MemTotal:/{print $2}' /proc/meminfo) / 1024 / 1024 ))
  # Leave the host its share: 30Gi on a big box (OS + docker + nginx-proxy-manager +
  # IntelliJ + Chrome + Jenkins build spikes), otherwise a third, never less than 8Gi.
  if [ "$HOST_GI" -ge 80 ]; then
    HOST_RESERVE_GI=30
  else
    HOST_RESERVE_GI=$(( HOST_GI / 3 ))
    if [ "$HOST_RESERVE_GI" -lt 8 ]; then HOST_RESERVE_GI=8; fi
  fi
  MK_GI="${MINIKUBE_MEM_GI:-$(( HOST_GI - HOST_RESERVE_GI ))}"
  if [ "$MK_GI" -lt 4 ]; then
    echo "FATAL: only ${HOST_GI}Gi RAM detected — too little to start this cluster."
    echo "       Seat the missing DIMMs, or override deliberately: MINIKUBE_MEM_GI=<n> $0"
    exit 1
  fi
  SYS_RES_GI=$(( HOST_GI - MK_GI + 1 ))
  if [ "$SYS_RES_GI" -lt 1 ]; then SYS_RES_GI=1; fi
  # CPU is compressible (throttles, never OOM-kills) so we over-advertise on purpose, while
  # still leaving ~8 threads for the host.
  MK_CPUS="${MINIKUBE_CPUS:-$(( $(nproc) - 8 ))}"
  if [ "$MK_CPUS" -gt 16 ]; then MK_CPUS=16; fi
  if [ "$MK_CPUS" -lt 4 ];  then MK_CPUS=4;  fi
  echo "minikube sizing: host=${HOST_GI}Gi -> --cpus ${MK_CPUS} --memory $(( MK_GI * 1024 ))MB, kubelet system-reserved=${SYS_RES_GI}Gi"
  if [ "$HOST_GI" -lt 80 ]; then
    echo "NOTE: this host is well under the 96G design point — the full app set (Jenkins +"
    echo "      kube-prometheus + Vault + ollama + splunk + apps) will be tight at ${MK_GI}Gi."
  fi
  minikube start --cpus "$MK_CPUS" --memory "$(( MK_GI * 1024 ))" --disk-size 40g --driver=docker --network 5million --gpus all --mount-string="/mnt/minikube-backups/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.system-reserved=cpu=1,memory=${SYS_RES_GI}Gi --extra-config=kubelet.kube-reserved=cpu=1,memory=2Gi --extra-config=kubelet.eviction-hard="memory.available<1Gi,nodefs.available<10%" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
  # Pre-2026-08-07 line (hardcoded for the 96G host), kept for reference:
  #minikube start --cpus 16 --memory 65536 --disk-size 40g --driver=docker --network 5million --gpus all --mount-string="/mnt/minikube-backups/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.system-reserved=cpu=1,memory=31Gi --extra-config=kubelet.kube-reserved=cpu=1,memory=2Gi --extra-config=kubelet.eviction-hard="memory.available<1Gi,nodefs.available<10%" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
  # Previous line (kept for reference): no kubelet reservations/eviction -> scheduler over-commits the 32G cgroup cap.
  #minikube start --cpus 12 --memory 32768 --disk-size 40g --driver=docker --network 5million --gpus all --mount-string="/mnt/minikube-backups/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
  #minikube start --cpus 12 --memory 32768 --disk-size 40g --driver=docker --network 5million --mount-string="/home/cloud/Ideaprojects/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
  #minikube start --cpus 6 --memory 16384 --disk-size 50g --driver=kvm2 --kvm-gpu --network="5million" --mount-string="/home/cloud/Ideaprojects/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
  #minikube start
  #set strictARP to true to allow for MetalLB loadbalancer
  #kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: false/" | kubectl apply -f - -n kube-system
  #To install MetalLB, apply the manifest
  #kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.11.0/manifests/namespace.yaml
  #kubectl apply -f metallb.yaml
  #This will deploy MetalLB to your cluster, under the metallb-system namespace
  #now install metallb config
  #kubectl apply -f metallb-config.yaml
  #sleep to allow for nginx to be updted with latest minikube kvm ip
  #echo "now sleeping for 3 minutes to allow for nginx to be updted with latest minikube kvm ip"
  #sleep 3m
fi
#################cri-dockerd deadline#############################
# MUST run after `minikube start` (a fresh node has no drop-in) and BEFORE anything
# starts creating containers. /var/lib/docker sits on the ageing sda SATA SSD, so under
# build+rollout load a single CreateContainer can outrun cri-dockerd's default 2m
# deadline — which then orphans a container and wedges the pod in a
# "container name already in use" retry loop. See the script header for the full trace.
# Best-effort: a tuning miss must not abort the bootstrap.
"$(dirname "$SCRIPT_PATH")/tune-cri-dockerd-timeout.sh" \
  || echo "WARN: cri-dockerd timeout tuning failed; container creates may time out under IO load."
#to install docker container registry — R8: self-managed + durable on sdb2 (NOT the ephemeral addon).
# The addon stored blobs on the pod's ephemeral /var/lib/registry, so every cluster stop wiped all
# images (cluster-wide ImagePullBackOff — the 2026-06-16 outage). We disable it and run our own
# Deployment+proxy backed by a hostPath PVC on sdb2. See k8s/registry/README.md.
minikube addons disable registry
kubectl apply -f "$(dirname "$SCRIPT_PATH")/k8s/registry/"
# Old ephemeral path (kept for reference): minikube addons enable registry
# Resource metrics for `kubectl top` / HPAs. We DO need this: prometheus-adapter
# can't serve pod metrics on this node (kubelet cAdvisor series lack pod/namespace/
# container labels), so top pod returns nothing. metrics-server reads the kubelet
# Summary API instead and owns v1beta1.metrics.k8s.io. The kube-prometheus
# adapter-apiservice manifest (which would re-claim that API on `apply -f manifests/`)
# has been removed from that repo, so there's no conflict on rebuild.
minikube addons enable metrics-server
#minikube addons enable ingress
#minikube addons enable dashboard
minikube addons enable nvidia-gpu-device-plugin
#minikube addons enable nvidia-driver-installer
#MINIKUBEIP=$(minikube ip)
#allow minikube to connect to local docker images
#eval $(minikube -p minikube docker-env)
# Re-arm dev-box → prod minikube API access over 10GbE. DOCKER-USER rules are wiped on docker
# restart, so a cluster rebuild must re-apply them. Best-effort (needs root); the installed
# devbox-kube-access.service re-applies on every boot regardless. See enable-devbox-kube-access.sh.
sudo -n "$HOME/Ideaprojects/STEP0/enable-devbox-kube-access.sh" || echo "devbox-kube-access: skipped (run 'sudo ./enable-devbox-kube-access.sh --install' once)"
###########x`######grafana-prometheus###########################
# Grafana's /var/lib/grafana is a DURABLE hostPath PV (kube-prometheus
# manifests/grafana-dataVolume.yaml -> node /mnt/grafana-data == host
# /mnt/minikube-backups/minikube-mnt/grafana-data). Pre-create it with the right owner
# BEFORE applying the manifests:
#   - the PV uses type: DirectoryOrCreate, and a kubelet-created dir lands root:root 0755;
#   - Grafana runs as uid/gid 65534 with readOnlyRootFilesystem, so it could not write and
#     would crash-loop on "failed to open sqlite database" — a failure that reads like a
#     Grafana bug rather than a permissions one.
# It is re-asserted on EVERY bootstrap on purpose: restore-scratch.sh phase 3 runs a
# recursive `chown -R cloud:cloud /mnt/minikube-backups`, which would otherwise leave this
# directory owned by uid 1000 after a resumed restore.
# Done THROUGH THE NODE, not with host sudo: the node's /mnt is the same host directory
# (--mount-string above), the node shell is already root, and this box has no passwordless
# sudo — so a `sudo mkdir` here would silently fail inside an unattended bootstrap.
docker exec minikube sh -c 'mkdir -p /mnt/grafana-data && chown -R 65534:65534 /mnt/grafana-data' \
  || echo "WARN: could not prepare /mnt/grafana-data; Grafana may fail to write its SQLite DB."
echo "deploying grafana prometheus"
cd $HOME/Ideaprojects/kube-prometheus/
kubectl apply --server-side -f manifests/setup
kubectl wait \
	--for condition=Established \
	--all CustomResourceDefinition \
	--namespace=monitoring
kubectl apply -f manifests/
#################vault###########################
echo "deploying vault"
# Durable Vault storage + daily snapshot (see k8s/vault-backup/). MUST apply
# BEFORE start-vault.sh: the pre-created data-vault-0 PVC (pinned to the Retain
# PV on the shared mount) has to exist so the helm StatefulSet ADOPTS it instead
# of dynamic-provisioning an ephemeral /tmp hostPath — the 2026-07-14 failure
# mode that destroyed all runtime-written Vault data on a minikube rebuild.
kubectl create namespace vault --dry-run=client -o yaml | kubectl apply -f -
kubectl apply -f "$(dirname "$SCRIPT_PATH")/k8s/vault-backup/"
cd $HOME/Ideaprojects/vault/
bash start-vault.sh
#################grafana admin login###############
# Pin Grafana's admin login from Vault (kv/grafana/admin -> monitoring/grafana-admin
# Secret). MUST run after start-vault.sh (needs Vault unsealed) and after the
# kube-prometheus apply above (needs the monitoring namespace). Grafana's
# /var/lib/grafana is an emptyDir, so without this the admin password reverts to the
# built-in admin/admin on every single pod restart. Best-effort: a monitoring login is
# not worth aborting a bootstrap that still has apps to deploy.
"$(dirname "$SCRIPT_PATH")/sync-grafana-admin.sh" \
  || echo "WARN: grafana admin sync failed; Grafana may be on its default admin/admin."
#################jenkins###########################
#create a customer jenkins/inbound-agent with k8s and curl and wget pre-installed and pushed to private repo
#if [[ "$(docker image inspect 172.16.238.2:5000/jenkins-inbound-agent-vik:cloud 2> /dev/null)" == "" ]]; then
# Always build so the image reflects the Dockerfile (the source of truth) after a
# refresh — e.g. the vault/sops/age/jq tooling the vault-secrets-sync pipeline
# needs. Docker layer caching makes an unchanged rebuild near-instant. Non-fatal:
# on a build/push failure fall back to whatever image is already present.
echo "building custom jenkins/inbound-agent image (cached layers make unchanged rebuilds fast)"
docker build -t container-registry.traderyolo.com/jenkins-inbound-agent-vik:cloud $HOME/Ideaprojects/jenkins/inbound-agent/. \
  || echo "WARN: inbound-agent image build failed; using the existing image"
docker push container-registry.traderyolo.com/jenkins-inbound-agent-vik:cloud \
  || echo "WARN: inbound-agent image push failed; using the image already in the registry"
#docker push $MINIKUBEIP:5000/jenkins-inbound-agent-vik:cloud
#create k8s components for jenkins
kubectl apply -f $HOME/Ideaprojects/jenkins/compiled.yaml

#################vault Jenkins credentials#####################################
# Mirror the per-app AppRole role_id/secret_id (that start-vault.sh just
# regenerated into ~/.vault/jenkins-approle/) + sops-age-key into Jenkins
# credentials. Each app's deploy job binds these and refreshes its own kv/<app>/*
# at deploy via the vaultSync() shared library — there is no central sync job.
# MUST run after Jenkins is up. On a fresh Vault the secret_ids change, so this
# keeps the credentials valid. Best-effort: never abort the bootstrap.
echo "configuring vault Jenkins credentials"
# Prefer the Jenkins credential from the gitignored .env (JENKINS_CRED) — same source
# trigger-app-builds.sh uses — so this no longer depends on an inline token in this file.
# Fall back to the legacy self-grep for backward-compat if .env is absent.
JENKINS_AUTH="$(grep -E '^JENKINS_CRED=' "$(dirname "$SCRIPT_PATH")/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )"
[ -n "$JENKINS_AUTH" ] || JENKINS_AUTH=$(grep -oE 'private-cloud:[0-9a-f]+@jenkins' "$SCRIPT_PATH" | head -1 | sed 's/@jenkins//')
JENKINS_NODEPORT="http://$(minikube ip 2>/dev/null || echo 172.16.238.2):30380"
for i in $(seq 1 60); do
  curl -sf -u "$JENKINS_AUTH" "$JENKINS_NODEPORT/api/json?tree=mode" >/dev/null 2>&1 && { echo "jenkins API ready"; break; }
  echo "waiting for jenkins API... ($i)"; sleep 5
done
JENKINS_URL="$JENKINS_NODEPORT" JENKINS_USER="${JENKINS_AUTH%%:*}" JENKINS_TOKEN="${JENKINS_AUTH#*:}" \
  bash "$HOME/Ideaprojects/vault/scripts/setup-jenkins-credentials.sh" \
  || echo "WARN: vault Jenkins credential setup failed; re-run vault/scripts/setup-jenkins-credentials.sh manually."

#################container-registry#############################
#create k8s components for private container registry - NOT USED BCOZ USING MINIKUBE REGISTRY
#kubectl apply -f $HOME/Ideaprojects/container-registry/private-registry.yaml

#################app deploys (Jenkins)#############################
# The actual per-app deploys are Jenkins job triggers, extracted to
# trigger-app-builds.sh. restore-scratch.sh sets SKIP_APP_BUILDS=1 to bring up the
# platform first and fire these only AFTER DNS points at the host.
if [ -z "${SKIP_APP_BUILDS:-}" ]; then
  "$(dirname "$SCRIPT_PATH")/trigger-app-builds.sh"
else
  echo "SKIP_APP_BUILDS set — skipping Jenkins app-build triggers. Run ./trigger-app-builds.sh after DNS is confirmed."
fi
#curl -X POST https://private-cloud:REVOKED-2026-06-30@jenkins.traderyolo.com/job/delete_mem_leak_java/build?token=delete_mem_leak_java
##################### ONLY FOR HSBC splunk-for-hsbc-demo - the lines with only one # can be dehashed to deploy splunk#############################
echo "End - NOT deploying splunk"
#cd $HOME/IdeaProjects/splunk-hsbc-demo/
#kubectl apply -f splunk-namespace.yaml
#kubectl apply -f compiled.yaml
#echo "splunk deployment done. now sleeping for 2 min before setting up splunk infra."
#sleep 3m
#cd $HOME/IdeaProjects/splunk-hsbc-demo/Automation/splunk-monitor/
##the below command can only run in bash
##export MONITORING_MACHINE='splunk.splunk.svc.cluster.local' && export HEC_TOKEN='25577715-5282-4f8b-ab9c-c8aa95a75bea' && export HEC_PORT='8088' && export GLOBAL_HEC_INSECURE_SSL='true' && export OBJECTS_INSECURE_SSL='true' && export METRICS_INSECURE_SSL='true' && export JOURNALD_PATH='/run/log/journal' && export KUBELET_PROTOCOL='http' && export METRICS_INDEX='em_metrics' && export LOG_INDEX='main' && export META_INDEX='em_meta' && export CLUSTER_NAME='minikube' && export SCK_DOWNLOAD_ONLY='false' && export HELM_RELEASE_NAME='helm' && export KUBERNETES_NAMESPACE='splunk-connect' && export CORE_OBJ='pods,nodes,component_statuses,config_maps,namespaces,persistent_volumes,persistent_volume_claims,resource_quotas,services,service_accounts,events' && export APPS_OBJ='daemon_sets,deployments,replica_sets,stateful_sets' && files=("kubernetes_connect_template.yaml" "deploy_sck_k8s.sh") && for each in "${files[@]}"; do wget -O- --no-check-certificate https://splunk.traderyolo.com:/en-US/static/app/splunk_app_infrastructure/kubernetes_connect/"$each" >$each; done && wget https://github.com/splunk/splunk-connect-for-kubernetes/releases/download/1.3.0/splunk-connect-for-kubernetes-1.3.0.tgz -O splunk-connect-for-kubernetes.tgz && bash deploy_sck_k8s.sh
##the below command can run in sh and bash.
#export MONITORING_MACHINE='splunk.splunk.svc.cluster.local' && export HEC_TOKEN='25577715-5282-4f8b-ab9c-c8aa95a75bea' && export HEC_PORT='8088' && export GLOBAL_HEC_INSECURE_SSL='true' && export OBJECTS_INSECURE_SSL='true' && export METRICS_INSECURE_SSL='true' && export JOURNALD_PATH='/run/log/journal' && export KUBELET_PROTOCOL='http' && export METRICS_INDEX='em_metrics' && export LOG_INDEX='main' && export META_INDEX='em_meta' && export CLUSTER_NAME='minikube' && export SCK_DOWNLOAD_ONLY='false' && export HELM_RELEASE_NAME='helm' && export KUBERNETES_NAMESPACE='splunk-connect' && export CORE_OBJ='pods,nodes,component_statuses,config_maps,namespaces,persistent_volumes,persistent_volume_claims,resource_quotas,services,service_accounts,events' && export APPS_OBJ='daemon_sets,deployments,replica_sets,stateful_sets' && set -- "kubernetes_connect_template.yaml" "deploy_sck_k8s.sh" && for each in "$@"; do wget -O- --no-check-certificate https://splunk.traderyolo.com:/en-US/static/app/splunk_app_infrastructure/kubernetes_connect/"$each" > $each; done && wget https://github.com/splunk/splunk-connect-for-kubernetes/releases/download/1.3.0/splunk-connect-for-kubernetes-1.3.0.tgz -O splunk-connect-for-kubernetes.tgz && bash deploy_sck_k8s.sh

##docker run --restart=always --network 5million -d --name qcguy -p 2368:2368 -v /home/vik/IdeaProjects/qcguy-cms/config/config.production.json:/var/lib/ghost/config.production.json -v some-ghost-data:/var/lib/ghost/content ghost
