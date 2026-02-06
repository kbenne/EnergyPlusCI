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
- **Python 3**: Required to run the dispatcher.
- **GitHub CLI (`gh`)**: Used to generate runner registration tokens when doing manual testing.

---

## Repo Layout

- `runners/ubuntu-2404/` — Packer template + cloud-init templates for the Ubuntu 24.04 runner image
- `runners/ubuntu-2204/` — Packer template + cloud-init templates for the Ubuntu 22.04 runner image
- `runners/windows-2022/` — Packer template + unattended install assets for Windows Server 2022 runners
- `dispatcher/` — autoscaler/dispatcher and LXC bootstrap scripts

---

## 1. Configure Runner Build Variables

Create a local vars file for the runner template you want to build:

```bash
cp runners/ubuntu-2404/packer.pkrvars.hcl runners/ubuntu-2404/packer.auto.pkrvars.hcl
```
Or for Ubuntu 22.04:

```bash
cp runners/ubuntu-2204/packer.pkrvars.hcl runners/ubuntu-2204/packer.auto.pkrvars.hcl
```
Or for Windows Server 2022:

```bash
cp runners/windows-2022/packer.pkrvars.hcl runners/windows-2022/packer.auto.pkrvars.hcl
```

Edit the `packer.auto.pkrvars.hcl` you just created and set real values for:

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

Optional overrides:

- `iso_url` (Ubuntu 24.04 ISO URL)
- `iso_file` (existing Proxmox ISO path like `local:iso/ubuntu-24.04.1-live-server-amd64.iso`)
- `iso_checksum` (set to `none` to skip checksum validation)
- `iso_download_pve` (set to `false` to have Packer upload the ISO instead of Proxmox downloading it)

---

## 2. Build the Runner VM Template

Run Packer from the runner directory you want to build:

```bash
packer init runners/ubuntu-2404
packer build runners/ubuntu-2404
```
Or for Ubuntu 22.04:

```bash
packer init runners/ubuntu-2204
packer build runners/ubuntu-2204
```
Or for Windows Server 2022:

```bash
packer init runners/windows-2022
packer build runners/windows-2022
```

Notes:

- `packer build runners/ubuntu-2404` loads all `*.pkr.hcl` files in that directory.
- `*.auto.pkrvars.hcl` in that directory is automatically loaded.
- The Packer template attaches a Cloud‑Init drive automatically (no manual UI steps).

To run a single file explicitly:

```bash
packer build runners/ubuntu-2404/ubuntu-2404-runner-iso.pkr.hcl
```
Or for Ubuntu 22.04:

```bash
packer build runners/ubuntu-2204/ubuntu-2204-runner-iso.pkr.hcl
```
Or for Windows Server 2022:

```bash
packer build runners/windows-2022/windows-2022-runner-iso.pkr.hcl
```

Windows notes:

- Provide a Windows Server 2022 ISO on Proxmox storage and set `iso_file`.
- Provide the virtio driver ISO (Fedora virtio-win) and set `virtio_iso_file`.
- The unattended install uses `winrm_password` as the local Administrator password.

If you want to auto-detect an existing ISO in Proxmox and reuse it:

```bash
runners/ubuntu-2404/packer-build.sh
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

It deletes stopped runner VMs and can cap concurrency via pool limits.

### Runner Pools (Multiple OS Templates)

The dispatcher can schedule multiple runner pools (for example Ubuntu 22.04 + 24.04) based on job `runs-on` labels. The default config lives at:

```
dispatcher/runner-pools.json
```

Edit this file to match your Proxmox templates, labels, and VMID ranges. The default runner user-data templates are copied into `/opt/dispatcher/cloud-init/` during LXC bootstrap.
If you need an alternate path, override with `RUNNER_POOLS_CONFIG`.

Each job is matched to a pool whose `labels` are a superset of the job labels (GitHub `runs-on`).
Use `max_total_runners` in the JSON (or `MAX_TOTAL_RUNNERS`) to cap concurrency.
Ensure each pool's `template` exists in Proxmox (for example `ubuntu-2204-runner-template`).

### Proxmox Clustering (No HA)

You can run a single dispatcher against a Proxmox cluster to spread runners across nodes without enabling HA:

- Create a basic Proxmox cluster (`pvecm create` on the first node, `pvecm add` on others).
- Keep storage local per node if you do not need live migration.
- Run **one** dispatcher instance to avoid double-provisioning.
- Use per-node runner pools to target specific nodes when spreading load.
- For multi-node clusters, prefer snippet uploads (unset `SNIPPETS_DIR`) unless the snippets directory is on shared storage.

Files:

```
dispatcher/dispatcher.py
dispatcher/requirements.txt
runners/ubuntu-2404/cloud-init/runner-user-data.pkrtpl
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
MAX_TOTAL_RUNNERS=0
DISABLE_CLEANUP=false
PAUSE_ON_STOPPED=false
REPO_OWNER=NREL
REPO_NAME=EnergyPlus
REPO_URL=https://github.com/NREL/EnergyPlus
POLL_INTERVAL=15
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

