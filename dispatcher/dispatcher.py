#!/usr/bin/env python3
import os
import time
import tempfile
from string import Template

import requests
import json


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
DISPATCHER_DIR = os.path.dirname(os.path.abspath(__file__))
RUNNER_POOLS_CONFIG = env(
    "RUNNER_POOLS_CONFIG", os.path.join(DISPATCHER_DIR, "runner-pools.json")
)
MAX_TOTAL_RUNNERS = int(env("MAX_TOTAL_RUNNERS", "0"))

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


def load_pools():
    with open(RUNNER_POOLS_CONFIG, "r", encoding="utf-8") as handle:
        config = json.load(handle)
    max_total = int(config.get("max_total_runners", 0))
    pools = [normalize_pool(pool) for pool in config.get("pools", [])]
    if not pools:
        raise SystemExit("RUNNER_POOLS_CONFIG has no pools defined")
    if MAX_TOTAL_RUNNERS > 0:
        max_total = MAX_TOTAL_RUNNERS
    return max_total, pools


def normalize_pool(pool):
    normalized = dict(pool)
    normalized.setdefault("node", PROXMOX_NODE)
    normalized.setdefault("template", TEMPLATE_NAME)
    normalized.setdefault("labels", RUNNER_LABELS.split(","))
    normalized.setdefault("vmid_start", RUNNER_ID_START)
    normalized.setdefault("vmid_end", RUNNER_ID_END)
    normalized.setdefault("runner_name_prefix", RUNNER_NAME_PREFIX)
    normalized.setdefault("runner_user", RUNNER_USER)
    normalized.setdefault("user_data_template", USER_DATA_TEMPLATE)
    normalized.setdefault("storage", PROXMOX_STORAGE)
    normalized.setdefault("max_runners", 0)

    labels = normalized.get("labels", [])
    if isinstance(labels, str):
        normalized["labels"] = [label.strip() for label in labels.split(",") if label.strip()]
    normalized["match_labels"] = sorted(set(normalized["labels"]) | {"self-hosted"})
    return normalized


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


def proxmox_delete(path):
    url = f"{PROXMOX_URL}{path}"
    resp = requests.delete(
        url,
        headers=proxmox_headers(),
        verify=PROXMOX_VERIFY_SSL,
        timeout=30,
    )
    if not resp.ok:
        raise RuntimeError(f"proxmox DELETE failed: {resp.status_code} {resp.text}")
    return resp.json()["data"]


def wait_for_task(upid):
    while True:
        status = proxmox_get(f"/nodes/{PROXMOX_NODE}/tasks/{upid}/status")
        if status.get("status") == "stopped":
            if status.get("exitstatus") not in (None, "OK"):
                raise RuntimeError(f"proxmox task failed: {status}")
            return
        time.sleep(2)


def list_vms(node):
    return proxmox_get(f"/nodes/{node}/qemu")


def find_template_vmid(node, template_name):
    for vm in list_vms(node):
        if vm.get("name") == template_name and vm.get("template", 0) == 1:
            return int(vm["vmid"])
    raise RuntimeError(f"template not found: {template_name}")


def find_runner_vms(vms, prefixes):
    runners = []
    for vm in vms:
        name = vm.get("name", "")
        if any(name.startswith(prefix) for prefix in prefixes):
            runners.append(vm)
    return runners


def delete_vm(node, vmid):
    try:
        upid = proxmox_post(f"/nodes/{node}/qemu/{vmid}/status/stop")
        wait_for_task(upid)
    except requests.HTTPError:
        pass
    upid = proxmox_delete(f"/nodes/{node}/qemu/{vmid}")
    wait_for_task(upid)


def next_vmid(pool, existing):
    for vmid in range(pool["vmid_start"], pool["vmid_end"] + 1):
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


def list_queued_jobs():
    queued_jobs = []
    url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/actions/runs"
    page = 1
    while True:
        resp = requests.get(
            url,
            headers=github_headers(),
            params={"status": "queued", "per_page": 100, "page": page},
            timeout=30,
        )
        resp.raise_for_status()
        runs = resp.json().get("workflow_runs", [])
        if not runs:
            break
        for run in runs:
            queued_jobs.extend(list_jobs_for_run(run["id"]))
        if len(runs) < 100:
            break
        page += 1
    return queued_jobs


def list_jobs_for_run(run_id):
    jobs = []
    url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/actions/runs/{run_id}/jobs"
    page = 1
    while True:
        resp = requests.get(
            url,
            headers=github_headers(),
            params={"per_page": 100, "page": page},
            timeout=30,
        )
        resp.raise_for_status()
        payload = resp.json().get("jobs", [])
        for job in payload:
            if job.get("status") == "queued":
                jobs.append(job)
        if len(payload) < 100:
            break
        page += 1
    return jobs


def registration_token():
    url = f"https://api.github.com/repos/{REPO_OWNER}/{REPO_NAME}/actions/runners/registration-token"
    resp = requests.post(url, headers=github_headers(), timeout=30)
    resp.raise_for_status()
    return resp.json()["token"]


