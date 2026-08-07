#!/bin/bash

set -e
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
  #minikube start --cpus 4 --memory 16384 --nodes 2 #--driver=none--driver=docker --alsologtostderr -v=4
  #---------------------------------------------------------------------------------------------------------
  # Mirrors the resource-efficient start line in start-scratch.sh (see plan.md "Cluster resource efficiency").
  #   --cpus 16 --memory 65536 : matches the cold-boot envelope so a warm rebuild gets the same sizing.
  #                          64G envelope on the 96G DDR5 host (2x32G + 2x16G; was 32768/32G on the old 48G host).
  #   kubelet system-reserved=31Gi : docker driver advertises the FULL host (24CPU/96G) to the scheduler (kubelet
  #                          reads host /proc/meminfo, not the cgroup) while Docker caps the container at 64G. The
  #                          reservation must bridge the whole host->cgroup gap: 94Gi cap - 31Gi sys - 2Gi kube - 1Gi
  #                          evict => ~60Gi Allocatable, ~4Gi under the 64G cgroup. (Was 2Gi -> ~89Gi Allocatable =
  #                          25Gi silent over-commit.) CPU left over-advertised on purpose (compressible). See
  #                          start-scratch.sh for the full rationale. zram swap stays on the host (plan.md R1).
  #   --gpus all           : added for parity with start-scratch so Ollama can claim the GPU on a warm rebuild
  #                          (if so, also uncomment the nvidia-gpu-device-plugin addon below).
  minikube start --cpus 16 --memory 65536 --disk-size 40g --driver=docker --network 5million --gpus all --mount-string="/mnt/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.system-reserved=cpu=1,memory=31Gi --extra-config=kubelet.kube-reserved=cpu=1,memory=2Gi --extra-config=kubelet.eviction-hard="memory.available<1Gi,nodefs.available<10%" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
  # Previous line (kept for reference): 6 CPU / 16G, no kubelet reservations/eviction, no GPU.
  #minikube start --cpus 6 --memory 16384 --disk-size 40g --driver=docker --network 5million --mount-string="/mnt/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
  #minikube start --cpus 6 --memory 16384 --disk-size 40g --driver=docker --network 5million --mount-string="/home/cloud/Ideaprojects/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
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
# Re-applied after every start: a rebuilt node has no drop-in. /var/lib/docker sits on
# the ageing sda SATA SSD, so under build+rollout load a CreateContainer can outrun
# cri-dockerd's default 2m deadline and wedge pods in a "container name already in use"
# retry loop. Idempotent + best-effort. See tune-cri-dockerd-timeout.sh for the trace.
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/tune-cri-dockerd-timeout.sh" \
  || echo "WARN: cri-dockerd timeout tuning failed; container creates may time out under IO load."
#to install docker container registry
minikube addons enable registry
# Resource metrics for `kubectl top` / HPAs. prometheus-adapter can't serve pod
# metrics on this node (kubelet cAdvisor series lack pod/namespace/container labels),
# so metrics-server reads the kubelet Summary API and owns v1beta1.metrics.k8s.io.
# Idempotent: re-enabling an already-enabled addon is a no-op.
minikube addons enable metrics-server
#minikube addons enable ingress
#minikube addons enable dashboard
minikube addons enable nvidia-gpu-device-plugin
#minikube addons enable nvidia-driver-installer
#MINIKUBEIP=$(minikube ip)
#allow minikube to connect to local docker images
#eval $(minikube -p minikube docker-env)
# Re-arm dev-box → prod minikube API access over 10GbE. DOCKER-USER rules AND Docker's
# raw/PREROUTING direct-routing drops are rebuilt on every docker start, so a warm restart must
# re-apply ours. Best-effort (needs root); the installed devbox-kube-access.service re-applies on
# boot and, since it is PartOf=docker.service, on a docker restart too.
# NOTE: no --emit-kubeconfig here (unlike start-scratch.sh) — a warm restart reuses the existing
# cluster, so the CA is unchanged and the dev box's kubeconfig stays valid.
sudo -n "$HOME/Ideaprojects/STEP0/enable-devbox-kube-access.sh" || echo "devbox-kube-access: skipped (run 'sudo ./enable-devbox-kube-access.sh --install' once)"
#################grafana-prometheus###########################
#echo "deploying grafana prometheus"
#cd $HOME/Ideaprojects/kube-prometheus/
#kubectl apply --server-side -f manifests/setup
#kubectl wait \
#	--for condition=Established \
#	--all CustomResourceDefinition \
#	--namespace=monitoring
#kubectl apply -f manifests/
#################vault###########################
echo "deploying vault"
cd $HOME/Ideaprojects/vault/
bash restart-vault.sh
#################grafana admin login###############
# Re-assert Grafana's admin login from Vault. Needed on the WARM path too: a
# minikube stop/start restarts the Grafana pod, and its /var/lib/grafana is an
# emptyDir — so the user DB, and the admin password with it, is gone again. The
# monitoring/grafana-admin Secret survives in etcd, so this is normally a no-op that
# only re-checks; it does not restart Grafana unless the password actually changed.
"$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/sync-grafana-admin.sh" \
  || echo "WARN: grafana admin sync failed; Grafana may be on its default admin/admin."
