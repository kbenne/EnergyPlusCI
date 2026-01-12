#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <repo_or_org_url> <registration_token> [labels] [runner_name]" >&2
  exit 2
fi

repo_url="$1"
reg_token="$2"
labels="${3:-energyplus,linux,x64,ubuntu-22.04}"
runner_name="${4:-$(hostname)}"

cd /opt/actions-runner

cleanup() {
  ./config.sh remove --unattended --token "${reg_token}" || true
}
trap cleanup EXIT

./config.sh \
  --unattended \
  --replace \
  --url "${repo_url}" \
  --token "${reg_token}" \
  --name "${runner_name}" \
  --labels "${labels}"

./run.sh --once
