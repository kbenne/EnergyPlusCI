# Ephemeral GitHub Actions Runners on Proxmox

Use this repo to build an Ubuntu runner VM template and run ephemeral, one-job GitHub Actions runners for `NREL/EnergyPlus` on Proxmox.

This guide is **prescriptive**. Follow the steps in order.

> Proxmox must already be installed and working. Proxmox storage and VM setup details are in `PROXMOX_SETUP.md`.

---

## Dependencies

This repo assumes you have:

- **Proxmox VE**: The hypervisor platform that hosts the VM templates and ephemeral runner VMs.
- **Packer**: HashiCorp tool used to build the Ubuntu VM template from an ISO.
- **LXC**: Linux Containers used to run the dispatcher as a lightweight service (recommended).
- **Python 3**: Required to run the dispatcher and the API-based bootstrap script.
- **GitHub CLI (`gh`)**: Used to generate runner registration tokens when doing manual testing.

---

## Repo Layout

- `runners/ubuntu-2204/` — Packer template + cloud-init templates for the Ubuntu 22.04 runner image
- `dispatcher/` — autoscaler/dispatcher and LXC bootstrap scripts (see `dispatcher/README.md`)

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

- Base build tooling (curl, git, build-essential, python3, cmake)
- `qemu-guest-agent`
- GitHub Actions runner installed at `/opt/actions-runner`
- One-shot runner script at `/opt/actions-runner/run-once.sh`

The runner is **not registered** in the image. Registration happens at boot via cloud-init.

---

---

## 5. Dispatcher (Autoscaler)

The dispatcher runs in an LXC container and uses the Proxmox API + GitHub API to:

1. Detect queued workflow runs on GitHub (via the GitHub API)
2. Mint a registration token (short-lived GitHub secret used once to register a runner)
3. Render cloud-init user-data (cloud-init injects per-boot config like hostname and scripts)
4. Upload the user-data snippet to Proxmox
5. Clone the VM template and start a runner

It currently enforces **one runner at a time** and deletes stopped runner VMs.

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

### GitHub Token (Fine-Grained, Recommended)

Create a fine-grained personal access token for the dispatcher:

1. GitHub → **Settings** → **Developer settings** → **Personal access tokens** → **Fine-grained tokens**
2. Resource owner: **NREL**
3. Repository access: **Only select repositories** → `EnergyPlus`
4. Permissions:
   - **Actions**: Read and write
   - **Administration**: Read and write
5. If the org enforces SSO, authorize the token for the org

Set this token as `GITHUB_TOKEN` for the dispatcher.

The dispatcher uses this token only to request **short-lived runner registration tokens**, which are injected via cloud-init at boot. The runner uses the short-lived token to register and then the token becomes invalid after use.

---

## 6. Bootstrap the Dispatcher LXC

This method does **not** require logging into the Proxmox host. It uses the Proxmox API to create and bootstrap the LXC.

To avoid re-exporting variables every time, create a local env file and source it:

```bash
cp dispatcher/dispatcher.env.example dispatcher/dispatcher.env
```

Then add your secrets/overrides in `dispatcher/dispatcher.env`, and source it:

```bash
source dispatcher/dispatcher.env
```

If you prefer not to use an env file, you can still export manually:

```bash
export PROXMOX_URL="http://10.1.1.158:8006/api2/json"
export PROXMOX_NODE="proxmox"
export PROXMOX_TOKEN_ID="root@pam!packer"
export PROXMOX_TOKEN_SECRET="REDACTED"
export GITHUB_TOKEN="REDACTED"
```

Create and and boostrap the LXC

```bash
python3 dispatcher/scripts/bootstrap-dispatcher-api.py
```

Notes:

- The script will download the Debian 12 LXC template if missing.
- If the Proxmox API does not support direct template download, the script will download locally and upload it.
- The dispatcher runs as a systemd service inside the container; if you used the bootstrap script, it is already enabled.
- Override the download URL with `CT_TEMPLATE_URL` if you mirror templates locally.
- To check status inside the LXC: `systemctl status dispatcher`

---
## 7. Secrets and Tokens

- Do not commit `packer.auto.pkrvars.hcl` or rendered cloud-init files.
- Rotate any tokens exposed in chat or logs.
- Prefer a dedicated Proxmox user/token for the dispatcher once stable.

### Token Model (Three Tokens)

There are three distinct tokens involved:

1. **Dispatcher token (long-lived)**  
   - **Scope:** GitHub API access to `NREL/EnergyPlus` only  
   - **Created by:** Fine-grained PAT (see “GitHub Token” in the Dispatcher section)  
   - **Used for:** Creating short-lived runner registration tokens  

2. **Runner registration token (short-lived)**  
   - **Scope:** Only registers a runner to the repo/org  
   - **Created by:** GitHub API call from the dispatcher  
   - **Used for:** One-time runner registration during boot  

3. **Job token (`GITHUB_TOKEN`, per job)**  
   - **Scope:** Determined by workflow `permissions:` and repo/org defaults  
   - **Created by:** GitHub Actions for each job  
   - **Used for:** GitHub operations during the job (checkout, API calls, releases)  

### Lock Down Job Token Permissions

To prevent runners from writing to the repo, set read-only permissions in workflows:

```yaml
permissions:
  contents: read
```

Also set the repo default to read-only:

- Settings → Actions → General → **Workflow permissions** → **Read repository contents permission**

---

## 9. Troubleshooting

See `PROXMOX_SETUP.md` for Proxmox-specific guidance and known gotchas (cloud-init, networking, QEMU guest agent).
