#!/usr/bin/env python3
import json
import os
import time
import tempfile
from string import Template

import requests


def env(name, default=None, required=False):
    value = os.getenv(name, default)
    if required and not value:
        raise SystemExit(f"missing required env var: {name}")
    return value


PROXMOX_URL = env("PROXMOX_URL", required=True).rstrip("/")
PROXMOX_NODE = env("PROXMOX_NODE", required=True)
PROXMOX_TOKEN_ID = env("PROXMOX_TOKEN_ID", required=True)
PROXMOX_TOKEN_SECRET = env("PROXMOX_TOKEN_SECRET", required=True)
PROXMOX_STORAGE = env("PROXMOX_STORAGE", "local")
PROXMOX_VERIFY_SSL = env("PROXMOX_VERIFY_SSL", "false").lower() in ("1", "true", "yes")
SNIPPETS_DIR = env("SNIPPETS_DIR", "/opt/dispatcher/snippets")

TEMPLATE_NAME = env("TEMPLATE_NAME", "ubuntu-2404-runner-template")
RUNNER_ID_START = int(env("RUNNER_ID_START", "200"))
RUNNER_ID_END = int(env("RUNNER_ID_END", "299"))
RUNNER_NAME_PREFIX = env("RUNNER_NAME_PREFIX", "energyplus-runner")
RUNNER_USER = env("RUNNER_USER", "ci")

REPO_OWNER = env("REPO_OWNER", "NREL")
REPO_NAME = env("REPO_NAME", "EnergyPlus")
REPO_URL = env("REPO_URL", f"https://github.com/{REPO_OWNER}/{REPO_NAME}")
RUNNER_LABELS = env("RUNNER_LABELS", "energyplus,linux,x64,ubuntu-24.04")

GITHUB_TOKEN = env("GITHUB_TOKEN", required=True)
POLL_INTERVAL = int(env("POLL_INTERVAL", "15"))

USER_DATA_TEMPLATE = env(
    "USER_DATA_TEMPLATE", "runners/ubuntu-2404/cloud-init/runner-user-data.pkrtpl"
)


def proxmox_headers():
    return {
        "Authorization": f"PVEAPIToken={PROXMOX_TOKEN_ID}={PROXMOX_TOKEN_SECRET}",
    }


def proxmox_get(path):
    url = f"{PROXMOX_URL}{path}"
    resp = requests.get(url, headers=proxmox_headers(), verify=PROXMOX_VERIFY_SSL, timeout=30)
    resp.raise_for_status()
    return resp.json()["data"]


def proxmox_post(path, data=None, files=None):
    url = f"{PROXMOX_URL}{path}"
    resp = requests.post(
        url,
        headers=proxmox_headers(),
        data=data,
        files=files,
        verify=PROXMOX_VERIFY_SSL,
        timeout=30,
    )
    if not resp.ok:
        raise RuntimeError(f"proxmox POST failed: {resp.status_code} {resp.text}")
    return resp.json()["data"]


def wait_for_task(upid):
    while True:
        status = proxmox_get(f"/nodes/{PROXMOX_NODE}/tasks/{upid}/status")
        if status.get("status") == "stopped":
            if status.get("exitstatus") not in (None, "OK"):
                raise RuntimeError(f"proxmox task failed: {status}")
            return
        time.sleep(2)


def list_vms():
    return proxmox_get(f"/nodes/{PROXMOX_NODE}/qemu")


def find_template_vmid():
    for vm in list_vms():
        if vm.get("name") == TEMPLATE_NAME and vm.get("template", 0) == 1:
            return int(vm["vmid"])
    raise RuntimeError(f"template not found: {TEMPLATE_NAME}")


def find_runner_vms():
    runners = []
    for vm in list_vms():
        name = vm.get("name", "")
        if name.startswith(RUNNER_NAME_PREFIX):
            runners.append(vm)
    return runners


def delete_vm(vmid):
    try:
        upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/stop")
        wait_for_task(upid)
    except requests.HTTPError:
        pass
    upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/qemu/{vmid}/delete")
    wait_for_task(upid)


def next_vmid():
    existing = {int(vm["vmid"]) for vm in list_vms()}
    for vmid in range(RUNNER_ID_START, RUNNER_ID_END + 1):
        if vmid not in existing:
            return vmid
    raise RuntimeError("no free vmid in range")


def github_headers():
    return {
        "Accept": "application/vnd.github+json",
        "Authorization": f"Bearer {GITHUB_TOKEN}",
        "X-GitHub-Api-Version": "2022-11-28",
    }


def has_queued_runs():
    url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/actions/runs"
    resp = requests.get(url, headers=github_headers(), params={"status": "queued"}, timeout=30)
    resp.raise_for_status()
    return resp.json().get("total_count", 0) > 0


def registration_token():
    url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/actions/runners/registration-token"
    resp = requests.post(url, headers=github_headers(), timeout=30)
    resp.raise_for_status()
    return resp.json()["token"]


def render_user_data(reg_token, runner_name):
    with open(USER_DATA_TEMPLATE, "r", encoding="utf-8") as handle:
        template = Template(handle.read())
    return template.substitute(
        repo_url=REPO_URL,
        registration_token=reg_token,
        runner_labels=RUNNER_LABELS,
        runner_name=runner_name,
        runner_user=RUNNER_USER,
    )


def upload_snippet(contents, snippet_name):
    if SNIPPETS_DIR:
        os.makedirs(SNIPPETS_DIR, exist_ok=True)
        snippet_path = os.path.join(SNIPPETS_DIR, snippet_name)
        with open(snippet_path, "w", encoding="utf-8") as handle:
            handle.write(contents)
        return

    with tempfile.NamedTemporaryFile("w", delete=False) as handle:
        handle.write(contents)
        temp_path = handle.name
    with open(temp_path, "rb") as handle:
        files = {"filename": (snippet_name, handle, "text/plain")}
        data = {"content": "snippets"}
        upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/storage/{PROXMOX_STORAGE}/upload", data=data, files=files)
    wait_for_task(upid)


def configure_cloud_init(vmid, snippet_name):
    cicustom = f"user={PROXMOX_STORAGE}:snippets/{snippet_name}"
    data = {"cicustom": cicustom}
    upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/qemu/{vmid}/config", data=data)
    wait_for_task(upid)


def update_cloud_init(vmid):
    upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/qemu/{vmid}/cloudinit")
    wait_for_task(upid)


def clone_and_start():
    template_id = find_template_vmid()
    vmid = next_vmid()
    runner_name = f"{RUNNER_NAME_PREFIX}-{vmid}"

    reg_token = registration_token()
    user_data = render_user_data(reg_token, runner_name)
    snippet_name = f"{runner_name}.yaml"
    upload_snippet(user_data, snippet_name)

    data = {"newid": vmid, "name": runner_name, "full": 0, "target": PROXMOX_NODE}
    upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/qemu/{template_id}/clone", data=data)
    wait_for_task(upid)

    configure_cloud_init(vmid, snippet_name)
    update_cloud_init(vmid)
    upid = proxmox_post(f"/nodes/{PROXMOX_NODE}/qemu/{vmid}/status/start")
    wait_for_task(upid)


def cleanup_stopped_runners():
    for vm in find_runner_vms():
        if vm.get("status") == "stopped":
            delete_vm(int(vm["vmid"]))


def any_runner_active():
    for vm in find_runner_vms():
        if vm.get("status") in ("running", "starting"):
            return True
    return False


def main():
    while True:
        cleanup_stopped_runners()
        if not any_runner_active() and has_queued_runs():
            clone_and_start()
        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
