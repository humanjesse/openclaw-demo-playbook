# OpenClaw Automated VM Provisioning Stack

Automated provisioning of isolated OpenClaw AI assistant instances inside KVM virtual machines, with Cloudflare tunnel ingress. Built to demo a customer onboarding flow for bare-metal server fleets managed via Ansible.

## Architecture

```
    POST /api/v1/provision {"tenant_name": "acme-corp"}
                    |
                FastAPI (port 8000)
                    |
        +-----------+-----------+
        |                       |
   Cloudflare API          Ansible Playbook
   (create tunnel,         (localhost)
    DNS CNAME)                  |
        |               +------+------+
        |               |             |
        |          cloud-init     virt-install
        |          ISO build      (KVM VM)
        |               |             |
        |               +------+------+
        |                      |
        |              Ubuntu 24.04 VM boots
        |                      |
        |              cloud-init runs:
        |               - Node.js 22
        |               - OpenClaw (npm)
        |               - cloudflared
        |                      |
        +-------> cloudflared connects tunnel
                       to localhost:18789
                               |
                  OpenClaw gateway talks to
                  Ollama @ 192.168.122.1:11434

    Result: https://acme-corp.demo.yourdomain.com -> OpenClaw WebChat
```

## Prerequisites

- Arch Linux host with KVM support (`/dev/kvm` exists)
- Ollama installed and running (bound to `0.0.0.0:11434`)
- Cloudflare account with API token, account ID, zone ID, and a domain
- Python 3.12+

## Quick Start

### 1. Host Setup (one-time)

The host setup script handles everything: KVM/libvirt packages, storage pool, SSH key generation, and cloud image download.

```bash
# Installs KVM/libvirt, creates storage pool, generates SSH key, downloads cloud image
./scripts/host-setup.sh

# IMPORTANT: Log out and back in (or run 'newgrp libvirt') for group changes
```

This creates:
- libvirt storage pool `images-1` at `/var/lib/libvirt/images/`
- Dedicated automation SSH key at `~/.ssh/openclaw_demo` (no passphrase)
- Ubuntu 24.04 cloud image in the storage pool

### 2. Python Environment

```bash
python3 -m venv .venv
source .venv/bin/activate
pip install -r requirements.txt
```

### 3. Configure Cloudflare Credentials

```bash
cp .env.example .env
# Edit .env with your Cloudflare credentials and paths
```

### 4. Start the API

```bash
source .venv/bin/activate
uvicorn api.main:app --host 0.0.0.0 --port 8000 --reload
```

### 5. Provision a Tenant

```bash
# Create
curl -X POST http://localhost:8000/api/v1/provision \
  -H "Content-Type: application/json" \
  -d '{"tenant_name": "acme-corp"}'

# Poll status (use the task_id from the response)
curl http://localhost:8000/api/v1/status/<task_id>

# When status is "ready", open the tunnel_url in your browser

# Tear down (returns 202 — poll /status/<task_id> for completion)
curl -X DELETE http://localhost:8000/api/v1/provision/acme-corp
```

## API Endpoints

| Method | Path | Description |
|--------|------|-------------|
| `GET` | `/health` | Health check |
| `POST` | `/api/v1/provision` | Start provisioning a new tenant |
| `GET` | `/api/v1/status/{task_id}` | Poll provisioning status |
| `DELETE` | `/api/v1/provision/{tenant_name}` | Destroy a tenant (async 202 — poll `/status` for completion) |

Interactive API docs available at `http://localhost:8000/docs` (Swagger UI).

## VM Resources

Default allocation per VM: 4 GB RAM, 4 vCPUs, 20 GB disk.

| Resource | Host Total | Reserved (OS + Ollama) | Available for VMs | Max Concurrent |
|----------|-----------|----------------------|-------------------|----------------|
| RAM | 46 GB | ~10 GB | ~36 GB | 8 VMs |
| vCPUs | 32 threads | ~4 | ~28 | 7 VMs |

Use `qwen3:8b` for the demo to keep Ollama's memory footprint low (~5 GB loaded).

## Project Structure

```
openclaw-provision/
├── README.md                      # This file
├── .env.example                   # Environment variable template
├── requirements.txt               # Python dependencies
├── docs/
│   ├── architecture.md            # Detailed architecture docs
│   ├── security-encryption.md     # Threat model, secure wipe, encrypted snapshots
│   ├── ubuntu-deploy-guide.md     # Step-by-step Ubuntu deployment
│   └── demo-script.md             # Step-by-step client demo guide
├── scripts/
│   ├── host-setup.sh              # Install KVM/libvirt on Arch
│   ├── host-setup-ubuntu.sh       # Install KVM/libvirt on Ubuntu (+ GPU, iptables)
│   ├── download-cloud-image.sh    # Fetch Ubuntu cloud image
│   └── cleanup.sh                 # Destroy all demo VMs
├── cloud-init/
│   ├── user-data.yaml.j2          # VM provisioning template
│   └── meta-data.yaml.j2          # VM metadata template
├── ansible/
│   ├── ansible.cfg
│   ├── inventory/localhost.yml
│   ├── vars/defaults.yml          # VM defaults (RAM, CPU, model)
│   └── playbooks/
│       ├── provision-vm.yml       # Create + configure VM
│       ├── destroy-vm.yml         # Tear down VM (quick)
│       ├── secure-wipe-vm.yml     # Tear down VM (zero-fill disk first)
│       └── save-vm-encrypted.yml  # Snapshot + LUKS encrypt VM
├── api/
│   ├── main.py                    # FastAPI application
│   ├── config.py                  # Settings from .env
│   ├── models.py                  # Request/response schemas
│   ├── routers/provision.py       # Provision endpoints
│   └── services/
│       ├── cloudflare.py          # Cloudflare tunnel management
│       └── ansible_runner.py      # Ansible subprocess runner
└── images/                        # Cloud images (gitignored)
```

## Cleanup

```bash
# Destroy all demo VMs
./scripts/cleanup.sh

# Cloudflare tunnels must be deleted via the API or dashboard
```
