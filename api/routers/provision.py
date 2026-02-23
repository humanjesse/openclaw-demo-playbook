import secrets
import uuid
from datetime import datetime, timezone

from fastapi import APIRouter, BackgroundTasks, HTTPException

from api.config import settings
from api.models import (
    ProvisionRequest,
    ProvisionResponse,
    ProvisionStatus,
    ProvisionStatusResponse,
)
from api.services.ansible_runner import AnsibleRunnerService
from api.services.cloudflare import CloudflareService

router = APIRouter(tags=["provision"])

# In-memory task store (demo only — production would use a database)
tasks: dict[str, dict] = {}

cf_service = CloudflareService(
    api_token=settings.cf_api_token,
    account_id=settings.cf_account_id,
    zone_id=settings.cf_zone_id,
    domain=settings.cf_domain,
)

ansible_service = AnsibleRunnerService(
    playbook_dir=settings.ansible_playbook_dir,
)


async def _provision_task(task_id: str, request: ProvisionRequest):
    """Background task: full provisioning flow."""
    task = tasks[task_id]
    try:
        # Step 1: Create Cloudflare tunnel
        task["status"] = ProvisionStatus.CREATING_TUNNEL
        tunnel = await cf_service.create_tunnel(request.tenant_name)
        task["tunnel_url"] = tunnel.public_hostname
        task["tunnel_id"] = tunnel.tunnel_id

        # Step 2: Generate gateway auth token
        gateway_token = secrets.token_urlsafe(32)

        # Step 3: Provision VM via Ansible
        task["status"] = ProvisionStatus.PROVISIONING_VM
        result = await ansible_service.provision_vm(
            vm_name=request.tenant_name,
            cf_tunnel_token=tunnel.tunnel_token,
            gateway_token=gateway_token,
            ollama_model=request.ollama_model or settings.ollama_model,
            vm_ram_mb=request.vm_ram_mb or settings.vm_ram_mb,
            vm_vcpus=request.vm_vcpus or settings.vm_vcpus,
        )

        task["vm_ip"] = result.get("vm_ip")
        task["status"] = ProvisionStatus.READY
        task["gateway_url"] = f"{tunnel.public_hostname}/?token={gateway_token}"
        task["message"] = "Provisioning complete. OpenClaw is ready."

    except Exception as e:
        task["status"] = ProvisionStatus.FAILED
        task["error"] = str(e)
        # Best-effort cleanup on failure
        try:
            if "tunnel_id" in task:
                await cf_service.delete_tunnel(task["tunnel_id"], request.tenant_name)
            await ansible_service.destroy_vm(request.tenant_name)
        except Exception:
            pass


@router.post("/provision", response_model=ProvisionResponse)
async def provision(
    request: ProvisionRequest, background_tasks: BackgroundTasks
):
    """Kick off a new OpenClaw VM provisioning."""
    # Check for duplicate active tenant
    for t in tasks.values():
        if (
            t["tenant_name"] == request.tenant_name
            and t["status"]
            not in (ProvisionStatus.FAILED, ProvisionStatus.DESTROYED)
        ):
            raise HTTPException(
                status_code=409,
                detail=f"Tenant '{request.tenant_name}' already exists or is being provisioned.",
            )

    task_id = str(uuid.uuid4())
    now = datetime.now(timezone.utc)
    tasks[task_id] = {
        "task_id": task_id,
        "tenant_name": request.tenant_name,
        "status": ProvisionStatus.PENDING,
        "tunnel_url": None,
        "vm_ip": None,
        "gateway_url": None,
        "created_at": now,
        "message": "Provisioning started",
    }

    background_tasks.add_task(_provision_task, task_id, request)

    return ProvisionResponse(
        task_id=task_id,
        tenant_name=request.tenant_name,
        status=ProvisionStatus.PENDING,
        created_at=now,
        message="Provisioning started. Poll /status/{task_id} for updates.",
    )


@router.get("/status/{task_id}", response_model=ProvisionStatusResponse)
async def get_status(task_id: str):
    """Poll provisioning status."""
    if task_id not in tasks:
        raise HTTPException(status_code=404, detail="Task not found")
    t = tasks[task_id]
    return ProvisionStatusResponse(
        task_id=t["task_id"],
        tenant_name=t["tenant_name"],
        status=t["status"],
        tunnel_url=t.get("tunnel_url"),
        vm_ip=t.get("vm_ip"),
        gateway_url=t.get("gateway_url"),
        error=t.get("error"),
    )


@router.delete("/provision/{tenant_name}")
async def deprovision(tenant_name: str):
    """Tear down a provisioned tenant (VM + tunnel)."""
    task = None
    for t in tasks.values():
        if t["tenant_name"] == tenant_name:
            task = t
            break
    if not task:
        raise HTTPException(status_code=404, detail="Tenant not found")

    try:
        if "tunnel_id" in task:
            await cf_service.delete_tunnel(task["tunnel_id"], tenant_name)
        await ansible_service.destroy_vm(tenant_name)
        task["status"] = ProvisionStatus.DESTROYED
        return {"message": f"Tenant '{tenant_name}' destroyed."}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
