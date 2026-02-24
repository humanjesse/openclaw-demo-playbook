#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

echo "=== OpenClaw Demo: Ubuntu Host Setup ==="
echo ""

# 1. Install virtualization stack
echo "[1/14] Installing KVM/libvirt/QEMU packages..."
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
echo "[2/14] Adding $USER to libvirt and kvm groups..."
for grp in libvirt kvm; do
    if ! groups "$USER" | grep -qw "$grp"; then
        sudo usermod -aG "$grp" "$USER"
        echo "  Added $USER to $grp group."
    else
        echo "  Already in $grp group."
    fi
done

# 3. Enable and start libvirtd
echo "[3/14] Enabling and starting libvirtd..."
sudo systemctl enable --now libvirtd.service

# 4. Start the default NAT network
echo "[4/14] Starting default NAT network..."
sudo virsh net-autostart default
sudo virsh net-start default 2>/dev/null || echo "  Default network already active."

# 5. Ensure storage pool exists at /var/lib/libvirt/images
echo "[5/14] Setting up libvirt storage pool..."
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
echo "[6/14] Checking automation SSH key..."
if [ ! -f "$HOME/.ssh/openclaw_demo" ]; then
    ssh-keygen -t ed25519 -f "$HOME/.ssh/openclaw_demo" -N "" -C "openclaw-demo-automation"
    echo "  Generated new automation key at ~/.ssh/openclaw_demo"
else
    echo "  Automation SSH key already exists."
fi

# 7. Download and install cloud image
echo "[7/14] Checking cloud image..."
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

# 8. Fix Docker/iptables FORWARD policy blocking VM traffic + VM isolation
echo "[8/14] Configuring iptables for VM internet access..."
OUTIF=$(ip route show default | grep -oP 'dev \K\S+')

# VM-to-VM isolation FIRST: insert at position 1 so it's always the top rule.
# Drops traffic that enters AND exits virbr0 (VM-to-VM).
# Does NOT affect VM->host (INPUT chain) or VM->internet (exits via $OUTIF).
if ! sudo iptables -C FORWARD -i virbr0 -o virbr0 -j DROP 2>/dev/null; then
    sudo iptables -I FORWARD 1 -i virbr0 -o virbr0 -j DROP
    echo "  Added FORWARD rule at pos 1: drop virbr0 -> virbr0 (VM-to-VM isolation)"
fi

# Docker fix: Docker sets FORWARD policy to DROP, blocking all VM outbound traffic.
# Insert at positions 2-3 (after the VM isolation DROP rule above).
if sudo iptables -L FORWARD -n 2>/dev/null | head -1 | grep -q "DROP"; then
    if ! sudo iptables -C FORWARD -i virbr0 -o "$OUTIF" -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD 2 -i virbr0 -o "$OUTIF" -j ACCEPT
        echo "  Added FORWARD rule at pos 2: virbr0 -> $OUTIF"
    fi
    if ! sudo iptables -C FORWARD -i "$OUTIF" -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; then
        sudo iptables -I FORWARD 3 -i "$OUTIF" -o virbr0 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
        echo "  Added FORWARD rule at pos 3: $OUTIF -> virbr0 (established)"
    fi
    echo "  iptables FORWARD rules configured."
else
    echo "  iptables FORWARD policy is ACCEPT, no Docker fix needed."
fi

# Persist iptables rules across reboots
echo iptables-persistent iptables-persistent/autosave_v4 boolean true | sudo debconf-set-selections
echo iptables-persistent iptables-persistent/autosave_v6 boolean true | sudo debconf-set-selections
sudo apt-get install -y iptables-persistent
sudo netfilter-persistent save
echo "  iptables rules persisted."

# 9. Install Ollama with GPU support
echo "[9/14] Setting up Ollama..."
if command -v ollama &>/dev/null; then
    echo "  Ollama already installed: $(ollama --version)"
else
    echo "  Installing Ollama..."
    curl -fsSL https://ollama.com/install.sh | sh
    echo "  Ollama installed."
fi

# Enable GPU persistence mode (keeps NVIDIA driver loaded, eliminates cold-start latency)
echo "  Enabling GPU persistence mode..."
if nvidia-smi &>/dev/null; then
    sudo nvidia-smi -pm 1
fi

# Configure Ollama: bind all interfaces, flash attention, keep model in VRAM
# NOTE: Ollama only supports a single OLLAMA_HOST bind address. Binding to 0.0.0.0 is
# required for VMs on virbr0 (192.168.122.0/24) to reach it. Step 10 restricts access to
# localhost and virbr0 via iptables. If rules are flushed (e.g. Docker restart), Ollama
# is exposed — run `netfilter-persistent reload` to restore.
echo "  Configuring Ollama..."
sudo mkdir -p /etc/systemd/system/ollama.service.d
sudo tee /etc/systemd/system/ollama.service.d/override.conf > /dev/null << 'EOF'
[Service]
Environment="OLLAMA_HOST=0.0.0.0:11434"
Environment="OLLAMA_KEEP_ALIVE=1h"
Environment="OLLAMA_FLASH_ATTENTION=1"
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