Run the bootstrap script on the Proxmox host (it uses `pct` and `pveam`).

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

Create and bootstrap the LXC:

```bash
chmod +x dispatcher/scripts/bootstrap-dispatcher-lxc.sh
sudo dispatcher/scripts/bootstrap-dispatcher-lxc.sh
```

To access the dispatcher container (the CTID is the number shown next to the container in the Proxmox UI):

- From the Proxmox host, enter the container shell: `sudo pct enter <ctid>`
- Inside the container, you can set a root password with `chpasswd` (e.g. `echo root:NEWPASSWORD | chpasswd`)
- You can also set the initial root password by exporting `CT_ROOT_PASSWORD` before running the bootstrap script

To follow dispatcher logs from inside the container:

```
journalctl -u dispatcher.service -f
```

From the Proxmox host without entering the container:

```
sudo pct exec <ctid> -- journalctl -u dispatcher.service -f
```

### Debugging Runner VMs

If a runner VM exits quickly, you can keep it around by setting `DISABLE_CLEANUP=true` in the dispatcher env, then restart the dispatcher. To avoid repeated provisioning while stopped runners exist, set `PAUSE_ON_STOPPED=true` as well. From the Proxmox UI, open the runner VM console and inspect logs:

- Linux runner:
  - `/var/log/cloud-init-output.log`
  - `/opt/actions-runner/_diag/*.log`
- Windows runner:
  - `C:\actions-runner\_diag\*.log`

You can also review the Proxmox task log for the VM start/stop events in the UI (Task History).

### Runner Bootstrap Flow (Linux)

1. The dispatcher fills in the placeholders in `runners/ubuntu-2404/cloud-init/runner-user-data.pkrtpl` (or 22.04) with a short-lived GitHub registration token.
2. That cloud-init user-data calls `/opt/actions-runner/run-once.sh` (copied into the template by Packer).
3. `run-once.sh` registers the runner (ephemeral) and launches the GitHub runner `run.sh`.

Key scripts:

- `runners/ubuntu-2404/cloud-init/runner-user-data.pkrtpl` (or 22.04) — cloud-init entrypoint.
- `runners/ubuntu-2404/scripts/runner-once.sh` (or 22.04) — registration + launch wrapper.
- `/opt/actions-runner/run.sh` — GitHub Actions runner entrypoint (downloaded from GitHub as part of the runner tarball; it runs the job steps defined in the `.github/workflows/*.yml` files).

Log locations:

- Cloud-init output: `/var/log/cloud-init-output.log` (includes output from `run-once.sh` and the runner process it launches).
- Runner logs: `/opt/actions-runner/_diag/*.log` (most detailed runner diagnostics).

Notes:

- The script will download the Debian 12 LXC template if missing.
- The dispatcher runs as a systemd service inside the container; if you used the bootstrap script, it is already enabled.
- If you already have the template tarball, set `CT_TEMPLATE_FILE=/path/to/debian-12-standard_12.2-1_amd64.tar.zst` to upload it directly.
- To check status inside the LXC: `systemctl status dispatcher`
- To follow logs from the Proxmox host: `sudo pct exec <ctid> -- journalctl -u dispatcher -f`
- If you want console login access, set `CT_ROOT_PASSWORD` before running the script.
- Ensure `PROXMOX_URL` is resolvable from inside the LXC (use an IP if needed).
- Use `PROXMOX_STORAGE=local` for snippets; `local-lvm` does not support snippets.
- Snippets are written via a bind mount at `/opt/dispatcher/snippets` by default; set `SNIPPETS_DIR` only if you want a different path.
- Runner lifecycle: cloud-init powers off the VM after the job completes; the dispatcher deletes stopped runner VMs on the next poll.

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
