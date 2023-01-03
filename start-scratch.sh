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
    --subnet=172.16.238.0/16 \
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
  #minikube start --cpus 6 --memory 16384 --disk-size 25g --driver=kvm2 --kvm-gpu --network 5million --mount-string="/home/cloud/Ideaprojects/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.housekeeping-interval=10s
  minikube start --cpus 6 --memory 16384 --disk-size 25g --driver=kvm2 --kvm-gpu --network="5million" --mount-string="/home/cloud/Ideaprojects/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000" --extra-config=kubelet.housekeeping-interval=10s
  #minikube start
  #set strictARP to true to allow for MetalLB loadbalancer
  #kubectl get configmap kube-proxy -n kube-system -o yaml | sed -e "s/strictARP: false/strictARP: false/" | kubectl apply -f - -n kube-system
  #To install MetalLB, apply the manifest
  #kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.11.0/manifests/namespace.yaml
  #kubectl apply -f metallb.yaml
  #This will deploy MetalLB to your cluster, under the metallb-system namespace
  #now install metallb config
  #kubectl apply -f metallb-config.yaml

  #to install docker container registry
  minikube addons enable registry

  #setup metrics server for minikube
  minikube addons enable metrics-server
fi
#MINIKUBEIP=$(minikube ip)
#allow minikube to connect to local docker images
#eval $(minikube -p minikube docker-env)
#################vault###########################
echo "deploying vault"
cd $HOME/Ideaprojects/vault/
bash start-vault.sh
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
kubectl apply -f $HOME/Ideaprojects/jenkins/compiled.yaml

#################container-registry#############################
#create k8s components for private container registry - NOT USED BCOZ USING MINIKUBE REGISTRY
#kubectl apply -f $HOME/Ideaprojects/container-registry/private-registry.yaml

#################qcguy#############################
#create k8s namespace for qcguy
kubectl create namespace qcguy --dry-run=client -o yaml | kubectl apply -f -
#create configmap for qcguy
kubectl create configmap qcguy-configmap --from-file=$HOME/Ideaprojects/qcguy-ghost/config -n qcguy --dry-run=true -o yaml | kubectl apply -f -
#create k8s components for qcguy
kubectl apply -f $HOME/Ideaprojects/qcguy-ghost/compiled.yaml

#################tatesremedies#############################
#create k8s namespace for tatesremedies
#kubectl create namespace tatesremedies --dry-run=client -o yaml | kubectl apply -f -
#create configmap for tatesremedies
#kubectl create configmap tatesremedies-configmap --from-file=$HOME/Ideaprojects/tatesremedies/config -n tatesremedies --dry-run=true -o yaml | kubectl apply -f -
#create k8s components for tatesremedies
#kubectl apply -f $HOME/Ideaprojects/tatesremedies/compiled.yaml

#################################build yolo jenkins pipeline remotely##########################
#wget --auth-no-challenge --user=admin --password=5ad344f0518640f62d0483084bb889bc http://13.126.143.49:8080/job/ANT//build?token=iFBDOBhNhaxL4T9ass93HRXun2JF161Z
curl -X POST https://private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com/job/trading-microservices/build?token=yolobuildstep_0
#curl -X POST https://private-cloud:117c6b563ff409adc59ecbfbbd2f795392@jenkins.traderyolo.com/job/delete_mem_leak_java/build?token=delete_mem_leak_java
##################### ONLY FOR HSBC splunk-for-hsbc-demo#############################
echo "deploying splunk"
cd $HOME/IdeaProjects/splunk-hsbc-demo/
kubectl apply -f splunk-namespace.yaml
kubectl apply -f compiled.yaml
echo "splunk deployment done. now sleeping for 2 min before setting up splunk infra."
sleep 3m
cd $HOME/IdeaProjects/splunk-hsbc-demo/Automation/splunk-monitor/
#the below command can only run in bash
export MONITORING_MACHINE='splunk.splunk.svc.cluster.local' && export HEC_TOKEN='25577715-5282-4f8b-ab9c-c8aa95a75bea' && export HEC_PORT='8088' && export GLOBAL_HEC_INSECURE_SSL='true' && export OBJECTS_INSECURE_SSL='true' && export METRICS_INSECURE_SSL='true' && export JOURNALD_PATH='/run/log/journal' && export KUBELET_PROTOCOL='http' && export METRICS_INDEX='em_metrics' && export LOG_INDEX='main' && export META_INDEX='em_meta' && export CLUSTER_NAME='minikube' && export SCK_DOWNLOAD_ONLY='false' && export HELM_RELEASE_NAME='helm' && export KUBERNETES_NAMESPACE='splunk-connect' && export CORE_OBJ='pods,nodes,component_statuses,config_maps,namespaces,persistent_volumes,persistent_volume_claims,resource_quotas,services,service_accounts,events' && export APPS_OBJ='daemon_sets,deployments,replica_sets,stateful_sets' && files=("kubernetes_connect_template.yaml" "deploy_sck_k8s.sh") && for each in "${files[@]}"; do wget -O- --no-check-certificate https://splunk.traderyolo.com:/en-US/static/app/splunk_app_infrastructure/kubernetes_connect/"$each" >$each; done && wget https://github.com/splunk/splunk-connect-for-kubernetes/releases/download/1.3.0/splunk-connect-for-kubernetes-1.3.0.tgz -O splunk-connect-for-kubernetes.tgz && bash deploy_sck_k8s.sh
#the below command can run in sh and bash.
#export MONITORING_MACHINE='splunk.splunk.svc.cluster.local' && export HEC_TOKEN='25577715-5282-4f8b-ab9c-c8aa95a75bea' && export HEC_PORT='8088' && export GLOBAL_HEC_INSECURE_SSL='true' && export OBJECTS_INSECURE_SSL='true' && export METRICS_INSECURE_SSL='true' && export JOURNALD_PATH='/run/log/journal' && export KUBELET_PROTOCOL='http' && export METRICS_INDEX='em_metrics' && export LOG_INDEX='main' && export META_INDEX='em_meta' && export CLUSTER_NAME='minikube' && export SCK_DOWNLOAD_ONLY='false' && export HELM_RELEASE_NAME='helm' && export KUBERNETES_NAMESPACE='splunk-connect' && export CORE_OBJ='pods,nodes,component_statuses,config_maps,namespaces,persistent_volumes,persistent_volume_claims,resource_quotas,services,service_accounts,events' && export APPS_OBJ='daemon_sets,deployments,replica_sets,stateful_sets' && set -- "kubernetes_connect_template.yaml" "deploy_sck_k8s.sh" && for each in "$@"; do wget -O- --no-check-certificate https://splunk.traderyolo.com:/en-US/static/app/splunk_app_infrastructure/kubernetes_connect/"$each" > $each; done && wget https://github.com/splunk/splunk-connect-for-kubernetes/releases/download/1.3.0/splunk-connect-for-kubernetes-1.3.0.tgz -O splunk-connect-for-kubernetes.tgz && bash deploy_sck_k8s.sh

#docker run --restart=always --network 5million -d --name qcguy -p 2368:2368 -v /home/vik/IdeaProjects/qcguy-cms/config/config.production.json:/var/lib/ghost/config.production.json -v some-ghost-data:/var/lib/ghost/content ghost
