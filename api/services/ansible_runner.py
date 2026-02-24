import asyncio
import json
import os
import re
from pathlib import Path


def _clean_env() -> dict[str, str]:
    """Return a clean environment without venv variables.

    virt-install uses #!/usr/bin/env python3 which picks up the venv's
    Python, but it needs system packages (gi/gobject-introspection).
    Stripping VIRTUAL_ENV and fixing PATH ensures system Python is used
    by subprocesses while ansible-playbook itself still runs from the venv.
    """
    env = os.environ.copy()
    venv_path = env.pop("VIRTUAL_ENV", None)
    if venv_path:
        # Remove venv bin from PATH so /usr/bin/env python3 finds system Python
        paths = env.get("PATH", "").split(":")
        paths = [p for p in paths if not p.startswith(venv_path)]
        env["PATH"] = ":".join(paths)
    env.pop("PYTHONHOME", None)
    # Keep ansible-playbook accessible — find its absolute path first
    return env


class AnsibleRunnerService:
    def __init__(self, playbook_dir: str):
        self.playbook_dir = Path(playbook_dir).resolve()
        # Resolve ansible-playbook path — check venv bin first (for systemd),
        # then fall back to PATH lookup
        import shutil
        import sys

        venv_bin = Path(sys.executable).parent / "ansible-playbook"
        if venv_bin.exists():
            self._ansible_playbook = str(venv_bin)
        else:
            self._ansible_playbook = shutil.which("ansible-playbook") or "ansible-playbook"

    async def provision_vm(
        self,
        vm_name: str,
        cf_tunnel_token: str,
        gateway_token: str,
        ollama_model: str = "qwen3:8b",
        vm_ram_mb: int = 4096,
        vm_vcpus: int = 4,
    ) -> dict:
        """Run the provision playbook. Returns dict with vm_ip on success."""
        extra_vars = json.dumps(
            {
                "vm_name": vm_name,
                "cf_tunnel_token": cf_tunnel_token,
                "gateway_token": gateway_token,
                "ollama_model": ollama_model,
                "vm_ram_mb": vm_ram_mb,
                "vm_vcpus": vm_vcpus,
            }
        )

        cmd = [
            self._ansible_playbook,
            str(self.playbook_dir / "provision-vm.yml"),
            "--extra-vars",
            extra_vars,
        ]

        env = _clean_env()
        # Ensure ansible can still find its modules via the venv's site-packages
        env["PYTHONPATH"] = ":".join(
            p for p in __import__("sys").path if "site-packages" in p
        )

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(self.playbook_dir.parent),
            env=env,
        )

        stdout, stderr = await process.communicate()

        if process.returncode != 0:
            raise RuntimeError(
                f"Ansible playbook failed (rc={process.returncode}): "
                f"{stderr.decode()}\n{stdout.decode()}"
            )

        # Parse VM IP from Ansible output
        output = stdout.decode()
        for line in output.split("\n"):
            if "192.168.122." in line:
                match = re.search(r"192\.168\.122\.\d+", line)
                if match:
                    return {"vm_ip": match.group(0), "output": output}

        return {"vm_ip": None, "output": output}

    async def destroy_vm(self, vm_name: str, secure: bool = True) -> None:
        """Run the destroy playbook.

        Args:
            vm_name: Name of the VM to destroy.
            secure: If True (default), zero-fills disk before deletion via
                    secure-wipe-vm.yml. If False, fast cleanup via destroy-vm.yml.
        """
        playbook = "secure-wipe-vm.yml" if secure else "destroy-vm.yml"
        cmd = [
            self._ansible_playbook,
            str(self.playbook_dir / playbook),
            "--extra-vars",
            json.dumps({"vm_name": vm_name}),
        ]

        env = _clean_env()
        env["PYTHONPATH"] = ":".join(
            p for p in __import__("sys").path if "site-packages" in p
        )

        process = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
            cwd=str(self.playbook_dir.parent),
            env=env,
        )

        stdout, stderr = await process.communicate()

        if process.returncode != 0:
            raise RuntimeError(
                f"VM destroy failed (rc={process.returncode}): "
                f"{stderr.decode()}\n{stdout.decode()}"
            )
