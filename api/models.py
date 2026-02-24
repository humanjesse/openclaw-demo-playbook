from datetime import datetime
from enum import Enum

from pydantic import BaseModel, Field


class ProvisionStatus(str, Enum):
    PENDING = "pending"
    CREATING_TUNNEL = "creating_tunnel"
    PROVISIONING_VM = "provisioning_vm"
    READY = "ready"
    DESTROYING = "destroying"
    DESTROYED = "destroyed"
    FAILED = "failed"


class ProvisionRequest(BaseModel):
    tenant_name: str = Field(
        ...,
        description="Tenant identifier — used as VM name and subdomain",
        pattern=r"^[a-z0-9][a-z0-9-]{1,30}[a-z0-9]$",
    )
    ollama_model: str | None = Field(
        None, description="Override the default Ollama model"
    )
    vm_ram_mb: int | None = Field(None, ge=2048, le=8192)
    vm_vcpus: int | None = Field(None, ge=2, le=8)


class ProvisionResponse(BaseModel):
    task_id: str
    tenant_name: str
    status: ProvisionStatus
    tunnel_url: str | None = None
    vm_ip: str | None = None
    gateway_url: str | None = None
    created_at: datetime
    message: str | None = None


class ProvisionStatusResponse(BaseModel):
    task_id: str
    tenant_name: str
    status: ProvisionStatus
    tunnel_url: str | None = None
    vm_ip: str | None = None
    gateway_url: str | None = None
    error: str | None = None
