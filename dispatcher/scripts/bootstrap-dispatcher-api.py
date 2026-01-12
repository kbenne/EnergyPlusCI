#!/usr/bin/env python3
import base64
import os
import time
import tempfile
from pathlib import Path

import requests

# Bootstrap a dispatcher LXC via Proxmox API calls instead of shelling out to `pct`.
# This script is meant to be run from a machine that can reach the Proxmox API.


def env(name, default=None, required=False):
    # Minimal env helper with optional required enforcement.
    value = os.getenv(name, default)
    print(f"name: {name}, value {value}")
    if required and not value:
        raise SystemExit(f"missing required env var: {name}")
    return value


# Proxmox connection and authentication.
PROXMOX_URL = env("PROXMOX_URL", required=True).rstrip("/")
PROXMOX_NODE = env("PROXMOX_NODE", required=True)
PROXMOX_TOKEN_ID = env("PROXMOX_TOKEN_ID", required=True)
PROXMOX_TOKEN_SECRET = env("PROXMOX_TOKEN_SECRET", required=True)
PROXMOX_STORAGE_ENV = os.getenv("PROXMOX_STORAGE")
PROXMOX_STORAGE = env("PROXMOX_STORAGE", "local")
PROXMOX_VERIFY_SSL_ENV = os.getenv("PROXMOX_VERIFY_SSL")
PROXMOX_VERIFY_SSL = env("PROXMOX_VERIFY_SSL", "false").lower() in ("1", "true", "yes")

# LXC container (CT) parameters.
CT_ID = env("CT_ID")
CT_HOSTNAME = env("CT_HOSTNAME", "dispatcher-1")
CT_STORAGE = env("CT_STORAGE", "local-lvm")
CT_BRIDGE = env("CT_BRIDGE", "vmbr0")
CT_CORES = env("CT_CORES", "1")
CT_MEMORY = env("CT_MEMORY", "512")
CT_SWAP = env("CT_SWAP", "0")
CT_DISK = env("CT_DISK", "4")
CT_NET = env("CT_NET", f"name=eth0,bridge={CT_BRIDGE},ip=dhcp")
CT_TEMPLATE = env("CT_TEMPLATE", "debian-12-standard_12.2-1_amd64.tar.zst")
CT_TEMPLATE_URL = env(
    "CT_TEMPLATE_URL",
    f"https://download.proxmox.com/images/system/{CT_TEMPLATE}",
)
CT_TEMPLATE_URL_VERIFY = env("CT_TEMPLATE_URL_VERIFY", "true").lower() in ("1", "true", "yes")

# Service name inside the container.
SERVICE_NAME = env("SERVICE_NAME", "dispatcher")

# GitHub token used by the dispatcher to mint runner registration tokens.
GITHUB_TOKEN = env("GITHUB_TOKEN", required=True)
# Optional dispatcher overrides passed through to /etc/default.
TEMPLATE_NAME = os.getenv("TEMPLATE_NAME")
RUNNER_ID_START = os.getenv("RUNNER_ID_START")
RUNNER_ID_END = os.getenv("RUNNER_ID_END")
RUNNER_NAME_PREFIX = os.getenv("RUNNER_NAME_PREFIX")
REPO_OWNER = os.getenv("REPO_OWNER")
REPO_NAME = os.getenv("REPO_NAME")
REPO_URL = os.getenv("REPO_URL")
RUNNER_LABELS = os.getenv("RUNNER_LABELS")
POLL_INTERVAL = os.getenv("POLL_INTERVAL")
USER_DATA_TEMPLATE = env("USER_DATA_TEMPLATE", "/opt/dispatcher/cloud-init/runner-user-data.pkrtpl")
# Repository root for reading dispatcher code and template files to push into the CT.
DISPATCHER_DIR = Path(env("DISPATCHER_DIR", Path(__file__).resolve().parents[2]))


def proxmox_headers():
    # Proxmox API token auth header.
    return {
        "Authorization": f"PVEAPIToken={PROXMOX_TOKEN_ID}={PROXMOX_TOKEN_SECRET}",
    }


def proxmox_get(path):
    # Thin wrapper for GET requests to Proxmox API paths.
    url = f"{PROXMOX_URL}{path}"
    resp = requests.get(url, headers=proxmox_headers(), verify=PROXMOX_VERIFY_SSL, timeout=30)
    resp.raise_for_status()
    return resp.json()["data"]


