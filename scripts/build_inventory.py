#!/usr/bin/env python3
#!/usr/bin/env python3
import json
import subprocess
import time
from pathlib import Path
import sys

OUTPUT_PATH = Path("/artifacts/output.json")  # wherever you write terraform output
INVENTORY_PATH = Path("/work/ansible/inventory/hosts.ini")

ANSIBLE_USER = "lennard"

def wait_for_output(path: Path, timeout: int = 600):
    print(f"⏳ Waiting for Terraform output at {path} ...", flush=True)

    start = time.time()
    while time.time() - start < timeout:
        if path.exists() and path.stat().st_size > 0:
            try:
                data = json.loads(path.read_text())
                if "all_nodes_ips" in data:
                    print("✅ Terraform output detected.", flush=True)
                    return data
            except json.JSONDecodeError:
                pass
        time.sleep(2)

    raise TimeoutError("Terraform output.json not ready in time.")

def as_list(terraform_output_obj):
    if isinstance(terraform_output_obj, dict) and "value" in terraform_output_obj:
        return terraform_output_obj["value"] # if value is at top level
    return terraform_output_obj


def build_host_ip_map(data: dict) -> dict:
    hostnames = as_list(data.get("all_nodes_hostnames", {})) # https://docs.python.org/3/library/stdtypes.html#dict.get
    ips = as_list(data.get("all_nodes_ips", {}))

    if not isinstance(hostnames, list) or not isinstance(ips, list):
        raise ValueError("Expected lists for all_nodes_hostnames and all_nodes_ips")

    if len(hostnames) != len(ips):
        raise ValueError(f"Hostname/IP mismatch: {len(hostnames)} != {len(ips)}")

    return {str(h).strip(): str(ip).strip() for h, ip in zip(hostnames, ips)} # https://realpython.com/python-zip-function/
def prepare_key():
    Path("/root/.ssh").mkdir(parents=True, exist_ok=True)
    subprocess.run(["cp", "/keys/id_ed25519", "/root/.ssh/id_ed25519"], check=True)
    subprocess.run(["chmod", "600", "/root/.ssh/id_ed25519"], check=True)



def main():
    data = wait_for_output(OUTPUT_PATH)
    host_ip = build_host_ip_map(data)

    control_plane_ips = set(as_list(data.get("control_plane_ip", {})) or [])
    worker_ips = set(as_list(data.get("worker_ips", {})) or [])

    control_plane_hosts = [h for h, ip in host_ip.items() if ip in control_plane_ips]
    worker_hosts = [h for h, ip in host_ip.items() if ip in worker_ips]

    # Windows-safe absolute path for SSH key
    ssh_key_path = (Path.home() / ".ssh" / "id_ed25519").as_posix()

    lines = []

    lines.append("[k8s_control_plane]")
    for h in control_plane_hosts:
        lines.append(f"{h} ansible_host={host_ip[h]}")
    lines.append("")

    lines.append("[k8s_workers]")
    for h in worker_hosts:
        lines.append(f"{h} ansible_host={host_ip[h]}")
    lines.append("")

    lines.append("[k8s:children]")
    lines.append("k8s_control_plane")
    lines.append("k8s_workers")
    lines.append("")

    lines.append("[k8s_all]")
    for h, ip in host_ip.items():
        lines.append(f"{h} ansible_host={ip}")
    lines.append("")

    lines.append("[all:vars]")
    lines.append(f"ansible_user={ANSIBLE_USER}")
    lines.append(f"ansible_ssh_private_key_file={ssh_key_path}")
    lines.append("ansible_ssh_common_args=-o StrictHostKeyChecking=no")
    lines.append("")
    # call this before ansible-playbook
    print("Preparing ssh file", flush=True)
    prepare_key()
    INVENTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    INVENTORY_PATH.write_text("\n".join(lines), encoding="utf-8")
    print("🧩 Running Ansible playbook...", flush=True)

    cmd = [
        "ansible-playbook",
        "-i", str(INVENTORY_PATH),
        "/work/ansible/playbook/playbook.yml",
        "-vvv",
    ]

    print("CMD:", " ".join(cmd), flush=True)

    p = subprocess.Popen(cmd, stdout=sys.stdout, stderr=sys.stderr, text=True)
    rc = p.wait()

    if rc != 0:
        raise SystemExit(rc)

    print("✅ Ansible finished successfully", flush=True)

if __name__ == "__main__":
    main()
