# Architecture

## Overview

This stack automates the provisioning of isolated OpenClaw AI assistant instances. Each tenant gets their own KVM virtual machine running Ubuntu 24.04, with OpenClaw pre-configured to use a shared Ollama instance on the host. External access is provided via Cloudflare tunnels.

## Component Flow

```
                          +-----------------+
                          |   Client/User   |
                          |  (curl / UI)    |
                          +--------+--------+
                                   |
                          POST /api/v1/provision
                                   |
                          +--------v--------+
                          |    FastAPI       |
                          |   (port 8000)   |
                          +---+--------+----+
                              |        |
              +---------------+        +---------------+
              |                                        |
    +---------v----------+                  +----------v----------+
    |  Cloudflare API    |                  |   Ansible Playbook  |
    |                    |                  |   (localhost)        |
    | 1. Create tunnel   |                  |                     |
    | 2. Set ingress     |                  | 1. Render cloud-init|
    | 3. Create DNS      |                  | 2. Build ISO        |
    +--------------------+                  | 3. Create qcow2 disk|
                                            | 4. virt-install     |
                                            | 5. Wait for IP      |
                                            | 6. Wait for SSH     |
                                            | 7. Wait for ready   |
                                            +----------+----------+
                                                       |
                                            +----------v----------+
                                            |    KVM/libvirt VM   |
                                            |   (Ubuntu 24.04)    |
                                            |                     |
                                            |  cloud-init runs:   |
                                            |  - Node.js 22       |
                                            |  - OpenClaw         |
                                            |  - cloudflared      |
                                            |                     |
                                            |  +---------+        |
                                            |  | OpenClaw|:18789  |
                                            |  +---------+        |
                                            |       |             |
                                            +-------|-------------+
                                                    |
                                      virbr0 (192.168.122.0/24)
                                                    |
                                            +-------v-------+
                                            |    Ollama     |
                                            | (host:11434)  |
                                            +---------------+
```

## Networking

### Why NAT (not bridged)

The host connects via WiFi (wlan0). WiFi interfaces cannot be bridged to a virtual bridge because 802.11 does not support MAC address spoofing from clients. libvirt's default NAT network (virbr0) is used instead.

### Network Layout

| Interface | IP | Purpose |
|-----------|-----|---------|
| wlan0 | DHCP (host WiFi) | Internet access |
| virbr0 | 192.168.122.1/24 | libvirt NAT bridge |
| VM eth0 | 192.168.122.x/24 (DHCP) | VM network |

### VM -> Host Communication

VMs reach the host at `192.168.122.1`. Ollama listens on `0.0.0.0:11434`, so it's reachable from VMs at `http://192.168.122.1:11434`.

### VM -> Internet

libvirt sets up iptables masquerading rules automatically. VMs can reach the internet through the host's WiFi connection for package downloads during cloud-init.

## Cloud-Init Flow

The cloud-init user-data is a Jinja2 template rendered by Ansible per-VM. It:

1. Creates an `openclaw` user with SSH access
2. Installs base packages (curl, git, build-essential, qemu-guest-agent)
3. Writes the OpenClaw config (`~/.openclaw/openclaw.json`) pre-configured for the host's Ollama
4. Runs a setup script that:
   - Installs Node.js 22 via NodeSource
   - Installs OpenClaw via npm
   - Runs non-interactive onboarding
   - Installs cloudflared
   - Starts the Cloudflare tunnel service
   - Writes a readiness sentinel file

## Cloudflare Tunnel Architecture

Each VM gets its own named tunnel:

```
Internet -> Cloudflare Edge -> Tunnel -> cloudflared (in VM) -> localhost:18789 (OpenClaw)
```

The FastAPI backend creates tunnels programmatically via the Cloudflare API:
1. Creates a tunnel object (gets a token)
2. Configures ingress rules (route hostname -> localhost:18789)
3. Creates a DNS CNAME record (tenant.domain.com -> tunnel-id.cfargotunnel.com)
4. Passes the token to the VM via cloud-init

Inside the VM, `cloudflared service install <token>` registers and starts the tunnel connector as a systemd service.

## Readiness Detection

Three-stage detection ensures the VM is fully operational:

1. **IP Assignment** (0-60s): Poll `virsh net-dhcp-leases` until the VM gets a DHCP lease
2. **SSH Available** (30-90s): `wait_for` on port 22
3. **OpenClaw Ready** (60-240s): SSH in and check for `/var/run/openclaw-ready` sentinel file, which is written as the last step of the setup script

## Security Notes (Demo Context)

- Gateway auth tokens are random 32-byte URL-safe strings, generated per-VM
- SSH keys are injected via cloud-init for host -> VM access
- Cloudflare tunnel tokens are passed through the cloud-init ISO (not network-exposed)
- The in-memory task store is demo-only; production would use a persistent database
- No TLS between VM and host Ollama (internal NAT network, acceptable for demo)

## Secrets Management

**Demo:** Credentials live in a `.env` file (gitignored) on the local machine. This is fine for development and demos.

**Production options (ranked by fit for this Ansible-heavy stack):**

| Approach | How It Works | Best For |
|----------|-------------|----------|
| **HashiCorp Vault** | Central secrets server. Ansible has native `hashi_vault` lookup plugin; FastAPI pulls secrets at startup via `hvac` client. Supports dynamic secrets, rotation, and audit logging. | Large infra teams, compliance-heavy environments |
| **Ansible Vault** (built-in) | Encrypts vars files at rest with `ansible-vault encrypt`. Decrypted at playbook runtime with a password/key file. Zero additional infrastructure. | Simplest path if Ansible is already the primary tool |
| **CI/CD Secrets** (GitHub Actions / GitLab CI) | Secrets injected as environment variables during pipeline runs. Never touch disk. | When provisioning is triggered from CI/CD pipelines |
| **Cloud Secret Managers** (AWS Secrets Manager / GCP Secret Manager) | API-based secret retrieval with IAM-scoped access. | Cloud-hosted API deployments |

## Storage Management

VM disks are managed through libvirt's **storage pool API** (`virsh vol-create-as`) rather than calling `qemu-img` directly. This means:

- No sudo/root access needed for disk operations — libvirtd handles permissions
- Volumes are tracked and visible via `virsh vol-list`
- Cleanup is handled via `virsh vol-delete` or `virsh undefine --remove-all-storage`
- The base cloud image lives in the same pool as VM disks

The storage pool `images-1` maps to `/var/lib/libvirt/images/`, the standard libvirt storage location. This is the production-standard approach — libvirt manages the storage lifecycle, not the automation user.

**What to store as secrets:**
- `CF_API_TOKEN` — Cloudflare API token (tunnel + DNS permissions)
- `CF_ACCOUNT_ID`, `CF_ZONE_ID` — not strictly secret but best kept out of source
- Per-VM `gateway_token` values — generated at runtime, ephemeral
- SSH private keys — for host-to-VM access
- Any future database credentials for the task store

**Recommendation for the client:** HashiCorp Vault if they don't already have a secrets solution. Ansible Vault as a quick win if they want zero new infrastructure.

## Mapping to Production (Client's 200 Servers)

| Demo (local) | Production |
|-------------|-----------|
| localhost inventory | 200 bare-metal server inventory |
| libvirt NAT network | Dedicated GPU network (likely 10GbE/25GbE) |
| Single Ollama on host | GPU servers with Ollama per-node or shared inference cluster |
| cloud-init via ISO | cloud-init via network datasource or PXE boot |
| In-memory task store | PostgreSQL / Redis |
| Single API process | Distributed API with task queue (Celery/RQ) |
