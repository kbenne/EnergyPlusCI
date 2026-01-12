# Ephemeral GitHub Actions Runners on Proxmox

Use this repo to build an Ubuntu runner VM template and run ephemeral, one-job GitHub Actions runners for `NREL/EnergyPlus` on Proxmox.

This guide is **prescriptive**. Follow the steps in order.

> Proxmox must already be installed and working. Proxmox storage and VM setup details are in `PROXMOX_SETUP.md`.

---

## Repo Layout

- `runners/ubuntu-2204/` — Packer template + cloud-init templates for the Ubuntu 22.04 runner image
- `dispatcher/` — autoscaler/dispatcher and LXC bootstrap scripts

---

## 1. Configure Runner Build Variables

Create a local vars file for the runner template:

```bash
cp runners/ubuntu-2204/packer.pkrvars.hcl runners/ubuntu-2204/packer.auto.pkrvars.hcl
```

Edit `runners/ubuntu-2204/packer.auto.pkrvars.hcl` and set real values for:

- `proxmox_url`
- `proxmox_username`
- `proxmox_token`
- `proxmox_node`
- `ssh_password`
- `ssh_password_hash`

Generate the password hash with:

```bash
openssl passwd -6 'password'
```

---

## 2. Build the Runner VM Template

Run Packer from the runner directory:

```bash
packer init runners/ubuntu-2204
packer build runners/ubuntu-2204
```

Notes:

- `packer build runners/ubuntu-2204` loads all `*.pkr.hcl` files in that directory.
- `*.auto.pkrvars.hcl` in that directory is automatically loaded.

To run a single file explicitly:

```bash
packer build runners/ubuntu-2204/ubuntu-2204-runner-iso.pkr.hcl
```

---

## 3. Runner Image Contents

The image includes:

- Base build tooling (curl, git, build-essential, python3)
- `qemu-guest-agent`
- GitHub Actions runner installed at `/opt/actions-runner`
- One-shot runner script at `/opt/actions-runner/run-once.sh`

The runner is **not registered** in the image. Registration happens at boot via cloud-init.

---

## 4. Cloud-Init User-Data for Runner Registration

Use the template:

```
runners/ubuntu-2204/cloud-init/runner-user-data.pkrtpl
```

It expects these values:

- `repo_url` (e.g., `https://github.com/NREL/EnergyPlus`)
- `runner_name`
- `runner_labels`
- `registration_token`

Generate a short-lived registration token with the GitHub CLI:

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/NREL/EnergyPlus/actions/runners/registration-token \
  --jq .token
```

Default runner labels:

```
energyplus,linux,x64,ubuntu-22.04
```

---

## 5. Dispatcher (Autoscaler)

The dispatcher runs outside Proxmox (recommended: LXC) and uses the Proxmox API + GitHub API to:

1. Detect queued workflow runs
2. Mint a registration token
3. Render cloud-init user-data
4. Upload the user-data snippet to Proxmox
5. Clone the VM template and start a runner

It enforces **one runner at a time** and deletes stopped runner VMs.

Files:

```
dispatcher/dispatcher.py
dispatcher/requirements.txt
runners/ubuntu-2204/cloud-init/runner-user-data.pkrtpl
```

### Required Environment Variables

```
PROXMOX_URL
PROXMOX_NODE
PROXMOX_TOKEN_ID
PROXMOX_TOKEN_SECRET
GITHUB_TOKEN
```

### Optional Environment Variables

```
PROXMOX_STORAGE=local
PROXMOX_VERIFY_SSL=false
TEMPLATE_NAME=ubuntu-2204-runner-template
RUNNER_ID_START=200
RUNNER_ID_END=299
RUNNER_NAME_PREFIX=energyplus-runner
REPO_OWNER=NREL
REPO_NAME=EnergyPlus
REPO_URL=https://github.com/NREL/EnergyPlus
RUNNER_LABELS=energyplus,linux,x64,ubuntu-22.04
POLL_INTERVAL=15
USER_DATA_TEMPLATE=runners/ubuntu-2204/cloud-init/runner-user-data.pkrtpl
```

---

## 6. Bootstrap the Dispatcher LXC (API-only)

This method does **not** require logging into the Proxmox host. It uses the Proxmox API to create and bootstrap the LXC.

```bash
export PROXMOX_URL="http://10.1.1.158:8006/api2/json"
export PROXMOX_NODE="proxmox"
export PROXMOX_TOKEN_ID="root@pam!packer"
export PROXMOX_TOKEN_SECRET="REDACTED"
export GITHUB_TOKEN="REDACTED"

python3 dispatcher/scripts/bootstrap-dispatcher-api.py
```

Notes:

- The script will download the Debian 12 LXC template if missing.
- Override the template with `CT_TEMPLATE` if needed.
- The dispatcher runs as a systemd service inside the container.

---

## 7. Start the Dispatcher

If you used the bootstrap script, the service is already enabled. To check status:

```bash
systemctl status dispatcher
```

---

## 8. Secrets and Tokens

- Do not commit `packer.auto.pkrvars.hcl` or rendered cloud-init files.
- Rotate any tokens exposed in chat or logs.
- Prefer a dedicated Proxmox user/token for the dispatcher once stable.

---

## 9. Troubleshooting

See `PROXMOX_SETUP.md` for Proxmox-specific guidance and known gotchas (cloud-init, networking, QEMU guest agent).
