# Ubuntu Demo Machine Deployment Guide

Final setup process for deploying OpenClaw provisioning stack on Ubuntu Server with NVIDIA GPUs.

## Prerequisites

- Ubuntu Server with sudo access (tested on Ubuntu 24.04, Python 3.12)
- SSH access (via OpenVPN or direct)
- NVIDIA GPUs (V100/B200) with drivers installed
- Cloudflare account with API token, account ID, zone ID, and a domain

Verify basics:
```bash
which curl git python3 && python3 --version
ls -la /dev/kvm  # must exist — if not, enable virtualization in BIOS
```

Install if missing:
```bash
sudo apt update && sudo apt install -y curl git python3 python3-venv python3-pip
```

## Step 1: Install Ollama + Pull Model

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull devstral-2:123b  # or whatever model you want
```

## Step 2: Clone Repo

```bash
git clone https://github.com/humanjesse/openclaw-demo-playbook.git ~/openclaw-provision
cd ~/openclaw-provision
```

## Step 3: Configure Environment

```bash
cp .env.example .env
nano .env
```

Fill in:
```
CF_API_TOKEN=<your-cloudflare-api-token>
CF_ACCOUNT_ID=<your-cloudflare-account-id>
CF_ZONE_ID=<your-cloudflare-zone-id>
CF_DOMAIN=zodollama.com
ANSIBLE_PLAYBOOK_DIR=./ansible/playbooks
VM_RAM_MB=4096
VM_VCPUS=4
OLLAMA_MODEL=devstral-2:123b
```

```bash
chmod 600 .env
```

## Step 4: Run Host Setup

```bash
chmod +x scripts/host-setup-ubuntu.sh
./scripts/host-setup-ubuntu.sh
```

This installs: KVM/QEMU/libvirt, creates storage pool, generates SSH key, downloads Ubuntu cloud image, configures iptables for VM NAT, configures Ollama to bind `0.0.0.0:11434` (so VMs can reach it via bridge IP).

After completion, **log out and SSH back in** for group membership to take effect.

## Step 5: Verify Setup

```bash
sudo virsh net-list --all          # default network active
sudo virsh pool-list --all         # images-1 pool active
sudo virsh vol-list images-1       # cloud image present
ls -la /dev/kvm                    # KVM accessible
curl http://192.168.122.1:11434/api/tags  # Ollama reachable from bridge IP
nvidia-smi                         # GPUs visible
```

## Step 6: Install Python Dependencies

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

If `python3 -m venv` fails:
```bash
sudo apt install -y python3.12-venv
```

## Step 7: Start the API

```bash
source .venv/bin/activate
uvicorn api.main:app --host 0.0.0.0 --port 8000
```

Verify: `curl http://localhost:8000/api/v1/health` (from another terminal)

## Step 8: Provision a VM

From a second terminal:
```bash
curl -s -X POST http://localhost:8000/api/v1/provision \
  -H "Content-Type: application/json" \
  -d '{"tenant_name": "demo-test-01"}' | jq
```

Poll status (replace `<task_id>` with the returned ID):
```bash
while true; do curl -s http://localhost:8000/api/v1/status/<task_id> | jq; sleep 10; done
```

Wait for `"status": "ready"`. Takes ~5-10 minutes for cloud-init to complete.

## Step 9: Approve Device Pairing

Open the `gateway_url` from the poll output in your browser. The dashboard will show "pairing required".

From the demo machine, approve the pairing:
```bash
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> openclaw devices list --json
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> openclaw devices approve <requestId>
```

Each new browser/device that connects needs its own approval.

## Step 10: Fix Context Window (if needed)

If the agent complains about context window being too small:
```bash
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> 'python3 -c "
import json
f=\"/home/openclaw/.openclaw/openclaw.json\"
c=json.load(open(f))
for m in c[\"models\"][\"providers\"][\"ollama\"][\"models\"]:
    m[\"contextWindow\"]=262144
    m[\"maxTokens\"]=16384
json.dump(c,open(f,\"w\"),indent=2)
print(\"done\")
"'
```

Restart the gateway:
```bash
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> sudo systemctl restart openclaw-gateway
```

## Cleanup

Delete a provisioned VM and its tunnel:
```bash
curl -s -X DELETE http://localhost:8000/api/v1/provision/<tenant_name> | jq
```

## Known Issues

- **Group membership not inherited by subprocesses**: Playbooks use `virsh -c qemu:///system` explicitly to avoid relying on libvirt group membership in subprocess chains
- **Docker iptables FORWARD DROP**: If Docker is installed, it sets iptables FORWARD policy to DROP, blocking VM internet. The host-setup script handles this automatically
- **OpenClaw onboard overwrites config**: The `openclaw onboard` command may change `gateway.bind` from `lan` to `loopback` and regenerate the auth token. If this happens, fix with sed on the VM
- **Device pairing per-client**: Each browser/device needs manual approval via `openclaw devices approve`
- **`watch` command fails**: If your terminal type isn't recognized (e.g. ghostty), use a `while` loop instead of `watch`