def proxmox_post(path, data=None, files=None, timeout=30):
    # Thin wrapper for POST requests to Proxmox API paths.
    url = f"{PROXMOX_URL}{path}"
    resp = requests.post(
        url,
        headers=proxmox_headers(),
        data=data,
        files=files,
        verify=PROXMOX_VERIFY_SSL,
        timeout=timeout,
    )
    resp.raise_for_status()
    return resp.json()["data"]


def wait_for_task(upid):
    # Poll a Proxmox task until completion, raising on failure.
    while True:
        status = proxmox_get(f"/nodes/{PROXMOX_NODE}/tasks/{upid}/status")
        if status.get("status") == "stopped":
            if status.get("exitstatus") not in (None, "OK"):
                raise RuntimeError(f"proxmox task failed: {status}")
            return
        time.sleep(2)


def next_ct_id():
    # Ask Proxmox for the next free numeric ID in the cluster.
    data = proxmox_get("/cluster/nextid")
    return str(data)


def template_exists():
    # Verify the LXC OS template tarball exists in the configured storage.
    content = proxmox_get(f"/nodes/{PROXMOX_NODE}/storage/{PROXMOX_STORAGE}/content")
    for item in content:
        if item.get("content") == "vztmpl" and item.get("volid", "").endswith(CT_TEMPLATE):
            return True
    return False


def download_template():
    # Ask the Proxmox node to download the LXC template into storage.
    data = {
        "content": "vztmpl",
        "filename": CT_TEMPLATE,
        "url": CT_TEMPLATE_URL,
    }
    try:
        upid = proxmox_post(
            f"/nodes/{PROXMOX_NODE}/storage/{PROXMOX_STORAGE}/download", data=data
        )
        wait_for_task(upid)
        return
    except requests.HTTPError as exc:
        if exc.response is None or exc.response.status_code != 501:
            raise

    # Fallback: download locally and upload to Proxmox storage.
    with tempfile.NamedTemporaryFile(delete=False) as tmp:
        with requests.get(
            CT_TEMPLATE_URL,
            stream=True,
            timeout=300,
            verify=CT_TEMPLATE_URL_VERIFY,
        ) as resp:
            resp.raise_for_status()
            for chunk in resp.iter_content(chunk_size=1024 * 1024):
                if chunk:
                    tmp.write(chunk)
        temp_path = tmp.name

    with open(temp_path, "rb") as handle:
        files = {"filename": (CT_TEMPLATE, handle, "application/octet-stream")}
        upload_data = {"content": "vztmpl"}
        upid = proxmox_post(
            f"/nodes/{PROXMOX_NODE}/storage/{PROXMOX_STORAGE}/upload",
            data=upload_data,
            files=files,
            timeout=300,
        )
    wait_for_task(upid)


def create_container(vmid):
    # Create the LXC container with basic resources and networking.
    ostemplate = f"{PROXMOX_STORAGE}:vztmpl/{CT_TEMPLATE}"
    data = {
        "vmid": vmid,
        "hostname": CT_HOSTNAME,
        "ostemplate": ostemplate,
        "storage": CT_STORAGE,
        "cores": CT_CORES,
        "memory": CT_MEMORY,
        "swap": CT_SWAP,
        "rootfs": f"{CT_STORAGE}:{CT_DISK}",
        "net0": CT_NET,
        "features": "nesting=1",
        "unprivileged": 1,
    }
    upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/lxc", data=data)
    wait_for_task(upid)


def start_container(vmid):
    # Start the LXC container.
    upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/lxc/{vmid}/status/start")
    wait_for_task(upid)


def exec_command(vmid, command):
    # Run a shell command inside the container and wait for completion.
    # The exec API returns a pid that must be polled for completion status.
    data = [("command", "bash"), ("extra-args[]", "-lc"), ("extra-args[]", command)]
    pid = proxmox_post(f"/nodes/{PROXMOX_NODE}/lxc/{vmid}/exec", data=data)
    while True:
        status = proxmox_get(f"/nodes/{PROXMOX_NODE}/lxc/{vmid}/exec-status?pid={pid}")
        if status.get("exited"):
            if status.get("exitcode", 0) != 0:
                raise RuntimeError(f"command failed ({status.get('exitcode')}): {command}")
            return
        time.sleep(1)


def write_file(vmid, dest_path, contents):
    # Copy file content into the CT by base64-encoding and decoding in-place.
    encoded = base64.b64encode(contents.encode("utf-8")).decode("ascii")
    exec_command(vmid, f"mkdir -p {os.path.dirname(dest_path)} && echo '{encoded}' | base64 -d > {dest_path}")


