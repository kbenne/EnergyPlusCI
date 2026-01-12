#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a lightweight LXC on Proxmox to run the dispatcher as a systemd service.
# Run this script on the Proxmox host.

CT_ID="${CT_ID:-300}"
CT_HOSTNAME="${CT_HOSTNAME:-dispatcher-1}"
CT_STORAGE="${CT_STORAGE:-local-lvm}"
CT_BRIDGE="${CT_BRIDGE:-vmbr0}"
CT_CORES="${CT_CORES:-1}"
CT_MEMORY="${CT_MEMORY:-512}"
CT_SWAP="${CT_SWAP:-0}"
CT_DISK="${CT_DISK:-4}"
CT_NET="${CT_NET:-name=eth0,bridge=${CT_BRIDGE},ip=dhcp}"
CT_TEMPLATE="${CT_TEMPLATE:-}"

DISPATCHER_DIR="${DISPATCHER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SERVICE_NAME="${SERVICE_NAME:-dispatcher}"

PROXMOX_URL="${PROXMOX_URL:-https://127.0.0.1:8006/api2/json}"
PROXMOX_NODE="${PROXMOX_NODE:-}"
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"

if [[ -z "${PROXMOX_URL}" || -z "${PROXMOX_NODE}" || -z "${PROXMOX_TOKEN_ID}" || -z "${PROXMOX_TOKEN_SECRET}" || -z "${GITHUB_TOKEN}" ]]; then
  echo "Missing required env vars: PROXMOX_URL, PROXMOX_NODE, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET, GITHUB_TOKEN" >&2
  exit 1
fi

if [[ ! -d "${DISPATCHER_DIR}/dispatcher" || ! -d "${DISPATCHER_DIR}/runners/ubuntu-2204/cloud-init" ]]; then
  echo "DISPATCHER_DIR must point to the repo root (contains dispatcher/ and runners/ubuntu-2204/)" >&2
  exit 1
fi

ensure_template() {
  if [[ -n "${CT_TEMPLATE}" ]]; then
    return 0
  fi
  local cached
  cached="$(pveam list local | awk '{print $1}' | grep -E '^debian-12-standard_.*_amd64.tar.zst$' | sort -V | tail -n 1 || true)"
  if [[ -n "${cached}" ]]; then
    CT_TEMPLATE="${cached}"
    return 0
  fi
  echo "No cached Debian 12 LXC template found in local storage; downloading..." >&2
  pveam download local debian-12-standard_12.2-1_amd64.tar.zst
  CT_TEMPLATE="debian-12-standard_12.2-1_amd64.tar.zst"
}

create_container() {
  if pct status "${CT_ID}" >/dev/null 2>&1; then
    echo "CT ${CT_ID} already exists; skipping create." >&2
    return 0
  fi
  pct create "${CT_ID}" "local:vztmpl/${CT_TEMPLATE}" \
    --hostname "${CT_HOSTNAME}" \
    --storage "${CT_STORAGE}" \
    --cores "${CT_CORES}" \
    --memory "${CT_MEMORY}" \
    --swap "${CT_SWAP}" \
    --rootfs "${CT_STORAGE}:${CT_DISK}" \
    --net0 "${CT_NET}" \
    --features nesting=1 \
    --unprivileged 1
}

start_container() {
  pct start "${CT_ID}"
  sleep 2
}

install_deps() {
  pct exec "${CT_ID}" -- bash -lc "apt-get update && apt-get install -y python3 python3-venv python3-pip ca-certificates"
}

push_files() {
  pct exec "${CT_ID}" -- mkdir -p /opt/dispatcher
  pct push "${CT_ID}" "${DISPATCHER_DIR}/dispatcher/dispatcher.py" /opt/dispatcher/dispatcher.py
  pct push "${CT_ID}" "${DISPATCHER_DIR}/dispatcher/requirements.txt" /opt/dispatcher/requirements.txt
  pct exec "${CT_ID}" -- mkdir -p /opt/dispatcher/cloud-init
  pct push "${CT_ID}" "${DISPATCHER_DIR}/runners/ubuntu-2204/cloud-init/runner-user-data.pkrtpl" /opt/dispatcher/cloud-init/runner-user-data.pkrtpl
}

