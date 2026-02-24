#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== OpenClaw Demo: Host Setup ==="
echo ""

# 1. Install virtualization stack
echo "[1/8] Installing KVM/libvirt/QEMU packages..."
sudo pacman -S --needed --noconfirm \
    qemu-full \
    libvirt \
    virt-install \
    dnsmasq \
    edk2-ovmf \
    libosinfo \
    cdrtools

# 2. Add user to libvirt group
echo "[2/8] Adding $USER to libvirt group..."
if ! groups "$USER" | grep -q '\blibvirt\b'; then
    sudo usermod -aG libvirt "$USER"
    echo "  Added. You may need to log out and back in (or run 'newgrp libvirt')."
else
    echo "  Already in libvirt group."
fi

# 3. Enable and start libvirtd
echo "[3/8] Enabling and starting libvirtd..."
sudo systemctl enable --now libvirtd.service

# 4. Start the default NAT network
echo "[4/8] Starting default NAT network..."
sudo virsh net-autostart default
sudo virsh net-start default 2>/dev/null || echo "  Default network already active."

# 5. Ensure storage pool exists at /var/lib/libvirt/images
echo "[5/8] Setting up libvirt storage pool..."
if virsh -c qemu:///system pool-info images-1 &>/dev/null; then
    echo "  Storage pool 'images-1' already exists."
else
    echo "  Creating storage pool 'images-1'..."
    sudo virsh pool-define-as images-1 dir --target /var/lib/libvirt/images
    sudo virsh pool-autostart images-1
    sudo virsh pool-start images-1
    echo "  Storage pool 'images-1' created and started."
fi

# 6. Generate dedicated automation SSH key (no passphrase)
echo "[6/8] Checking automation SSH key..."
if [ ! -f "$HOME/.ssh/openclaw_demo" ]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/openclaw_demo" -N "" -C "openclaw-demo-automation"
    echo "  Generated new automation key at ~/.ssh/openclaw_demo"
else
    echo "  Automation SSH key already exists."
fi

# 7. Download and install cloud image
echo "[7/8] Checking cloud image..."
CLOUD_IMAGE="/var/lib/libvirt/images/ubuntu-24.04-cloudimg-amd64.img"
LOCAL_IMAGE="$PROJECT_DIR/images/ubuntu-24.04-cloudimg-amd64.img"

if [ -f "$CLOUD_IMAGE" ]; then
    echo "  Cloud image already in libvirt storage."
elif [ -f "$LOCAL_IMAGE" ]; then
    echo "  Copying cloud image to libvirt storage..."
    sudo cp "$LOCAL_IMAGE" "$CLOUD_IMAGE"
    sudo chown libvirt-qemu:libvirt-qemu "$CLOUD_IMAGE" 2>/dev/null || true
    virsh pool-refresh images-1 2>/dev/null || true
    echo "  Cloud image installed."
else
    echo "  Downloading cloud image..."
    curl -fSL --progress-bar -o "$LOCAL_IMAGE" \
        https://cloud-images.ubuntu.com/noble/current/noble-server-cloudimg-amd64.img
    echo "  Copying to libvirt storage..."
    sudo cp "$LOCAL_IMAGE" "$CLOUD_IMAGE"
    sudo chown libvirt-qemu:libvirt-qemu "$CLOUD_IMAGE" 2>/dev/null || true
    virsh pool-refresh images-1 2>/dev/null || true
    echo "  Cloud image downloaded and installed."
fi

# 8. Fix Docker iptables FORWARD policy blocking VM traffic + VM isolation
echo "[8/8] Configuring iptables for VM internet access..."
# Docker sets iptables FORWARD policy to DROP, which blocks all VM outbound traffic.
# Add explicit ACCEPT rules for virbr0 <-> wlan0 forwarding.
OUTIF=$(ip route show default | grep -oP 'dev \K\S+')
if sudo iptables -L FORWARD -n 2>/dev/null | head -1 | grep -q "DROP"; then
    # Check if rules already exist
    if ! sudo iptables -C FORWARD -i virbr0 -o "$OUTIF" -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -i virbr0 -o "$OUTIF" -j ACCEPT
        echo "  Added FORWARD rule: virbr0 -> $OUTIF"
    fi
    if ! sudo iptables -C FORWARD -i "$OUTIF" -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -i "$OUTIF" -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        echo "  Added FORWARD rule: $OUTIF -> virbr0 (established)"
    fi
    echo "  iptables FORWARD rules configured for VM NAT."
else
    echo "  iptables FORWARD policy is ACCEPT, no Docker fix needed."
fi

# VM-to-VM isolation: drop traffic that enters AND exits virbr0 (VM-to-VM).
# Does NOT affect VM->host (INPUT chain) or VM->internet (exits via $OUTIF).
if ! sudo iptables -C FORWARD -i virbr0 -o virbr0 -j DROP 2>/dev/null; then
    sudo iptables -I FORWARD -i virbr0 -o virbr0 -j DROP
    echo "  Added FORWARD rule: drop virbr0 -> virbr0 (VM-to-VM isolation)"
fi
# NOTE: On Arch, iptables rules are NOT automatically persisted across reboots.
# To persist, run: sudo iptables-save | sudo tee /etc/iptables/iptables.rules
# Then: sudo systemctl enable --now iptables.service

echo ""
echo "=== Verification ==="
echo ""
echo "Networks:"
virsh -c qemu:///system net-list --all 2>/dev/null || virsh net-list --all
echo ""
echo "Storage pools:"
virsh -c qemu:///system pool-list --all 2>/dev/null || virsh pool-list --all
echo ""
echo "Cloud image:"
virsh -c qemu:///system vol-list images-1 2>/dev/null || virsh vol-list images-1
echo ""
echo "Bridge interface:"
ip addr show virbr0 2>/dev/null || echo "  virbr0 not yet available (may need reboot or 'newgrp libvirt')"
echo ""
echo "KVM support:"
ls -la /dev/kvm
echo ""
echo "SSH key:"
echo "  $(cat "$HOME/.ssh/openclaw_demo.pub")"
echo ""
echo "=== Host setup complete ==="
echo ""
echo "NOTE: If this is your first time, log out and back in (or run 'newgrp libvirt')"
echo "      for the libvirt group membership to take effect."
