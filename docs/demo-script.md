# Demo Script: Client Meeting Walkthrough

This is a step-by-step guide for demonstrating the OpenClaw automated provisioning stack to the client.

## Pre-Demo Checklist

- [ ] Host setup complete (`virsh net-list` shows `default` active)
- [ ] Ubuntu cloud image downloaded (`images/ubuntu-24.04-cloudimg-amd64.img` exists)
- [ ] Ollama running with `qwen3:8b` loaded (`ollama list`)
- [ ] `.env` configured with Cloudflare credentials
- [ ] API running (`uvicorn api.main:app --host 0.0.0.0 --port 8000`)
- [ ] No leftover VMs from previous demos (`virsh list --all` is empty)
- [ ] Browser ready

## Demo Flow

### Step 1: Show the API (1 min)

Open `http://localhost:8000/docs` in a browser.

> "This is the provisioning API. A single POST request creates a fully isolated OpenClaw instance with its own VM, configured to use your GPU servers for inference, and accessible via a secure Cloudflare tunnel."

Point out the three endpoints:
- `POST /provision` - create a tenant
- `GET /status/{task_id}` - check progress
- `DELETE /provision/{tenant_name}` - tear down

### Step 2: Provision a Tenant Live (1 min to kick off)

In a terminal:

```bash
curl -s -X POST http://localhost:8000/api/v1/provision \
  -H "Content-Type: application/json" \
  -d '{"tenant_name": "acme-corp"}' | jq .
```

> "I just kicked off provisioning for 'acme-corp'. The system is now creating a Cloudflare tunnel, spinning up a KVM VM, and configuring OpenClaw inside it."

Save the `task_id` from the response.

### Step 3: Explain While Waiting (2-3 min)

While the VM provisions, explain the architecture:

> "Under the hood, this is doing exactly what would happen on your 200 servers:
>
> 1. An Ansible playbook creates a cloud-init configuration specific to this tenant
> 2. A KVM VM boots from a clean Ubuntu 24.04 image
> 3. Cloud-init installs and configures OpenClaw with a pre-set connection to the Ollama inference server
> 4. A Cloudflare tunnel provides secure external access without opening any ports
>
> On your bare-metal servers, the only difference is the Ansible inventory targets real hardware instead of localhost."

Show the VM appearing:

```bash
virsh list --all
```

### Step 4: Poll Status (30 sec)

```bash
# Poll until ready
curl -s http://localhost:8000/api/v1/status/<task_id> | jq .
```

Show the status progression: `pending` -> `creating_tunnel` -> `provisioning_vm` -> `ready`.

### Step 5: Open the Tunnel URL (1 min)

When status is `ready`, copy the `gateway_url` from the response and open it in the browser.

> "This is a fully functional OpenClaw instance running inside an isolated VM. It's accessible from anywhere via Cloudflare — no VPN, no port forwarding."

### Step 6: Send a Chat Message (1 min)

Type a message in the OpenClaw web chat interface. Wait for the response.

> "That response just came from the Ollama server running on the host machine. In your setup, this would be your V100 GPU cluster. The VM doesn't need its own GPU — it connects to the inference server over the internal network."

### Step 7: Multi-Tenancy (Optional, 2 min)

Provision a second tenant:

```bash
curl -s -X POST http://localhost:8000/api/v1/provision \
  -H "Content-Type: application/json" \
  -d '{"tenant_name": "globex-inc"}' | jq .
```

> "Each tenant gets complete isolation — separate VM, separate config, separate tunnel. They share the inference infrastructure but can't see each other."

### Step 8: Tear Down (1 min)

```bash
curl -s -X DELETE http://localhost:8000/api/v1/provision/acme-corp | jq .
# Returns 202 with task_id — destruction runs in the background
```

> "Deprovisioning is just as automated and runs in the background. The cloud-init ISO is securely ejected and deleted, the VM disk is wiped, and the Cloudflare tunnel is removed."

### Step 9: Map to Production (2 min)

> "Here's how this maps to your environment:
>
> - **This demo runs on a single mini PC.** Your production runs on 200 bare-metal servers.
> - **Same Ansible playbooks** — we change the inventory from `localhost` to your server fleet.
> - **Same cloud-init templates** — configured for your network topology and GPU setup.
> - **Same API** — but backed by a proper database and task queue for production scale.
> - **GPU passthrough** — on your V100 servers, we'd add VFIO GPU passthrough to give each VM direct GPU access, or point OpenClaw at a shared inference cluster.
>
> The automation you just saw is the same automation that will onboard your customers."

## Troubleshooting During Demo

| Issue | Quick Fix |
|-------|-----------|
| Provision hangs at `provisioning_vm` | Check `virsh list --all` and `virsh console <vm-name>` |
| Tunnel URL doesn't load | DNS propagation delay — wait 60 seconds and retry |
| OpenClaw shows connection error | Verify Ollama is running: `curl http://192.168.122.1:11434/api/tags` |
| VM won't start | Check disk space: `df -h /var/lib/libvirt/images` |
| Slow provisioning | Pre-bake the cloud image (see architecture.md optimization section) |

## Cleanup After Demo

```bash
./scripts/cleanup.sh
# Also delete tunnels via Cloudflare dashboard if needed
```