# 10. Restrict Ollama port to VMs and localhost only
echo "[10/14] Restricting Ollama port to VM network and localhost..."
# Allow Ollama from localhost (for ollama pull, health checks, CLI)
if ! sudo iptables -C INPUT -i lo -p tcp --dport 11434 -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -i lo -p tcp --dport 11434 -j ACCEPT
    echo "  Added INPUT rule: allow 11434 from lo"
fi
# Allow Ollama from VM bridge network
if ! sudo iptables -C INPUT -i virbr0 -p tcp --dport 11434 -j ACCEPT 2>/dev/null; then
    sudo iptables -I INPUT -i virbr0 -p tcp --dport 11434 -j ACCEPT
    echo "  Added INPUT rule: allow 11434 from virbr0"
fi
# Drop Ollama from all other interfaces (WiFi, public, etc.)
if ! sudo iptables -C INPUT -p tcp --dport 11434 -j DROP 2>/dev/null; then
    sudo iptables -A INPUT -p tcp --dport 11434 -j DROP
    echo "  Added INPUT rule: drop 11434 from all other sources"
fi
sudo netfilter-persistent save
echo "  Ollama port restricted and persisted."

# 11. Download embedding model for VMs
echo "[11/14] Downloading embedding model..."
EMBED_DIR="$PROJECT_DIR/models"
EMBED_FILE="$EMBED_DIR/embeddinggemma-300m-qat-Q8_0.gguf"
mkdir -p "$EMBED_DIR"
if [ -f "$EMBED_FILE" ]; then
    echo "  Embedding model already downloaded."
else
    curl -fSL --progress-bar -o "$EMBED_FILE" \
        "https://huggingface.co/ggml-org/embeddinggemma-300m-qat-q8_0-GGUF/resolve/main/embeddinggemma-300m-qat-Q8_0.gguf"
    echo "  Embedding model downloaded ($(du -h "$EMBED_FILE" | cut -f1))."
fi

# 12. Set up Python virtual environment
echo "[12/14] Setting up Python virtual environment..."
sudo apt-get install -y python3-venv python3-pip
if [ ! -d "$PROJECT_DIR/.venv" ]; then
    python3 -m venv "$PROJECT_DIR/.venv"
    echo "  Created virtual environment."
else
    echo "  Virtual environment already exists."
fi
"$PROJECT_DIR/.venv/bin/pip" install --upgrade pip
"$PROJECT_DIR/.venv/bin/pip" install -r "$PROJECT_DIR/requirements.txt"
echo "  Python dependencies installed."

# 13. Create provisioning API systemd service
echo "[13/14] Setting up provisioning API service..."
sudo tee /etc/systemd/system/openclaw-provision-api.service > /dev/null << SVCEOF
[Unit]
Description=OpenClaw Provisioning API
After=network.target libvirtd.service ollama.service

[Service]
Type=simple
User=$USER
WorkingDirectory=$PROJECT_DIR
ExecStart=$PROJECT_DIR/.venv/bin/uvicorn api.main:app --host 0.0.0.0 --port 8000
Restart=on-failure
RestartSec=5
EnvironmentFile=$PROJECT_DIR/.env

[Install]
WantedBy=multi-user.target
SVCEOF
sudo systemctl daemon-reload
sudo systemctl enable --now openclaw-provision-api.service
echo "  Provisioning API service started."

# Verify GPU detection
echo ""
echo "  GPU status:"
if nvidia-smi &>/dev/null; then
    nvidia-smi --query-gpu=name,memory.total,memory.free --format=csv
else
    echo "  WARNING: nvidia-smi not found. Ollama will use CPU only."
fi

# 14. Verify setup
echo "[14/14] Verifying setup..."
echo ""
echo "=== Verification ==="
echo ""
echo "iptables (security rules):"
echo "  FORWARD chain (VM isolation):"
sudo iptables -L FORWARD -n 2>/dev/null | grep -E "virbr0.*virbr0.*DROP" && echo "    VM-to-VM isolation: OK" || echo "    WARNING: VM-to-VM isolation rule not found"
echo "  INPUT chain (Ollama restriction):"
sudo iptables -L INPUT -n 2>/dev/null | grep -E "11434.*DROP" && echo "    Ollama port restriction: OK" || echo "    WARNING: Ollama port restriction rule not found"
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
echo "Provisioning API:"
if curl -s -m 2 http://localhost:8000/health 2>/dev/null | grep -q ok; then
    echo "  API is running on port 8000."
else
    echo "  WARNING: API not yet responding (check: sudo journalctl -u openclaw-provision-api)"
fi
echo ""
echo "=== Host setup complete ==="
echo ""
echo "NOTE: If this is your first time, log out and back in (or run 'newgrp libvirt')"
echo "      for the libvirt/kvm group membership to take effect."