def bootstrap_container(vmid):
    # Install runtime dependencies inside the CT.
    exec_command(vmid, "apt-get update")
    exec_command(vmid, "apt-get install -y python3 python3-venv python3-pip ca-certificates")

    # Read the dispatcher code and assets from the repo.
    dispatcher_py = (DISPATCHER_DIR / "dispatcher" / "dispatcher.py").read_text(encoding="utf-8")
    requirements = (DISPATCHER_DIR / "dispatcher" / "requirements.txt").read_text(encoding="utf-8")
    user_data_tpl = (
        DISPATCHER_DIR
        / "runners"
        / "ubuntu-2204"
        / "cloud-init"
        / "runner-user-data.pkrtpl"
    ).read_text(encoding="utf-8")

    # Write dispatcher files into the container filesystem.
    write_file(vmid, "/opt/dispatcher/dispatcher.py", dispatcher_py)
    write_file(vmid, "/opt/dispatcher/requirements.txt", requirements)
    write_file(vmid, "/opt/dispatcher/cloud-init/runner-user-data.pkrtpl", user_data_tpl)

    # Create a venv and install Python dependencies.
    exec_command(vmid, "python3 -m venv /opt/dispatcher/.venv")
    exec_command(vmid, "/opt/dispatcher/.venv/bin/pip install -r /opt/dispatcher/requirements.txt")

    # Write the dispatcher environment file used by systemd.
    env_lines = [
        f"PROXMOX_URL={PROXMOX_URL}",
        f"PROXMOX_NODE={PROXMOX_NODE}",
        f"PROXMOX_TOKEN_ID={PROXMOX_TOKEN_ID}",
        f"PROXMOX_TOKEN_SECRET={PROXMOX_TOKEN_SECRET}",
        f"GITHUB_TOKEN={GITHUB_TOKEN}",
        f"USER_DATA_TEMPLATE={USER_DATA_TEMPLATE}",
    ]
    optional_env = [
        ("PROXMOX_STORAGE", PROXMOX_STORAGE_ENV),
        ("PROXMOX_VERIFY_SSL", PROXMOX_VERIFY_SSL_ENV),
        ("TEMPLATE_NAME", TEMPLATE_NAME),
        ("RUNNER_ID_START", RUNNER_ID_START),
        ("RUNNER_ID_END", RUNNER_ID_END),
        ("RUNNER_NAME_PREFIX", RUNNER_NAME_PREFIX),
        ("REPO_OWNER", REPO_OWNER),
        ("REPO_NAME", REPO_NAME),
        ("REPO_URL", REPO_URL),
        ("RUNNER_LABELS", RUNNER_LABELS),
        ("POLL_INTERVAL", POLL_INTERVAL),
    ]
    for name, value in optional_env:
        if value is not None and value != "":
            env_lines.append(f"{name}={value}")
    env_file = "\n".join(env_lines)
    write_file(vmid, f"/etc/default/{SERVICE_NAME}", env_file + "\n")

    # Install and start a systemd service for the dispatcher.
    unit = "\n".join(
        [
            "[Unit]",
            "Description=Proxmox GitHub Actions dispatcher",
            "After=network-online.target",
            "",
            "[Service]",
            "Type=simple",
            f"EnvironmentFile=/etc/default/{SERVICE_NAME}",
            "ExecStart=/opt/dispatcher/.venv/bin/python /opt/dispatcher/dispatcher.py",
            "Restart=always",
            "RestartSec=5",
            "",
            "[Install]",
            "WantedBy=multi-user.target",
        ]
    )
    write_file(vmid, f"/etc/systemd/system/{SERVICE_NAME}.service", unit + "\n")
    exec_command(vmid, "systemctl daemon-reload")
    exec_command(vmid, f"systemctl enable --now {SERVICE_NAME}.service")


def main():
    # Ensure the LXC OS template exists, then create and bootstrap the container.
    if not template_exists():
        print(f"Template not found; requesting download of {CT_TEMPLATE} to {PROXMOX_STORAGE}...")
        download_template()

    vmid = CT_ID or next_ct_id()
    create_container(vmid)
    start_container(vmid)
    bootstrap_container(vmid)
    # Provide a simple confirmation line for logs/automation.
    print(f"Dispatcher LXC created and started: CT {vmid} ({CT_HOSTNAME})")


if __name__ == "__main__":
    main()
