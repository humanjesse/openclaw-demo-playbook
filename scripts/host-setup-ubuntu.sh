#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== OpenClaw Demo: Ubuntu Host Setup ==="
echo ""

# 1. Install virtualization stack
echo "[1/9] Installing KVM/libvirt/QEMU packages..."
sudo apt-get update
sudo apt-get install -y \
    qemu-kvm \
    qemu-utils \
    libvirt-daemon-system \
    libvirt-clients \
    virtinst \
    genisoimage \
    ovmf \
    libosinfo-bin \
    dnsmasq-base \
    bridge-utils

# 2. Add user to libvirt and kvm groups
echo "[2/9] Adding $USER to libvirt and kvm groups..."
for grp in libvirt kvm; do
    if ! groups "$USER" | grep -qw "$grp"; then
        sudo usermod -aG "$grp" "$USER"
        echo "  Added $USER to $grp group."
    else
        echo "  Already in $grp group."
    fi
done

# 3. Enable and start libvirtd
echo "[3/9] Enabling and starting libvirtd..."
sudo systemctl enable --now libvirtd.service

# 4. Start the default NAT network
echo "[4/9] Starting default NAT network..."
sudo virsh net-autostart default
sudo virsh net-start default 2>/dev/null || echo "  Default network already active."

# 5. Ensure storage pool exists at /var/lib/libvirt/images
echo "[5/9] Setting up libvirt storage pool..."
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
echo "[6/9] Checking automation SSH key..."
if [ ! -f "$HOME/.ssh/openclaw_demo" ]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/openclaw_demo" -N "" -C "openclaw-demo-automation"
    echo "  Generated new automation key at ~/.ssh/openclaw_demo"
else
    echo "  Automation SSH key already exists."
fi

# 7. Download and install cloud image
echo "[7/9] Checking cloud image..."
CLOUD_IMAGE="/var/lib/libvirt/images/ubuntu-24.04-cloudimg-amd64.img"
LOCAL_IMAGE="$PROJECT_DIR/images/ubuntu-24.04-cloudimg-amd64.img"
mkdir -p "$PROJECT_DIR/images"

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

# 8. Fix Docker/iptables FORWARD policy blocking VM traffic
echo "[8/9] Configuring iptables for VM internet access..."
OUTIF=$(ip route show default | grep -oP 'dev \K\S+')
if sudo iptables -L FORWARD -n 2>/dev/null | head -1 | grep -q "DROP"; then
    # Docker sets FORWARD policy to DROP, which blocks all VM outbound traffic.
    if ! sudo iptables -C FORWARD -i virbr0 -o "$OUTIF" -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -i virbr0 -o "$OUTIF" -j ACCEPT
        echo "  Added FORWARD rule: virbr0 -> $OUTIF"
    fi
    if ! sudo iptables -C FORWARD -i "$OUTIF" -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD -i "$OUTIF" -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        echo "  Added FORWARD rule: $OUTIF -> virbr0 (established)"
    fi
    # Persist iptables rules across reboots
    echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
    echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
    sudo apt-get install -y iptables-persistent
    sudo netfilter-persistent save
    echo "  iptables FORWARD rules configured and persisted."
else
    echo "  iptables FORWARD policy is ACCEPT, no changes needed."
fi

# 9. Install Ollama with GPU support
echo "[9/9] Setting up Ollama..."
if command -v ollama &>/dev/null; then
    echo "  Ollama already installed: $(ollama --version)"
else
    echo "  Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    echo "  Ollama installed."
fi

# Configure Ollama to listen on all interfaces (so VMs can reach it via virbr0)
echo "  Configuring Ollama to bind 0.0.0.0:11434..."
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=1h"
EOF
sudo systemctl daemon-reload
sudo systemctl enable --now ollama.service
sudo systemctl restart ollama.service

# Wait for Ollama to be ready
echo "  Waiting for Ollama to start..."
for i in $(seq 1 30); do
    if curl -s -m 2 http://localhost:11434/api/tags >/dev/null 2>&1; then
        echo "  Ollama is running."
        break
    fi
    sleep 1
done

# Read model from .env if available, otherwise default to qwen3:8b
MODEL="qwen3:8b"
if [ -f "$PROJECT_DIR/.env" ]; then
    ENV_MODEL=$(grep -oP '^OLLAMA_MODEL=\K.*' "$PROJECT_DIR/.env" || true)
    if [ -n "$ENV_MODEL" ]; then
        MODEL="$ENV_MODEL"
    fi
fi

# Pull model only if not already downloaded
if ollama list 2>/dev/null | grep -q "^${MODEL}"; then
    echo "  Model $MODEL already pulled."
else
    echo "  Pulling model $MODEL (this may take a few minutes)..."
    ollama pull "$MODEL"
    echo "  Model $MODEL ready."
fi

# Verify GPU detection
echo ""
echo "  GPU status:"
if nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv
else
    echo "  WARNING: nvidia-smi not found. Ollama will use CPU only."
fi

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
echo "mkisofs:"
which mkisofs 2>/dev/null || echo "  WARNING: mkisofs not found! Run: sudo ln -s /usr/bin/genisoimage /usr/bin/mkisofs"
echo ""
echo "Ollama from bridge IP:"
curl -s http://192.168.122.1:11434/api/tags 2>/dev/null | head -c 200 || echo "  WARNING: Ollama not reachable from bridge IP (virbr0 may not be up yet)"
echo ""
echo "=== Host setup complete ==="
echo ""
echo "NOTE: If this is your first time, log out and back in (or run 'newgrp libvirt')"
echo "      for the libvirt/kvm group membership to take effect."
