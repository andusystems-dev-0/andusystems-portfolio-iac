#!/bin/bash
# Do a full redeploy of everything
ansible-playbook -i ansible/inventory/portfolio ansible/configurations/portfolio.yml --tags vms,kubernetes,metallb,apps,install -K