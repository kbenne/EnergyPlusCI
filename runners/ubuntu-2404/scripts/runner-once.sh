#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "usage: $0 <repo_or_org_url> <registration_token> [labels] [runner_name]" >&2
  exit 2
fi

if [[ "$(id -u)" -eq 0 ]]; then
  runner_user="${RUNNER_USER:-ci}"
  if ! id -u "${runner_user}" >/dev/null 2>&1; then
    runner_user="$(getent passwd 1000 | cut -d: -f1 || true)"
  fi
  if [[ -n "${runner_user}" ]]; then
    exec /usr/sbin/runuser -u "${runner_user}" -- "$0" "$@"
  fi
  echo "runner-once: unable to drop privileges; no non-root user found" >&2
  exit 1
fi

repo_url="$1"
reg_token="$2"
labels="${3:-energyplus,linux,x64,ubuntu-24.04}"
runner_name="${4:-$(hostname)}"

cd /opt/actions-runner

cleanup() {
  if [[ -f .runner ]]; then
    ./config.sh remove --token "${reg_token}" || true
  fi
}
trap cleanup EXIT

./config.sh \
  --unattended \
  --replace \
  --ephemeral \
  --url "${repo_url}" \
  --token "${reg_token}" \
  --name "${runner_name}" \
  --labels "${labels}"

./run.sh
