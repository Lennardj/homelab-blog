#!/bin/bash
set -euo pipefail

OUTPUT_JSON="/artifacts/output.json"

echo "⏳ Waiting for Terraform to produce ${OUTPUT_JSON}..."

# wait up to 10 minutes (300 * 2s)
for i in {1..300}; do
  if [[ -s "$OUTPUT_JSON" ]] && jq -e '.all_nodes_ips.value | length > 0' "$OUTPUT_JSON" >/dev/null 2>&1; then
    echo "✅ Terraform output is ready."
    break
  fi
  sleep 2
done

# fail loud if still not ready
if ! [[ -s "$OUTPUT_JSON" ]] || ! jq -e '.all_nodes_ips.value | length > 0' "$OUTPUT_JSON" >/dev/null 2>&1; then
  echo "❌ Terraform output.json not ready or invalid."
  echo "---- output.json (first 60 lines) ----"
  head -n 60 "$OUTPUT_JSON" || true
  exit 1
fi

echo "📄 Building inventory..."
python3 /work/scripts/build_inventory.py

echo "🧩 Running playbook..."
cd /work/ansible
ansible-playbook -i /work/ansible/inventory/hosts.ini playbook.yml