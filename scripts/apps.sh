#!/bin/bash
# Install Networking Apps for Kubernetes
ansible-playbook -i ansible/inventory/portfolio ansible/configurations/apps.yml --tags apps,install