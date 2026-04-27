#!/bin/bash
# Build and deploy the portfolio game to the portfolio cluster
ansible-playbook -i ansible/inventory/portfolio ansible/configurations/roles/deploy-portfolio.yml --tags deploy-portfolio,install -K
