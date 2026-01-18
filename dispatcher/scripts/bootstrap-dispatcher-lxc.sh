#!/usr/bin/env bash
set -euo pipefail

# Bootstrap a lightweight LXC on Proxmox to run the dispatcher as a systemd service.
# Run this script on the Proxmox host.

ENV_FILE="${ENV_FILE:-${DISPATCHER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}/dispatcher/dispatcher.env}"

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
CT_TEMPLATE_FILE="${CT_TEMPLATE_FILE:-}"
CT_ROOT_PASSWORD="${CT_ROOT_PASSWORD:-}"
SNIPPETS_DIR="${SNIPPETS_DIR:-/opt/dispatcher/snippets}"

DISPATCHER_DIR="${DISPATCHER_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
SERVICE_NAME="${SERVICE_NAME:-dispatcher}"

PROXMOX_URL="${PROXMOX_URL:-https://127.0.0.1:8006/api2/json}"
PROXMOX_NODE="${PROXMOX_NODE:-}"
PROXMOX_TOKEN_ID="${PROXMOX_TOKEN_ID:-}"
PROXMOX_TOKEN_SECRET="${PROXMOX_TOKEN_SECRET:-}"
GITHUB_TOKEN="${GITHUB_TOKEN:-}"
PROXMOX_STORAGE="${PROXMOX_STORAGE:-local}"

if [[ -f "${ENV_FILE}" ]]; then
  # shellcheck source=/dev/null
  source "${ENV_FILE}"
fi

if [[ -z "${PROXMOX_URL}" || -z "${PROXMOX_NODE}" || -z "${PROXMOX_TOKEN_ID}" || -z "${PROXMOX_TOKEN_SECRET}" || -z "${GITHUB_TOKEN}" ]]; then
  echo "Missing required env vars: PROXMOX_URL, PROXMOX_NODE, PROXMOX_TOKEN_ID, PROXMOX_TOKEN_SECRET, GITHUB_TOKEN" >&2
  exit 1
fi

if [[ ! -d "${DISPATCHER_DIR}/dispatcher" || ! -d "${DISPATCHER_DIR}/runners/ubuntu-2404/cloud-init" ]]; then
  echo "DISPATCHER_DIR must point to the repo root (contains dispatcher/ and runners/ubuntu-2404/)" >&2
  exit 1
fi

ensure_template() {
  if [[ -n "${CT_TEMPLATE_FILE}" ]]; then
    if [[ ! -f "${CT_TEMPLATE_FILE}" ]]; then
      echo "CT_TEMPLATE_FILE not found: ${CT_TEMPLATE_FILE}" >&2
      exit 1
    fi
    CT_TEMPLATE="$(basename "${CT_TEMPLATE_FILE}")"
    cp -f "${CT_TEMPLATE_FILE}" "/var/lib/vz/template/cache/${CT_TEMPLATE}"
    return 0
  fi
  if [[ -n "${CT_TEMPLATE}" ]]; then
    return 0
  fi
  local cached
  cached="$(pveam list local | awk '{print $1}' | grep -E '^debian-12-standard_.*_amd64.tar.zst$' | sort -V | tail -n 1 || true)"
  if [[ -n "${cached}" ]]; then
    CT_TEMPLATE="${cached}"
    return 0
  fi
  echo "No cached Debian 12 LXC template found in local storage; downloading latest..." >&2
  CT_TEMPLATE="$(pveam available --section system | awk '{print $2}' | grep -E '^debian-12-standard_.*_amd64.tar.zst$' | sort -V | tail -n 1 || true)"
  if [[ -z "${CT_TEMPLATE}" ]]; then
    echo "Unable to find Debian 12 LXC template in pveam available list" >&2
    exit 1
  fi
  pveam download local "${CT_TEMPLATE}"
}

create_container() {
  if pct status "${CT_ID}" >/dev/null 2>&1; then
    echo "CT ${CT_ID} already exists; destroying before recreate." >&2
    pct stop "${CT_ID}" || true
    pct destroy "${CT_ID}"
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
  mkdir -p /var/lib/vz/snippets
  chown 100000:100000 /var/lib/vz/snippets
  pct set "${CT_ID}" --mp0 /var/lib/vz/snippets,mp="${SNIPPETS_DIR}"
}

start_container() {
  pct start "${CT_ID}"
  sleep 2
}

set_root_password() {
  local root_password="${CT_ROOT_PASSWORD:-}"
  if [[ -n "${root_password}" ]]; then
    pct exec "${CT_ID}" -- bash -lc "echo root:${root_password} | chpasswd"
  fi
}

install_deps() {
  pct exec "${CT_ID}" -- bash -lc "apt-get update && apt-get install -y python3 python3-venv python3-pip ca-certificates"
}

