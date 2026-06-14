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
  # Resource-efficient start (see plan.md "Cluster resource efficiency" section). Key changes vs the old line:
  #   --cpus 16            : CPU is compressible (throttles, never OOM-kills) so we give burst headroom while
  #                          still leaving ~8 threads for the host (IntelliJ + Chrome). Mem is the hard limit, not CPU.
  #   --memory 32768       : unchanged 32G envelope; reserves ~14G for OS/Docker/nginx-proxy-manager/IntelliJ/Chrome.
  #   kubelet system/kube-reserved + eviction-hard : the docker driver reports the FULL host (24CPU/49G) as node
  #                          capacity while Docker hard-caps the container at 12-16CPU/32G via cgroups. Without these
  #                          the scheduler silently over-commits past 32G and the host kernel OOM-kills inside the
  #                          cgroup (no swap = abrupt pod/node death). These flags make the kubelet reserve headroom
  #                          and evict BEFORE the cgroup limit is hit. NOTE: also add zram swap on the host (see plan.md).
  minikube start --cpus 16 --memory 32768 --disk-size 40g --driver=docker --network 5million --gpus all --mount-string="/mnt/minikube-backups/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.system-reserved=cpu=1,memory=2Gi --extra-config=kubelet.kube-reserved=cpu=1,memory=2Gi --extra-config=kubelet.eviction-hard="memory.available<1Gi,nodefs.available<10%" --extra-config=kubelet.housekeeping-interval=10s --extra-config=kubelet.authentication-token-webhook=true --extra-config=kubelet.authorization-mode=Webhook --extra-config=scheduler.bind-address=0.0.0.0 --extra-config=controller-manager.bind-address=0.0.0.0
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
#to install docker container registry
minikube addons enable registry
#setup metrics server for minikube - NOT NEEDED because of grafana and prometheus installation
#minikube addons enable metrics-server
#minikube addons enable ingress
#minikube addons enable dashboard
#minikube addons enable metrics-server
minikube addons enable nvidia-gpu-device-plugin
#minikube addons enable nvidia-driver-installer
#MINIKUBEIP=$(minikube ip)
#allow minikube to connect to local docker images
#eval $(minikube -p minikube docker-env)
###########x`######grafana-prometheus###########################
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
cd $HOME/Ideaprojects/vault/
bash start-vault.sh
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

#################vault-secrets-sync (Jenkins job + credentials)#################
# Recreate the vault-secrets-sync pipeline job and its credentials (sops-age-key
# + the per-app AppRole role_id/secret_id that start-vault.sh just regenerated
# into ~/.vault/jenkins-approle/). MUST run after Jenkins is up. On a fresh Vault
# the AppRole secret_ids change, so this re-sync keeps Jenkins' credentials valid.
# Best-effort: never abort the bootstrap. Logic lives in the vault repo.
echo "configuring vault-secrets-sync Jenkins pipeline + credentials"
JENKINS_AUTH=$(grep -oE 'private-cloud:[0-9a-f]+@jenkins' "$0" | head -1 | sed 's/@jenkins//')
JENKINS_NODEPORT="http://$(minikube ip 2>/dev/null || echo 172.16.238.2):30380"
for i in $(seq 1 60); do
  curl -sf -u "$JENKINS_AUTH" "$JENKINS_NODEPORT/api/json?tree=mode" >/dev/null 2>&1 && { echo "jenkins API ready"; break; }
  echo "waiting for jenkins API... ($i)"; sleep 5
done
JENKINS_URL="$JENKINS_NODEPORT" JENKINS_USER="${JENKINS_AUTH%%:*}" JENKINS_TOKEN="${JENKINS_AUTH#*:}" \
  bash "$HOME/Ideaprojects/vault/scripts/setup-jenkins-pipeline.sh" \
  || echo "WARN: vault-secrets-sync Jenkins setup failed; re-run vault/scripts/setup-jenkins-pipeline.sh manually."

#################container-registry#############################
#create k8s components for private container registry - NOT USED BCOZ USING MINIKUBE REGISTRY
#kubectl apply -f $HOME/Ideaprojects/container-registry/private-registry.yaml

#################qcguy#############################
#create k8s namespace for qcguy
kubectl create namespace qcguy --dry-run=client -o yaml | kubectl apply -f -
#create configmap for qcguy
kubectl create configmap qcguy-configmap --from-file=$HOME/Ideaprojects/qcguy-ghost/config -n qcguy --dry-run=client -o yaml | kubectl apply -f -
#create k8s components for qcguy
kubectl apply -f $HOME/Ideaprojects/qcguy-ghost/compiled.yaml

##################qcx && predictonomy#############################
##create k8s namespace for qcx
#kubectl create namespace qcx --dry-run=client -o yaml | kubectl apply -f -
##create configmap for qcx
#kubectl create configmap qcguy-configmap --from-file=$HOME/Ideaprojects/qcguy-ghost/config -n qcguy --dry-run=client -o yaml | kubectl apply -f -
##create k8s components for qcguy
#kubectl apply -f $HOME/IdeaProjects/qcx/k8s/deployment.yaml
#curl -X POST https://jenkins.traderyolo.com/job/QCX/build?token=qcx
#curl -X POST https://jenkins.traderyolo.com/job/predictonomy/build?token=predict
echo "building predictonomy"
curl -X POST https://private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com/job/predictonomy/build?token=predict
#curl -X POST https://private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com/job/QCX/build?token=qcx

#################Ollama#############################
# Deploy ollama via its Jenkins job (wiqram/ollama Jenkinsfile): it creates the
# `ollama` namespace + the `vault-secrets` ServiceAccount and applies the ollama
# + webui deployments, which fetch kv/ollama/* through the Vault agent injector.
# The Vault side (ollama-role/policy, k8s auth config, kv/ollama/* seed) is set
# up by start-vault.sh above. The ollama job has no build token, so trigger it as
# the authenticated user (the API token authorises the build, no token needed).
echo "building ollama"
curl -X POST https://private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com/job/ollama/build

#################tatesremedies#############################
#create k8s namespace for tatesremedies
#kubectl create namespace tatesremedies --dry-run=client -o yaml | kubectl apply -f -
#create configmap for tatesremedies
#kubectl create configmap tatesremedies-configmap --from-file=$HOME/Ideaprojects/tatesremedies/config -n tatesremedies --dry-run=true -o yaml | kubectl apply -f -
#create k8s components for tatesremedies
#kubectl apply -f $HOME/Ideaprojects/tatesremedies/compiled.yaml

#################################build yolo jenkins pipeline remotely##########################
echo "building yolo pipeline but before that sleeping for 1 min"
sleep 1m
#wget --auth-no-challenge --user=admin --password=5ad344f0518640f62d0483084bb889bc http://13.126.143.49:8080/job/ANT//build?token=iFBDOBhNhaxL4T9ass93HRXun2JF161Z
curl -X POST https://private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com/job/trading-microservices/build?token=yolobuildstep_0
#curl -X POST https://private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com/job/delete_mem_leak_java/build?token=delete_mem_leak_java
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
