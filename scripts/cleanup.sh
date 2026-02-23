#!/usr/bin/env bash
set -euo pipefail

echo "=== OpenClaw Demo: Cleanup ==="
echo ""

# Destroy all VMs that match our naming pattern
echo "Checking for demo VMs..."
VM_LIST=$(virsh list --all --name 2>/dev/null | grep -v '^$' || true)

if [ -z "$VM_LIST" ]; then
    echo "  No VMs found."
else
    for vm in $VM_LIST; do
        echo "  Destroying: $vm"
        virsh destroy "$vm" 2>/dev/null || true
        virsh undefine "$vm" --remove-all-storage 2>/dev/null || true
    done
fi

# Clean up cloud-init ISOs
echo ""
echo "Cleaning up cloud-init ISOs..."
rm -fv /tmp/cloud-init-*.iso 2>/dev/null || echo "  No ISOs found."

# Clean up temp cloud-init directories
echo ""
echo "Cleaning up temp cloud-init directories..."
rm -rfv /tmp/cloud-init-*/ 2>/dev/null || echo "  No temp dirs found."

echo ""
echo "=== Cleanup complete ==="
echo "NOTE: Cloudflare tunnels must be deleted via the API or Cloudflare dashboard."
