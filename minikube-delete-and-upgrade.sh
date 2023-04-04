#! /bin/sh

# Minikube update script file

minikube delete && \
sudo rm -rf /usr/local/bin/minikube && sudo rm -r ${HOME}/.minikube && sudo curl -Lo minikube https://storage.googleapis.com/minikube/releases/latest/minikube-linux-amd64 && \
sudo chmod +x minikube && \
sudo cp minikube /usr/local/bin/ && \
sudo rm minikube && \
minikube start --driver kvm2 --kvm-gpu &&\

# Enabling addons: ingress, dashboard
minikube addons enable ingress && \
minikube addons enable dashboard && \
minikube addons enable metrics-server && \
minikube addons enable nvidia-gpu-device-plugin && \
minikube addons enable nvidia-driver-installer && \
# Showing enabled addons
echo '\n\n\033[4;33m Enabled Addons \033[0m' && \
minikube addons list | grep STATUS && minikube addons list | grep enabled && \

# Showing current status of Minikube
echo '\n\n\033[4;33m Current status of Minikube \033[0m' && minikube status