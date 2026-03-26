#!/bin/sh
set -e
cd /work/terraform/proxmox
terraform init
terraform apply -auto-approve
VM_IPS=$(terraform output -json all_nodes_ips | jq -r '.[]')
for IP in $VM_IPS; do
  echo "Waiting for SSH on $IP..."
  until nc -z -w5 "$IP" 22 2>/dev/null; do
    sleep 5
  done
  echo "$IP is ready"
done
terraform output -json > /artifacts/output.json.tmp
mv /artifacts/output.json.tmp /artifacts/output.json