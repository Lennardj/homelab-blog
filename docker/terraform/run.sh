#!/bin/sh
set -e
cd /work/terraform/proxmox
terraform init
terraform apply -auto-approve
terraform output -json > /artifacts/output.json