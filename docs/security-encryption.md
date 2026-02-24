# Security: VM Data Encryption & Secure Teardown

## Context

Customer question: Can we encrypt the log/chat files inside VMs so they can't be exfiltrated?

Short answer: Encryption at rest has limited value in this architecture because VMs are ephemeral and data is always decrypted while the VM is running. The more impactful controls are secure teardown and (optionally) encrypted snapshots for VMs that need to be preserved.

## Threat Model

Understanding what encryption at rest does and doesn't protect against:

| Threat | Encryption at rest helps? | Better control |
|--------|--------------------------|----------------|
| Someone copies the QCOW2 file from the host | **Yes** | Host access controls, QCOW2 LUKS |
| Someone gets SSH/shell access to the running VM | **No** — data is decrypted while mounted | Access controls, network segmentation |
| Someone compromises the hypervisor host | **Partially** — depends on key storage | Host hardening, separate key management |
| QCOW2 lingers on disk after VM stops | **Yes** | Secure wipe on teardown (preferred) |
| Network interception of chat traffic | **No** — different problem | TLS (already handled by Cloudflare tunnels) |
| Forensic recovery of deleted QCOW2 blocks | **Yes** | `virsh vol-wipe` before `vol-delete` |

## Current VM Lifecycle

Today, VMs are ephemeral but not automatically cleaned up:

```
Provision ──> Running (data decrypted, accessible) ──> Explicit DELETE call ──> Destroyed
                                                           │
                                                    What if this doesn't happen?
                                                    QCOW2 sits on disk indefinitely.
```

**Key gap:** There is no TTL or auto-destroy. If a VM stops (crash, shutdown, host reboot) without an explicit `DELETE /api/v1/provision/{tenant_name}` call, the QCOW2 overlay with all chat logs remains in `/var/lib/libvirt/images/` until someone manually cleans it up.

## Where Logs Live Inside the VM

| Path | Contents |
|------|----------|
| `~/.openclaw/agents/<agentId>/sessions/*.jsonl` | Full chat transcripts (messages, tool calls, responses) |
| `~/clawd/memory/YYYY-MM-DD.md` | Markdown memory/summary files |
| `/tmp/openclaw/openclaw-YYYY-MM-DD.log` | Gateway request/response logs |
| `/var/log/openclaw-setup.log` | One-time provisioning log (less sensitive) |

All of these live on the QCOW2 overlay disk.

## Host-Side Logging: Ollama

Ollama runs on the host, not inside the VM, so it's important to understand what it logs — wiping a VM doesn't help if the host kept a copy of the conversation.

**Good news:** By default, Ollama does **not** log prompts or responses. Its systemd journal logs (`journalctl -u ollama`) only capture operational metadata: HTTP method, status code, request path (`/api/chat`), response time, and client IP. The actual conversation content is not recorded.

**Warning:** If `OLLAMA_DEBUG=1` is set in the Ollama service environment, full prompts **are** written to the journal. Our `host-setup-ubuntu.sh` does not set this flag. **Do not enable debug mode in production** — it will write every user prompt to the host's systemd journal.

### What the host journal does contain (even without debug mode)

| Data | Example | Sensitive? |
|------|---------|------------|
| Client IP | `192.168.122.45` | Low — maps to a VM, not a user directly |
| Request path | `POST /api/chat` | No |
| Timing | `200 OK 1.2s` | No |
| Model used | `qwen3:8b` | No |

If even this metadata is a concern, the host journal can be configured to not persist Ollama logs:

```bash
# Option A: Make all journal logs volatile (RAM-only, lost on reboot)
# In /etc/systemd/journald.conf:
#   Storage=volatile

# Option B: Drop Ollama logs specifically (keep other service logs)
# In /etc/systemd/journald.conf.d/drop-ollama.conf:
#   [Match]
#   _SYSTEMD_UNIT=ollama.service
#   [Journal]
#   MaxRetentionSec=1h
```

### Checklist for production

- [ ] Confirm `OLLAMA_DEBUG` is **not** set in `/etc/systemd/system/ollama.service.d/override.conf`
- [ ] Decide on host journal retention policy for `ollama.service` logs
- [ ] If the host has multiple tenants' VMs, note that journal metadata could correlate VM IPs to request timing (side-channel, low risk)

## Recommended Approach

### Priority 1: Secure Wipe on Teardown (Playbook: `secure-wipe-vm.yml`)

For the default case where VMs are ephemeral and data doesn't need to survive:

- Use `virsh vol-wipe` (writes zeros over the QCOW2 file) before `virsh vol-delete`
- This prevents forensic recovery of chat data from the host filesystem
- Drop-in replacement for the current `destroy-vm.yml` flow
- No key management overhead, no performance impact during VM operation

**Use when:** Standard session teardown. Customer doesn't need to preserve the VM data.

### Priority 2: Encrypted Snapshot for Preservation (Playbook: `save-vm-encrypted.yml`)

For cases where a VM image needs to be saved (audit, debugging, customer request):

- Shut down the VM cleanly
- Export the QCOW2 overlay to a standalone image (no backing file dependency)
- Encrypt the exported image with LUKS via `qemu-img convert`
- Store the encrypted image in a designated archive directory
- Optionally destroy the original VM after saving

**Use when:** Customer wants to preserve a session's data but keep it encrypted at rest.

### Priority 3: Future Considerations

These are not implemented but worth evaluating if the customer's threat model demands it:

| Control | What it adds | Complexity |
|---------|-------------|------------|
| **VM auto-destroy TTL** | API-level timer that destroys VMs after N hours | Medium — needs background scheduler |
| **QCOW2 LUKS at creation** | Encrypt VM disk from the start | Medium — but incompatible with backing files (increases disk usage) |
| **fscrypt on log directories** | Protects logs even if someone gets shell access to running VM | Low-medium — cloud-init can set this up |
| **Host disk encryption (LUKS)** | Protects everything on the host at rest | Medium — requires host reboot, key management |

## QCOW2 LUKS and Backing Files

Important constraint: LUKS-encrypted QCOW2 images **do not support external backing files**. Our current setup uses CoW backing files to share the base Ubuntu 24.04 image across VMs (saving ~2GB per VM). Enabling QCOW2 LUKS at creation time would require full-copy disks per VM, increasing storage from ~200MB overlay to ~4-5GB per VM.

This is why the "encrypt on save" approach (Priority 2) is more practical — it only encrypts when archiving, not during normal operation.

## Key Management

For the encrypted snapshot workflow:

- **Demo/simple:** Passphrase-based LUKS encryption. The passphrase is provided at save time and required to open the image later. Store passphrases in the existing secrets management solution (`.env` for demo, Vault for production).
- **Production:** Consider a dedicated key per tenant, managed by HashiCorp Vault or equivalent. The `save-vm-encrypted.yml` playbook accepts the passphrase as an extra var, so the key source is pluggable.

## Playbook Reference

| Playbook | Purpose | When to use |
|----------|---------|-------------|
| `destroy-vm.yml` | Current teardown (quick delete, no wipe) | Fast cleanup, low-sensitivity data |
| `secure-wipe-vm.yml` | Secure teardown (wipe + delete) | Default for production teardowns |
| `save-vm-encrypted.yml` | Snapshot + LUKS encrypt + optional destroy | Preserving session data securely |