#################jenkins###########################
#create a customer jenkins/inbound-agent with k8s and curl and wget pre-installed and pushed to private repo
#if [[ "$(docker image inspect 172.16.238.2:5000/jenkins-inbound-agent-vik:cloud 2> /dev/null)" == "" ]]; then
if docker image inspect container-registry.traderyolo.com/jenkins-inbound-agent-vik:cloud; then
#if docker image inspect $MINIKUBEIP:5000/jenkins-inbound-agent-vik:cloud; then
  # docker image for inbound agent doesnt exist. create one
  echo "custom jenkins/inbound-agent image does exist - No need to create one"
else
  echo "custom jenkins/inbound-agent DOES NOT exist - Creating one now"
  docker build -t container-registry.traderyolo.com/jenkins-inbound-agent-vik:cloud $HOME/Ideaprojects/jenkins/inbound-agent/.
  #docker build -t $MINIKUBEIP:5000/jenkins-inbound-agent-vik:cloud $HOME/Ideaprojects/jenkins/inbound-agent/.
fi
docker push container-registry.traderyolo.com/jenkins-inbound-agent-vik:cloud
#docker push $MINIKUBEIP:5000/jenkins-inbound-agent-vik:cloud
#create k8s components for jenkins
#kubectl apply -f $HOME/Ideaprojects/jenkins/compiled.yaml

#################container-registry#############################
#create k8s components for private container registry - NOT USED BCOZ USING MINIKUBE REGISTRY
#kubectl apply -f $HOME/Ideaprojects/container-registry/private-registry.yaml

#################qcguy#############################
#create k8s namespace for qcguy
#kubectl create namespace qcguy --dry-run=client -o yaml | kubectl apply -f -
#create configmap for qcguy
#kubectl create configmap qcguy-configmap --from-file=$HOME/Ideaprojects/qcguy-ghost/config -n qcguy --dry-run=client -o yaml | kubectl apply -f -
#create k8s components for qcguy
#kubectl apply -f $HOME/Ideaprojects/qcguy-ghost/compiled.yaml

#################tatesremedies#############################
#create k8s namespace for tatesremedies
#kubectl create namespace tatesremedies --dry-run=client -o yaml | kubectl apply -f -
#create configmap for tatesremedies
#kubectl create configmap tatesremedies-configmap --from-file=$HOME/Ideaprojects/tatesremedies/config -n tatesremedies --dry-run=true -o yaml | kubectl apply -f -
#create k8s components for tatesremedies
#kubectl apply -f $HOME/Ideaprojects/tatesremedies/compiled.yaml

