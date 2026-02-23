from fastapi import FastAPI

from api.routers.provision import router as provision_router

app = FastAPI(
    title="OpenClaw VM Provisioning API",
    description="Automated KVM VM provisioning for OpenClaw tenants with Cloudflare tunnel ingress.",
    version="0.1.0",
)

app.include_router(provision_router, prefix="/api/v1")


@app.get("/health")
async def health():
    return {"status": "ok"}
