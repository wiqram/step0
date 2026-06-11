#!/bin/bash
sudo apt clean
sudo apt autoclean
sudo apt autoremove -y
sudo journalctl --vacuum-size=500M
sudo rm -rf /var/tmp/*
sudo rm -rf /var/tmp/*
docker system prune -a -f
docker volume prune -f
docker builder prune -a -f
minikube ssh -- docker system df
minikube ssh -- docker system prune -a -f