#################################build yolo jenkins pipeline remotely##########################
echo "building yolo pipeline"
#wget --auth-no-challenge --user=admin --password=5ad344f0518640f62d0483084bb889bc http://13.126.143.49:8080/job/ANT//build?token=iFBDOBhNhaxL4T9ass93HRXun2JF161Z
# Jenkins credential from the gitignored .env (JENKINS_CRED) — same pattern as trigger-app-builds.sh,
# so the token is no longer inline here. Set JENKINS_CRED=user:token in STEP0/.env.
SELFDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
JENKINS_CRED="$(grep -E '^JENKINS_CRED=' "$SELFDIR/.env" 2>/dev/null | head -1 | cut -d= -f2- | tr -d '"'"'"'' )"
curl -X POST "https://${JENKINS_CRED}@jenkins.traderyolo.com/job/trading-microservices/build?token=yolobuildstep_0"
#curl -X POST "https://${JENKINS_CRED}@jenkins.traderyolo.com/job/delete_mem_leak_java/build?token=delete_mem_leak_java"
##################### ONLY FOR HSBC splunk-for-hsbc-demo#############################
#echo "deploying splunk"
#cd $HOME/IdeaProjects/splunk-hsbc-demo/
#kubectl apply -f splunk-namespace.yaml
#kubectl apply -f compiled.yaml
#echo "splunk deployment done. now sleeping for 2 min before setting up splunk infra."
#sleep 3m
#cd $HOME/IdeaProjects/splunk-hsbc-demo/Automation/splunk-monitor/
#the below command can only run in bash
#export MONITORING_MACHINE='splunk.splunk.svc.cluster.local' && export HEC_TOKEN='25577715-5282-4f8b-ab9c-c8aa95a75bea' && export HEC_PORT='8088' && export GLOBAL_HEC_INSECURE_SSL='true' && export OBJECTS_INSECURE_SSL='true' && export METRICS_INSECURE_SSL='true' && export JOURNALD_PATH='/run/log/journal' && export KUBELET_PROTOCOL='http' && export METRICS_INDEX='em_metrics' && export LOG_INDEX='main' && export META_INDEX='em_meta' && export CLUSTER_NAME='minikube' && export SCK_DOWNLOAD_ONLY='false' && export HELM_RELEASE_NAME='helm' && export KUBERNETES_NAMESPACE='splunk-connect' && export CORE_OBJ='pods,nodes,component_statuses,config_maps,namespaces,persistent_volumes,persistent_volume_claims,resource_quotas,services,service_accounts,events' && export APPS_OBJ='daemon_sets,deployments,replica_sets,stateful_sets' && files=("kubernetes_connect_template.yaml" "deploy_sck_k8s.sh") && for each in "${files[@]}"; do wget -O- --no-check-certificate https://splunk.traderyolo.com:/en-US/static/app/splunk_app_infrastructure/kubernetes_connect/"$each" >$each; done && wget https://github.com/splunk/splunk-connect-for-kubernetes/releases/download/1.3.0/splunk-connect-for-kubernetes-1.3.0.tgz -O splunk-connect-for-kubernetes.tgz && bash deploy_sck_k8s.sh
#the below command can run in sh and bash.
#export MONITORING_MACHINE='splunk.splunk.svc.cluster.local' && export HEC_TOKEN='25577715-5282-4f8b-ab9c-c8aa95a75bea' && export HEC_PORT='8088' && export GLOBAL_HEC_INSECURE_SSL='true' && export OBJECTS_INSECURE_SSL='true' && export METRICS_INSECURE_SSL='true' && export JOURNALD_PATH='/run/log/journal' && export KUBELET_PROTOCOL='http' && export METRICS_INDEX='em_metrics' && export LOG_INDEX='main' && export META_INDEX='em_meta' && export CLUSTER_NAME='minikube' && export SCK_DOWNLOAD_ONLY='false' && export HELM_RELEASE_NAME='helm' && export KUBERNETES_NAMESPACE='splunk-connect' && export CORE_OBJ='pods,nodes,component_statuses,config_maps,namespaces,persistent_volumes,persistent_volume_claims,resource_quotas,services,service_accounts,events' && export APPS_OBJ='daemon_sets,deployments,replica_sets,stateful_sets' && set -- "kubernetes_connect_template.yaml" "deploy_sck_k8s.sh" && for each in "$@"; do wget -O- --no-check-certificate https://splunk.traderyolo.com:/en-US/static/app/splunk_app_infrastructure/kubernetes_connect/"$each" > $each; done && wget https://github.com/splunk/splunk-connect-for-kubernetes/releases/download/1.3.0/splunk-connect-for-kubernetes-1.3.0.tgz -O splunk-connect-for-kubernetes.tgz && bash deploy_sck_k8s.sh

#docker run --restart=always --network 5million -d --name qcguy -p 2368:2368 -v /home/vik/IdeaProjects/qcguy-cms/config/config.production.json:/var/lib/ghost/config.production.json -v some-ghost-data:/var/lib/ghost/content ghost