setup_venv() {
  pct exec "${CT_ID}" -- bash -lc "python3 -m venv /opt/dispatcher/.venv && /opt/dispatcher/.venv/bin/pip install -r /opt/dispatcher/requirements.txt"
}

write_env_file() {
  pct exec "${CT_ID}" -- bash -lc "cat /dev/null > /etc/default/${SERVICE_NAME}
if [[ -n \"${PROXMOX_URL:-}\" ]]; then echo \"PROXMOX_URL=${PROXMOX_URL}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_NODE:-}\" ]]; then echo \"PROXMOX_NODE=${PROXMOX_NODE}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_TOKEN_ID:-}\" ]]; then echo \"PROXMOX_TOKEN_ID=${PROXMOX_TOKEN_ID}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_TOKEN_SECRET:-}\" ]]; then echo \"PROXMOX_TOKEN_SECRET=${PROXMOX_TOKEN_SECRET}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${GITHUB_TOKEN:-}\" ]]; then echo \"GITHUB_TOKEN=${GITHUB_TOKEN}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${USER_DATA_TEMPLATE:-}\" ]]; then echo \"USER_DATA_TEMPLATE=${USER_DATA_TEMPLATE}\" >> /etc/default/${SERVICE_NAME}; else echo \"USER_DATA_TEMPLATE=/opt/dispatcher/cloud-init/runner-user-data.pkrtpl\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_STORAGE:-}\" ]]; then echo \"PROXMOX_STORAGE=${PROXMOX_STORAGE}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_VERIFY_SSL:-}\" ]]; then echo \"PROXMOX_VERIFY_SSL=${PROXMOX_VERIFY_SSL}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${TEMPLATE_NAME:-}\" ]]; then echo \"TEMPLATE_NAME=${TEMPLATE_NAME}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${RUNNER_ID_START:-}\" ]]; then echo \"RUNNER_ID_START=${RUNNER_ID_START}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${RUNNER_ID_END:-}\" ]]; then echo \"RUNNER_ID_END=${RUNNER_ID_END}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${RUNNER_NAME_PREFIX:-}\" ]]; then echo \"RUNNER_NAME_PREFIX=${RUNNER_NAME_PREFIX}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${REPO_OWNER:-}\" ]]; then echo \"REPO_OWNER=${REPO_OWNER}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${REPO_NAME:-}\" ]]; then echo \"REPO_NAME=${REPO_NAME}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${REPO_URL:-}\" ]]; then echo \"REPO_URL=${REPO_URL}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${RUNNER_LABELS:-}\" ]]; then echo \"RUNNER_LABELS=${RUNNER_LABELS}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${POLL_INTERVAL:-}\" ]]; then echo \"POLL_INTERVAL=${POLL_INTERVAL}\" >> /etc/default/${SERVICE_NAME}; fi"
}

write_systemd() {
  pct exec "${CT_ID}" -- bash -lc "cat > /etc/systemd/system/${SERVICE_NAME}.service <<'EOF'
[Unit]
Description=Proxmox GitHub Actions dispatcher
After=network-online.target

[Service]
Type=simple
EnvironmentFile=/etc/default/${SERVICE_NAME}
ExecStart=/opt/dispatcher/.venv/bin/python /opt/dispatcher/dispatcher.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"
  pct exec "${CT_ID}" -- systemctl daemon-reload
  pct exec "${CT_ID}" -- systemctl enable --now "${SERVICE_NAME}.service"
}

ensure_template
create_container
start_container
install_deps
push_files
setup_venv
write_env_file
write_systemd

echo "Dispatcher LXC setup complete: CT ${CT_ID} (${CT_HOSTNAME})"
