#!/usr/bin/env bash
# Run a WP-CLI command against the live WordPress install.
#
#   ./scripts/wp.sh option get siteurl
#   ./scripts/wp.sh plugin list
#   ./scripts/wp.sh post list --post_type=page
#
# Requires kubectl with access to the cluster. From the Windows workstation the
# cluster is reached over SSH to the master node, so run this there, or use:
#   ssh lennard@192.168.1.70 'kubectl exec -n wordpress deploy/wpcli -- wp ...'
#
# NOTE: this reports the DATABASE state. The WordPress pod additionally applies
# WP_HOME/WP_SITEURL from WORDPRESS_CONFIG_EXTRA at runtime, which can differ.
# That divergence is intentional - see KNOWLEDGE_BASE.md.
set -euo pipefail

NAMESPACE="${WP_NAMESPACE:-wordpress}"

if [ $# -eq 0 ]; then
  echo "usage: $0 <wp-cli args...>" >&2
  echo "example: $0 option get siteurl" >&2
  exit 64
fi

exec kubectl exec -n "$NAMESPACE" deploy/wpcli -- wp "$@"
