#!/bin/sh
set -e
cd /work/terraform/proxmox

# Restore state from persistent volume if it exists (skip if same path)
if [ -f /tfstate/terraform.tfstate ] && ! [ /tfstate/terraform.tfstate -ef terraform.tfstate ]; then
  cp /tfstate/terraform.tfstate .
fi

terraform init
terraform apply -auto-approve

# Persist state for next run (skip if same path)
if ! [ /tfstate/terraform.tfstate -ef terraform.tfstate ]; then
  cp terraform.tfstate /tfstate/terraform.tfstate
fi
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