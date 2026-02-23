from dataclasses import dataclass

import httpx


@dataclass
class TunnelInfo:
    tunnel_id: str
    tunnel_name: str
    tunnel_token: str
    public_hostname: str


class CloudflareService:
    BASE_URL = "https://api.cloudflare.com/client/v4"

    def __init__(
        self, api_token: str, account_id: str, zone_id: str, domain: str
    ):
        self.account_id = account_id
        self.zone_id = zone_id
        self.domain = domain
        self.headers = {
            "Authorization": f"Bearer {api_token}",
            "Content-Type": "application/json",
        }

    async def _find_dns_record(
        self, client: httpx.AsyncClient, name: str
    ) -> str | None:
        """Find an existing DNS record by name. Returns record ID or None."""
        resp = await client.get(
            f"{self.BASE_URL}/zones/{self.zone_id}/dns_records",
            headers=self.headers,
            params={"name": f"{name}.{self.domain}", "type": "CNAME"},
        )
        resp.raise_for_status()
        records = resp.json().get("result", [])
        if records:
            return records[0]["id"]
        return None

    async def _find_tunnel_by_name(
        self, client: httpx.AsyncClient, name: str
    ) -> str | None:
        """Find an existing tunnel by name. Returns tunnel ID or None."""
        resp = await client.get(
            f"{self.BASE_URL}/accounts/{self.account_id}/cfd_tunnel",
            headers=self.headers,
            params={"name": name, "is_deleted": "false"},
        )
        resp.raise_for_status()
        tunnels = resp.json().get("result", [])
        if tunnels:
            return tunnels[0]["id"]
        return None

    async def create_tunnel(self, tenant_name: str) -> TunnelInfo:
        """Create a Cloudflare tunnel with DNS and ingress config."""
        tunnel_name = f"openclaw-{tenant_name}"
        hostname = f"{tenant_name}.{self.domain}"

        async with httpx.AsyncClient(timeout=30) as client:
            # Clean up any leftover tunnel with the same name
            old_tunnel_id = await self._find_tunnel_by_name(
                client, tunnel_name
            )
            if old_tunnel_id:
                # Force-clean active connections first
                await client.delete(
                    f"{self.BASE_URL}/accounts/{self.account_id}/cfd_tunnel/{old_tunnel_id}/connections",
                    headers=self.headers,
                )
                await client.delete(
                    f"{self.BASE_URL}/accounts/{self.account_id}/cfd_tunnel/{old_tunnel_id}",
                    headers=self.headers,
                )

            # 1. Create the tunnel
            resp = await client.post(
                f"{self.BASE_URL}/accounts/{self.account_id}/cfd_tunnel",
                headers=self.headers,
                json={
                    "name": tunnel_name,
                    "config_src": "cloudflare",
                },
            )
            resp.raise_for_status()
            data = resp.json()["result"]
            tunnel_id = data["id"]
            tunnel_token = data["token"]

            # 2. Configure ingress rules
            resp = await client.put(
                f"{self.BASE_URL}/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}/configurations",
                headers=self.headers,
                json={
                    "config": {
                        "ingress": [
                            {
                                "hostname": hostname,
                                "service": "http://localhost:18789",
                                "originRequest": {},
                            },
                            {"service": "http_status:404"},
                        ]
                    }
                },
            )
            resp.raise_for_status()

            # 3. Create or update DNS CNAME record
            existing_record_id = await self._find_dns_record(
                client, tenant_name
            )
            dns_payload = {
                "type": "CNAME",
                "name": tenant_name,
                "content": f"{tunnel_id}.cfargotunnel.com",
                "proxied": True,
            }

            if existing_record_id:
                resp = await client.put(
                    f"{self.BASE_URL}/zones/{self.zone_id}/dns_records/{existing_record_id}",
                    headers=self.headers,
                    json=dns_payload,
                )
            else:
                resp = await client.post(
                    f"{self.BASE_URL}/zones/{self.zone_id}/dns_records",
                    headers=self.headers,
                    json=dns_payload,
                )
            resp.raise_for_status()

            return TunnelInfo(
                tunnel_id=tunnel_id,
                tunnel_name=tunnel_name,
                tunnel_token=tunnel_token,
                public_hostname=f"https://{hostname}",
            )

    async def delete_tunnel(self, tunnel_id: str, tenant_name: str = "") -> None:
        """Delete a tunnel and its DNS record."""
        async with httpx.AsyncClient(timeout=30) as client:
            # Delete DNS record if tenant_name provided
            if tenant_name:
                record_id = await self._find_dns_record(
                    client, tenant_name
                )
                if record_id:
                    await client.delete(
                        f"{self.BASE_URL}/zones/{self.zone_id}/dns_records/{record_id}",
                        headers=self.headers,
                    )

            # Clean connections then delete tunnel
            await client.delete(
                f"{self.BASE_URL}/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}/connections",
                headers=self.headers,
            )
            await client.delete(
                f"{self.BASE_URL}/accounts/{self.account_id}/cfd_tunnel/{tunnel_id}",
                headers=self.headers,
            )
