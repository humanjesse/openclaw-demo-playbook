from pydantic_settings import BaseSettings


class Settings(BaseSettings):
    # Cloudflare
    cf_api_token: str = ""
    cf_account_id: str = ""
    cf_zone_id: str = ""
    cf_domain: str = "demo.example.com"

    # Ansible
    ansible_playbook_dir: str = "/home/wassie/Work/openclaw-provision/ansible/playbooks"

    # VM defaults
    vm_ram_mb: int = 4096
    vm_vcpus: int = 4

    # Ollama
    ollama_model: str = "qwen3:8b"

    model_config = {"env_file": ".env"}


settings = Settings()
