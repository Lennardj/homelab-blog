import json
from pathlib import Path

OUTPUT_PATH = Path("../proxmox/output.json")  # wherever you write terraform output
INVENTORY_PATH = Path("ansible/inventory/hosts.ini")

ANSIBLE_USER = "ubuntu"


def as_list(terraform_output_obj):
    if isinstance(terraform_output_obj, dict) and "value" in terraform_output_obj:
        return terraform_output_obj["value"]
    return terraform_output_obj


def build_host_ip_map(data: dict) -> dict:
    hostnames = as_list(data.get("all_nodes_hostnames", {}))
    ips = as_list(data.get("all_nodes_ips", {}))

    if not isinstance(hostnames, list) or not isinstance(ips, list):
        raise ValueError("Expected lists for all_nodes_hostnames and all_nodes_ips")

    if len(hostnames) != len(ips):
        raise ValueError(f"Hostname/IP mismatch: {len(hostnames)} != {len(ips)}")

    return {str(h).strip(): str(ip).strip() for h, ip in zip(hostnames, ips)}


def main():
    data = json.loads(OUTPUT_PATH.read_text(encoding="utf-8"))
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

    INVENTORY_PATH.parent.mkdir(parents=True, exist_ok=True)
    INVENTORY_PATH.write_text("\n".join(lines), encoding="utf-8")
    print(f"✅ Wrote inventory: {INVENTORY_PATH}")


if __name__ == "__main__":
    main()
