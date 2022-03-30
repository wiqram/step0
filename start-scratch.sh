#!/bin/sh

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
    minikube start --cpus 6 --memory 16384 --network 5million --mount-string="/home/cloud/Ideaprojects/minikube-mnt/:/mnt" --mount --insecure-registry="172.16.238.2:5000"
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
fi

#allow minikube to connect to local docker images
#eval $(minikube -p minikube docker-env)
#################jenkins###########################
#create k8s components for jenkins
kubectl apply -f $HOME/Ideaprojects/jenkins/compiled.yaml

#################container-registry#############################
#create k8s components for private container registry - NOT USED BCOZ USING MINIKUBE REGISTRY
#kubectl apply -f $HOME/Ideaprojects/container-registry/private-registry.yaml

#################qcguy#############################
#create k8s namespace for qcguy
kubectl create namespace qcguy --dry-run=client -o yaml | kubectl apply -f -
#create configmap for qcguy
kubectl create configmap qcguy-configmap --from-file=$HOME/Ideaprojects/qcguy-ghost/config -n qcguy
#create k8s components for qcguy
kubectl apply -f $HOME/Ideaprojects/qcguy-ghost/compiled.yaml


#docker run --restart=always --network 5million -d --name qcguy -p 2368:2368 -v /home/vik/IdeaProjects/qcguy-cms/config/config.production.json:/var/lib/ghost/config.production.json -v some-ghost-data:/var/lib/ghost/content ghost