def render_user_data(reg_token, runner_name, runner_user, user_data_template, runner_labels):
    with open(user_data_template, "r", encoding="utf-8") as handle:
        template = Template(handle.read())
    return template.substitute(
        repo_url=REPO_URL,
        registration_token=reg_token,
        runner_labels=runner_labels,
        runner_name=runner_name,
        runner_user=runner_user,
    )


def upload_snippet(contents, snippet_name, node, storage):
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
        upid = proxmox_post(f"/nodes/{node}/storage/{storage}/upload", data=data, files=files)
    wait_for_task(upid)


def configure_cloud_init(vmid, snippet_name, node, storage):
    cicustom = f"user={storage}:snippets/{snippet_name}"
    data = {"cicustom": cicustom}
    upid = proxmox_post(f"/nodes/{node}/qemu/{vmid}/config", data=data)
    wait_for_task(upid)


def update_cloud_init(node, vmid):
    try:
        upid = proxmox_post(f"/nodes/{node}/qemu/{vmid}/cloudinit")
    except RuntimeError as exc:
        message = str(exc)
        if "501" in message and "/cloudinit" in message:
            print("warning: proxmox cloudinit endpoint unavailable; skipping update")
            return
        raise
    wait_for_task(upid)


def clone_and_start(pool, existing_vms):
    node = pool["node"]
    template_id = find_template_vmid(node, pool["template"])
    vmid = next_vmid(pool, existing_vms)
    runner_name = f"{pool['runner_name_prefix']}-{vmid}"

    reg_token = registration_token()
    user_data = render_user_data(
        reg_token,
        runner_name,
        pool["runner_user"],
        pool["user_data_template"],
        ",".join(pool["labels"]),
    )
    snippet_name = f"{runner_name}.yaml"
    upload_snippet(user_data, snippet_name, node, pool["storage"])

    data = {"newid": vmid, "name": runner_name, "full": 0, "target": node}
    upid = proxmox_post(f"/nodes/{node}/qemu/{template_id}/clone", data=data)
    wait_for_task(upid)

    configure_cloud_init(vmid, snippet_name, node, pool["storage"])
    update_cloud_init(node, vmid)
    upid = proxmox_post(f"/nodes/{node}/qemu/{vmid}/status/start")
    wait_for_task(upid)
    return vmid


def cleanup_stopped_runners(pools, vms_by_node):
    for pool in pools:
        node = pool["node"]
        prefixes = {pool["runner_name_prefix"]}
        runners = find_runner_vms(vms_by_node.get(node, []), prefixes)
        for vm in runners:
            if vm.get("status") == "stopped":
                delete_vm(node, int(vm["vmid"]))


def pool_active_count(pool, vms):
    prefixes = {pool["runner_name_prefix"]}
    runners = find_runner_vms(vms, prefixes)
    return sum(1 for vm in runners if vm.get("status") in ("running", "starting"))


def pool_match(pool, job_labels):
    return set(job_labels).issubset(set(pool["match_labels"]))


def choose_pool(pools, job_labels):
    matching = [pool for pool in pools if pool_match(pool, job_labels)]
    if not matching:
        return None
    return min(matching, key=lambda pool: len(pool["labels"]))


def collect_node_vms(pools):
    vms_by_node = {}
    for pool in pools:
        node = pool["node"]
        if node not in vms_by_node:
            vms_by_node[node] = list_vms(node)
    return vms_by_node


def main():
    max_total, pools = load_pools()
    while True:
        vms_by_node = collect_node_vms(pools)
        cleanup_stopped_runners(pools, vms_by_node)

        queued_jobs = list_queued_jobs()
        if not queued_jobs:
            time.sleep(POLL_INTERVAL)
            continue

        needed_counts = {pool["name"]: 0 for pool in pools}
        for job in queued_jobs:
            labels = job.get("labels", [])
            pool = choose_pool(pools, labels)
            if pool:
                needed_counts[pool["name"]] += 1

        total_active = 0
        active_by_pool = {}
        for pool in pools:
            node = pool["node"]
            active = pool_active_count(pool, vms_by_node.get(node, []))
            active_by_pool[pool["name"]] = active
            total_active += active

        total_capacity = max_total if max_total > 0 else None
        available_total = None if total_capacity is None else max(total_capacity - total_active, 0)

        for pool in pools:
            need = needed_counts.get(pool["name"], 0)
            active = active_by_pool.get(pool["name"], 0)
            to_start = max(0, need - active)
            if to_start == 0:
                continue

            pool_cap = pool.get("max_runners", 0)
            if pool_cap:
                to_start = min(to_start, max(pool_cap - active, 0))
            if available_total is not None:
                to_start = min(to_start, available_total)

            if to_start <= 0:
                continue

            node_vms = vms_by_node.get(pool["node"], [])
            existing = {int(vm["vmid"]) for vm in node_vms}
            for _ in range(to_start):
                vmid = clone_and_start(pool, existing)
                existing.add(vmid)
                if available_total is not None:
                    available_total -= 1
                    if available_total <= 0:
                        break
            if available_total is not None and available_total <= 0:
                break

        time.sleep(POLL_INTERVAL)


if __name__ == "__main__":
    main()