push_files() {
  pct exec "${CT_ID}" -- mkdir -p /opt/dispatcher
  pct push "${CT_ID}" "${DISPATCHER_DIR}/dispatcher/dispatcher.py" /opt/dispatcher/dispatcher.py
  pct push "${CT_ID}" "${DISPATCHER_DIR}/dispatcher/requirements.txt" /opt/dispatcher/requirements.txt
  pct push "${CT_ID}" "${DISPATCHER_DIR}/dispatcher/runner-pools.json" /opt/dispatcher/runner-pools.json
  pct exec "${CT_ID}" -- mkdir -p /opt/dispatcher/cloud-init
  pct push "${CT_ID}" "${DISPATCHER_DIR}/runners/ubuntu-2404/cloud-init/runner-user-data.pkrtpl" /opt/dispatcher/cloud-init/runner-user-data-2404.pkrtpl
  pct push "${CT_ID}" "${DISPATCHER_DIR}/runners/ubuntu-2204/cloud-init/runner-user-data.pkrtpl" /opt/dispatcher/cloud-init/runner-user-data-2204.pkrtpl
}

setup_venv() {
  pct exec "${CT_ID}" -- bash -lc "python3 -m venv /opt/dispatcher/.venv && /opt/dispatcher/.venv/bin/pip install -r /opt/dispatcher/requirements.txt"
}

write_env_file() {
  local user_data_template="${USER_DATA_TEMPLATE:-}"
  local proxmox_storage="${PROXMOX_STORAGE:-}"
  local proxmox_verify_ssl="${PROXMOX_VERIFY_SSL:-}"
  local template_name="${TEMPLATE_NAME:-}"
  local runner_id_start="${RUNNER_ID_START:-}"
  local runner_id_end="${RUNNER_ID_END:-}"
  local runner_name_prefix="${RUNNER_NAME_PREFIX:-}"
  local repo_owner="${REPO_OWNER:-}"
  local repo_name="${REPO_NAME:-}"
  local repo_url="${REPO_URL:-}"
  local runner_labels="${RUNNER_LABELS:-}"
  local poll_interval="${POLL_INTERVAL:-}"
  local snippets_dir="${SNIPPETS_DIR:-}"
  pct exec "${CT_ID}" -- bash -lc "cat /dev/null > /etc/default/${SERVICE_NAME}
if [[ -n \"${PROXMOX_URL:-}\" ]]; then echo \"PROXMOX_URL=${PROXMOX_URL}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_NODE:-}\" ]]; then echo \"PROXMOX_NODE=${PROXMOX_NODE}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_TOKEN_ID:-}\" ]]; then echo \"PROXMOX_TOKEN_ID=${PROXMOX_TOKEN_ID}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${PROXMOX_TOKEN_SECRET:-}\" ]]; then echo \"PROXMOX_TOKEN_SECRET=${PROXMOX_TOKEN_SECRET}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${GITHUB_TOKEN:-}\" ]]; then echo \"GITHUB_TOKEN=${GITHUB_TOKEN}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${user_data_template}\" ]]; then echo \"USER_DATA_TEMPLATE=${user_data_template}\" >> /etc/default/${SERVICE_NAME}; else echo \"USER_DATA_TEMPLATE=/opt/dispatcher/cloud-init/runner-user-data.pkrtpl\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${proxmox_storage}\" ]]; then echo \"PROXMOX_STORAGE=${proxmox_storage}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${proxmox_verify_ssl}\" ]]; then echo \"PROXMOX_VERIFY_SSL=${proxmox_verify_ssl}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${template_name}\" ]]; then echo \"TEMPLATE_NAME=${template_name}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${runner_id_start}\" ]]; then echo \"RUNNER_ID_START=${runner_id_start}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${runner_id_end}\" ]]; then echo \"RUNNER_ID_END=${runner_id_end}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${runner_name_prefix}\" ]]; then echo \"RUNNER_NAME_PREFIX=${runner_name_prefix}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${repo_owner}\" ]]; then echo \"REPO_OWNER=${repo_owner}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${repo_name}\" ]]; then echo \"REPO_NAME=${repo_name}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${repo_url}\" ]]; then echo \"REPO_URL=${repo_url}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${runner_labels}\" ]]; then echo \"RUNNER_LABELS=${runner_labels}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${poll_interval}\" ]]; then echo \"POLL_INTERVAL=${poll_interval}\" >> /etc/default/${SERVICE_NAME}; fi
if [[ -n \"${snippets_dir}\" ]]; then echo \"SNIPPETS_DIR=${snippets_dir}\" >> /etc/default/${SERVICE_NAME}; fi"
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
set_root_password
install_deps
push_files
setup_venv
write_env_file
write_systemd

echo "Dispatcher LXC setup complete: CT ${CT_ID} (${CT_HOSTNAME})"
