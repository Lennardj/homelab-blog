#!/bin/sh
set -e
cd /work/terraform/proxmox
terraform init
terraform apply -auto-approve
sleep 300
terraform output -json > /artifacts/output.json.tmp
mv /artifacts/output.json.tmp /artifacts/output.json