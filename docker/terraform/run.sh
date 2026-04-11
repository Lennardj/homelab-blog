#!/bin/sh
set -e
cd /work/terraform/proxmox

# Restore state from persistent volume if it exists (skip if same path)
if [ -f /tfstate/terraform.tfstate ] && ! [ /tfstate/terraform.tfstate -ef terraform.tfstate ]; then
  cp /tfstate/terraform.tfstate .
fi

# Stop existing K8s VMs before force_create (Proxmox can't destroy running VMs)

PVE_API="${TF_VAR_proxmox_api_url}"
PVE_AUTH="Authorization: PVEAPIToken=${TF_VAR_proxmox_api_token_id}=${TF_VAR_proxmox_api_token_secret}"
PVE_NODE="${TF_VAR_target_node:-pve}"
for VMID in 150 200 201; do
  STATUS=$(curl -sk -H "$PoVE_AUTH" \
    "${PVE_API}/nodes/${PVE_NODE}/qemu/${VMID}/status/current" 2>/dev/null \
    | jq -r '.data.status // empty')
  if [ "$STATUS" = "running" ]; then
    echo "Stopping VM $VMID..."
    curl -sk -X POST -H "$PVE_AUTH" \
      "${PVE_API}/nodes/${PVE_NODE}/qemu/${VMID}/status/stop" >/dev/null
    sleep 10
  fi
done

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

