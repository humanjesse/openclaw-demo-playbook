# Ubuntu Demo Machine Deployment Guide

Step-by-step setup for deploying the OpenClaw provisioning stack on Ubuntu Server with NVIDIA GPUs. Tested on Ubuntu 24.04 with 8x V100-SXM2-32GB.

## Prerequisites

- Ubuntu Server with sudo access
- SSH access (via OpenVPN or direct)
- NVIDIA GPUs with drivers already installed (`nvidia-smi` works)
- Cloudflare account with API token, account ID, zone ID, and a domain
- Two SSH sessions to the demo machine (one for the API, one for commands)

Verify basics:
```bash
which curl git python3 && python3 --version
ls -la /dev/kvm  # must exist — if not, enable virtualization in BIOS
nvidia-smi       # GPUs visible
```

Install if missing:
```bash
sudo apt update && sudo apt install -y curl git python3 python3-venv python3-pip
```

## Step 1: Install Ollama + Pull Model

```bash
curl -fsSL https://ollama.com/install.sh | sh
ollama pull devstral-2:123b
```

> **Model selection notes:**
> - `devstral-2:123b` — dense 123B model, ~9-10 tok/s on 8x V100. Good quality, moderate speed.
> - For faster inference, consider a Mixture of Experts (MoE) model — only a fraction of parameters are active per token so generation is faster.
> - For MoE models from HuggingFace (not on Ollama registry), see [Importing Custom Models](#importing-custom-models-from-huggingface) below.
> - Make sure the model + KV cache fits in total VRAM. If `ollama ps` shows `CPU/GPU` split, the model is spilling to CPU and will be slow.

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

Fill in (update `OLLAMA_MODEL` to match whatever model you pulled):
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

This installs:
- KVM/QEMU/libvirt packages
- Creates `images-1` storage pool
- Generates SSH key (`~/.ssh/openclaw_demo`)
- Downloads Ubuntu 24.04 cloud image
- Configures iptables: VM-to-VM isolation (FORWARD DROP), VM internet access (Docker fix), Ollama port restriction (INPUT: localhost + virbr0 only)
- Persists iptables rules via `iptables-persistent`
- Configures Ollama: binds `0.0.0.0:11434`, enables flash attention, sets 1hr keep-alive
- Enables GPU persistence mode (`nvidia-smi -pm 1`)
- Pulls the model specified in `.env`
- Sets up Python venv and installs dependencies
- Creates and enables the provisioning API systemd service

After completion, **log out and SSH back in** for libvirt/kvm group membership to take effect.

## Step 5: Verify Setup

```bash
sudo virsh net-list --all          # default network active
sudo virsh pool-list --all         # images-1 pool active
sudo virsh vol-list images-1       # cloud image present
ls -la /dev/kvm                    # KVM accessible
curl http://192.168.122.1:11434/api/tags  # Ollama reachable from bridge IP
nvidia-smi                         # GPUs visible
which mkisofs                      # should return /usr/bin/mkisofs (from genisoimage)
```

If `mkisofs` is missing:
```bash
sudo ln -s /usr/bin/genisoimage /usr/bin/mkisofs
```

## Step 6: Install Python Dependencies

```bash
cd ~/openclaw-provision
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

If `python3 -m venv` fails:
```bash
sudo apt install -y python3.12-venv
```

## Step 7: Warm Up the Model

Before starting the API, warm up the model so the first user request isn't slow (~35s cold load):
```bash
curl -s http://localhost:11434/api/generate -d '{"model": "devstral-2:123b", "keep_alive": "1h", "prompt": "hi"}'
```

Verify it's 100% on GPU:
```bash
ollama ps
```

Should show `100% GPU`. If it shows `CPU/GPU` split, the model + KV cache is too large — reduce context or use a smaller model.

## Step 8: Start the API

In **Terminal 1**:
```bash
cd ~/openclaw-provision
source .venv/bin/activate
uvicorn api.main:app --host 0.0.0.0 --port 8000
```

## Step 9: Provision a VM

In **Terminal 2**:
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

> **Note:** Use a `while` loop instead of `watch` — `watch` fails if the terminal type (e.g. ghostty) isn't recognized on the server.

## Step 10: Fix Gateway Config

The `openclaw onboard` command inside the VM overwrites some gateway settings. After provisioning completes, fix them:

```bash
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> \
  'sed -i s/loopback/lan/ /home/openclaw/.openclaw/openclaw.json'
```

Get the correct token from the poll output (`gateway_url` contains `?token=<TOKEN>`) and replace the onboard-generated token:

```bash
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> \
  'sed -i s/<onboard_token>/<correct_token>/ /home/openclaw/.openclaw/openclaw.json'
```

To find the onboard token:
```bash
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> \
  cat /home/openclaw/.openclaw/openclaw.json | grep token
```

Fix the context window and max tokens:
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
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> \
  sudo systemctl restart openclaw-gateway
```

## Step 11: Approve Device Pairing

Open the `gateway_url` from the poll output in your browser (the full URL with `?token=...`).

The dashboard will show **"pairing required"**. Each browser/device needs manual approval:

```bash
# List pending pairing requests
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> \
  openclaw devices list --json

# Approve the request (copy the requestId from the output above)
ssh -i ~/.ssh/openclaw_demo -o StrictHostKeyChecking=no openclaw@<vm_ip> \
  openclaw devices approve <requestId>
```

After approval, the dashboard should show **"Health OK"** and you can start chatting.

## Cleanup

Delete a provisioned VM and its tunnel (async — returns 202):
```bash
# Start destruction (returns task_id)
curl -s -X DELETE http://localhost:8000/api/v1/provision/<tenant_name> | jq

# Poll for completion
curl -s http://localhost:8000/api/v1/status/<task_id> | jq
```

---

## Importing Custom Models from HuggingFace

For models not on Ollama's registry (e.g. MoE models from Unsloth/HuggingFace):

### 1. Install huggingface-hub
```bash
sudo apt install -y python3-pip
pip3 install --break-system-packages huggingface-hub
```

### 2. Download the GGUF files
```bash
python3 -c "from huggingface_hub import snapshot_download; snapshot_download('unsloth/MiniMax-M2.5-GGUF', allow_patterns='Q5_K_S/*', local_dir='/tmp/minimax')"
```

> **Warning:** Large model downloads can saturate your network link. Coordinate with your network team.

### 3. Merge sharded GGUFs (if multiple files)

Ollama can't load sharded GGUFs directly. Merge them first:

```bash
# Build llama-gguf-split
sudo apt install -y cmake build-essential
git clone https://github.com/ggml-org/llama.cpp.git /tmp/llama-cpp
cd /tmp/llama-cpp && cmake -B build && cmake --build build --target llama-gguf-split -j$(nproc)

# Merge (make sure you have enough disk space for the merged file)
/tmp/llama-cpp/build/bin/llama-gguf-split --merge \
  /tmp/minimax/Q5_K_S/MiniMax-M2.5-Q5_K_S-00001-of-00005.gguf \
  /tmp/minimax/MiniMax-M2.5-Q5_K_S.gguf
```

### 4. Create Ollama model

> **Important:** Some models need a chat template in the Modelfile. Check the model's HuggingFace page for `chat_template.jinja` and convert it to Ollama's Go template format.

```bash
cat > /tmp/Modelfile << 'EOF'
FROM /tmp/minimax/MiniMax-M2.5-Q5_K_S.gguf
EOF
ollama create minimax:q5ks -f /tmp/Modelfile
```

### 5. Test
```bash
ollama run minimax:q5ks "hello" --verbose
```

### 6. Update .env
```
OLLAMA_MODEL=minimax:q5ks
```

---

## GPU Optimization Settings

These are configured automatically by `host-setup-ubuntu.sh`, but for reference:

| Setting | What it does |
|---------|-------------|
| `OLLAMA_HOST=0.0.0.0:11434` | Binds to all interfaces so VMs can reach Ollama via bridge IP |
| `OLLAMA_KEEP_ALIVE=1h` | Keeps model in VRAM for 1 hour (avoids ~35s cold load) |
| `OLLAMA_FLASH_ATTENTION=1` | 10x faster prompt processing, no quality loss |
| `nvidia-smi -pm 1` | GPU persistence mode — keeps driver loaded, eliminates cold-start |

To check model is fully on GPU:
```bash
ollama ps  # should show 100% GPU, not CPU/GPU split
```

To check GPU utilization during inference:
```bash
nvidia-smi  # GPUs cycle through 100% one at a time — this is normal for multi-GPU inference
```

---

## Known Issues

- **Group membership not inherited by subprocesses**: Playbooks use `virsh -c qemu:///system` explicitly to avoid relying on libvirt group membership in subprocess chains. You must still log out/in after setup for `virsh` to work from your shell.
- **Docker iptables FORWARD DROP**: If Docker is installed, it sets iptables FORWARD policy to DROP, blocking VM internet. The host-setup script detects and fixes this automatically, and persists rules with `iptables-persistent`.
- **OpenClaw onboard overwrites gateway config**: The `openclaw onboard` command changes `gateway.bind` from `lan` to `loopback` and regenerates the auth token. Must be fixed manually after each provision (see Step 10).
- **Device pairing per-client**: Each browser/device needs manual approval via `openclaw devices approve <requestId>`.
- **`watch` command fails on ghostty**: Terminal type `xterm-ghostty` isn't recognized on Ubuntu. Use `while true; do ...; sleep N; done` loops instead.
- **Passwordless sudo not available**: The setup script uses `sudo` for apt/systemd. Ansible playbooks avoid sudo by using `virsh -c qemu:///system`.
- **Ollama binds 0.0.0.0**: Required for VM access (Ollama only supports a single bind address). Protected by iptables INPUT rules (step 10). If rules are flushed (e.g. Docker restart), run `sudo netfilter-persistent reload` to restore.
- **Sharded GGUFs**: Ollama cannot import multi-file GGUFs directly. Merge with `llama-gguf-split --merge` first.
