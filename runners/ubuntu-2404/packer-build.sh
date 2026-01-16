#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
vars_file="${VARS_FILE:-${script_dir}/packer.auto.pkrvars.hcl}"
config_file="${script_dir}/ubuntu-2404-runner-iso.pkr.hcl"

get_var_from_file() {
  local key="$1"
  local file="$2"
  local value

  value="$(sed -n "s/^${key}[[:space:]]*=[[:space:]]*\"\\(.*\\)\"[[:space:]]*$/\\1/p" "${file}" | head -n 1)"
  if [[ -n "${value}" ]]; then
    printf '%s' "${value}"
    return 0
  fi
  return 1
}

get_default_from_config() {
  local var_name="$1"
  awk -v var_name="${var_name}" '
    $0 ~ "variable[[:space:]]+\""var_name"\"" { in_block=1 }
    in_block && $0 ~ /default[[:space:]]*=/ {
      gsub(/.*default[[:space:]]*=[[:space:]]*\"/, "", $0)
      gsub(/\".*/, "", $0)
      print $0
      exit
    }
    in_block && $0 ~ /}/ { in_block=0 }
  ' "${config_file}"
}

require_value() {
  local name="$1"
  local value="$2"

  if [[ -z "${value}" ]]; then
    echo "Missing ${name}. Set ${name} in ${vars_file} or export ${name^^}." >&2
    exit 1
  fi
}

proxmox_url="${PROXMOX_URL:-$(get_var_from_file "proxmox_url" "${vars_file}" || true)}"
proxmox_username="${PROXMOX_USERNAME:-$(get_var_from_file "proxmox_username" "${vars_file}" || true)}"
proxmox_token="${PROXMOX_TOKEN:-$(get_var_from_file "proxmox_token" "${vars_file}" || true)}"
proxmox_node="${PROXMOX_NODE:-$(get_var_from_file "proxmox_node" "${vars_file}" || true)}"
iso_url="${ISO_URL:-$(get_var_from_file "iso_url" "${vars_file}" || true)}"

if [[ -z "${iso_url}" ]]; then
  iso_url="$(get_default_from_config "iso_url")"
fi

require_value "proxmox_url" "${proxmox_url}"
require_value "proxmox_username" "${proxmox_username}"
require_value "proxmox_token" "${proxmox_token}"
require_value "proxmox_node" "${proxmox_node}"
require_value "iso_url" "${iso_url}"

iso_name="$(basename "${iso_url}")"
iso_storage="${PROXMOX_ISO_STORAGE:-local}"
volid="${iso_storage}:iso/${iso_name}"

auth_header="Authorization: PVEAPIToken=${proxmox_username}=${proxmox_token}"
content_url="${proxmox_url}/nodes/${proxmox_node}/storage/${iso_storage}/content?content=iso"

if curl -fsS -H "${auth_header}" "${content_url}" | rg -q "\"volid\"\\s*:\\s*\"${volid}\""; then
  echo "Found existing ISO: ${volid}"
  export PACKER_VAR_iso_file="${volid}"
else
  echo "ISO not found on Proxmox storage; will download: ${iso_url}"
  unset PACKER_VAR_iso_file || true
fi

exec packer build "${script_dir}"
