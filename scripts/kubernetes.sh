#!/bin/bash

# Create VMs on Proxmox
ansible-playbook -i ansible/inventory/portfolio ansible/configurations/roles/kubernetes.yml --tags kubernetes,install -K