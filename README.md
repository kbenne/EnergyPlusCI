# Proxmox VM Setup for Ephemeral CI Runners

This document captures the steps **so far** for setting up a base virtual machine (VM) in Proxmox VE that will later be used as a **template** for disposable, one-job-per-VM CI runners (e.g., GitHub Actions self-hosted runners).

> ⚠️ This document assumes Proxmox VE is already installed and working. Proxmox installation itself is documented elsewhere.

---

## Repo Layout

- `runners/ubuntu-2204/` — Packer template + cloud-init templates for the Ubuntu 22.04 runner image
- `dispatcher/` — autoscaler/dispatcher and LXC bootstrap scripts

---

## 1. Storage Concepts in Proxmox (Important Context)

Proxmox typically provides two default storage backends:

- \`\`

  - Directory-backed storage (usually `/var/lib/vz`)
  - Used for:
    - ISO images
    - Cloud-init snippets
    - Backups

- \`\`

  - LVM-thin pool
  - Used for:
    - VM disks
    - Supports copy-on-write (CoW) linked clones

**Rule of thumb:**

- ISOs → `local`
- VM disks → `local-lvm`

This setup is sufficient for prototyping and supports fast VM cloning.

---

## 2. Uploading an Ubuntu ISO to Proxmox

### Option A: Upload via Proxmox Web UI

1. In the Proxmox web interface, select the **node**
2. Click **local** → **ISO Images**
3. Click **Upload**
4. Upload an Ubuntu Server ISO (e.g., Ubuntu 22.04 LTS)

### Option B: Upload via `scp`

From your local machine:

```bash
scp ubuntu-22.04.4-live-server-amd64.iso \
    root@<proxmox-ip>:/var/lib/vz/template/iso/
```

Or download directly on the Proxmox host:

```bash
ssh root@<proxmox-ip>
cd /var/lib/vz/template/iso
wget https://releases.ubuntu.com/22.04/ubuntu-22.04.4-live-server-amd64.iso
```

After upload, the ISO should appear under **local → ISO Images** in the UI.

---

## 3. Creating the Base Ubuntu VM (Manual Build)

The **first VM should be built manually using the Proxmox web UI**. This establishes a known-good baseline before introducing automation tools like Packer.

### Recommended VM Settings

**General**

- Name: `ubuntu-22.04-runner-base`

**OS**

- ISO image: Ubuntu Server 22.04 LTS (from `local`)

**System**

- Machine: `q35`
- BIOS: `OVMF (UEFI)`
- EFI disk: enabled

**Disks**

- Bus: VirtIO SCSI
- Disk size: 40–80 GB
- Storage: `local-lvm`

**CPU**

- Type: `host`
- Cores: 2–4

**Memory**

- 4–8 GB

**Network**

- Model: VirtIO
- Bridge: CI / non-internal bridge or VLAN

Complete the wizard, start the VM, and install Ubuntu normally via the console.

---

## 4. Base Package Installation Inside the VM

After Ubuntu installation and first boot, install the required base packages **inside the VM**:

```bash
sudo apt update && sudo apt upgrade -y
sudo apt install -y \
  curl \
  ca-certificates \
  git \
  build-essential \
  python3 \
  cloud-init \
  qemu-guest-agent
```

### QEMU Guest Agent (Important)

The QEMU guest agent is required for Proxmox to:

- display the VM’s IP address in the UI
- query basic guest status information

#### Proxmox-side requirement

In the Proxmox UI **while the VM is powered off**:

- VM → **Options** → **QEMU Guest Agent** → **Enabled**

This exposes the required virtio-serial device to the guest.

#### Guest-side behavior (Ubuntu 22.04+)

- `qemu-guest-agent.service` is often **static** (not enabled via `systemctl enable`)
- The service will **not start** unless the virtio device exists
- If the Proxmox option is enabled correctly, the device will appear as:

```bash
/dev/virtio-ports/org.qemu.guest_agent.0
```

Once the device exists, start the agent manually:

```bash
sudo systemctl start qemu-guest-agent.service
```

If the device is missing, the service will fail with a dependency timeout. This is almost always a Proxmox-side configuration issue.

---

## 5. Enabling Cloud-Init Support in Proxmox

Cloud-init is required so each cloned VM can receive unique configuration (hostname, runner registration, etc.).

Steps:

1. Shut down the VM
2. In **Hardware**, click **Add → CloudInit Drive**
3. Use default storage (`local` is fine)
4. Adjust **Boot Order** so the CloudInit drive is before the main disk

No cloud-init user data is added yet.

---

## 6. Where Actions Happen: Inside the VM vs Proxmox Host

Some steps happen **inside the guest OS (Ubuntu/Windows VM)**, and others happen **in Proxmox**.

### Inside the VM (guest OS)

These are OS hygiene/configuration steps performed from an SSH session or the Proxmox console **inside Ubuntu**:

- Installing packages
- Enabling and verifying `qemu-guest-agent`
- Cleaning cloud-init instance state and machine identity prior to templating

### In Proxmox (host/UI)

These are infrastructure lifecycle steps performed in the Proxmox UI or on the Proxmox host:

- Adding a CloudInit drive device
- Converting a VM to a template
- Cloning, starting, stopping, and destroying VMs

> Key point: the **clean steps are run inside the VM**, not on the Proxmox host.

---

## 7. Cloud-Init Drive vs Main VM Storage (Important Clarification)

In Proxmox, the **CloudInit Drive is NOT the VM’s main storage**. It is a small, separate, read-only disk whose sole purpose is to pass configuration data to the VM at boot.

### Main VM Disk (OS + Filesystem)

- Typically shown as `scsi0` in Proxmox
- Stored on \`\` (LVM-thin)
- Contains:
  - Ubuntu OS installation
  - `/`, `/home`, `/var`, build directories, etc.
- This is the disk that gets cloned (copy-on-write) for each job VM

### CloudInit Drive (Configuration Only)

- Typically shown as `ide2` or `scsi1`
- Stored on \`\` (directory-backed storage)
- Very small (MB-scale)
- Contains only:
  - cloud-init user-data
  - cloud-init meta-data
  - network configuration
- Read by cloud-init **once at boot**
- Not used for persistent storage and not writable by the VM

### Required Storage Content Settings for `local`

For `local` storage to be selectable when adding a CloudInit drive, it must allow **both**:

- ✅ **Disk image** – required to store the small CloudInit virtual disk
- ✅ **Snippets** – required to store cloud-init user-data / meta-data

In your current setup, \*\*all content types are enabled except \*\*\`\`, which is correct. The `Container` content type is only used for LXC containers and is **not needed** for VM-based CI runners.

There is **no separate "CloudInit" content checkbox** in many Proxmox versions; CloudInit relies on the combination of **Disk image + Snippets**.

### Why This Separation Exists (and Why It’s Good)

- Keeps the OS disk clean and reusable as a template
- Allows per-job customization (hostname, runner registration, scripts) without modifying the template
- Prevents state from leaking between jobs
- Makes "one VM per job" cheap and deterministic

In the Proxmox UI, a correctly configured VM will typically show:

```
scsi0   local-lvm:vm-XXX-disk-0   (main OS disk)
ide2    local:cloudinit           (cloud-init config disk)
net0    virtio
```

This is expected and correct.

---

## 7. Preparing the VM for Templating and Creating a Template

These steps are run **inside the Ubuntu VM** (guest OS) just before converting it to a template, followed by the Proxmox-side conversion.

### Correct sequencing

1. Boot the VM (it must be running so you can execute the commands)
2. Run the clean steps
3. Shut the VM down
4. Convert to template **while it is powered off**

### Clean steps (inside the VM)

```bash
sudo cloud-init clean --logs
sudo truncate -s 0 /etc/machine-id
sudo shutdown now
```

> After running these, **do not boot the VM again**. Convert it to a template while it is shut down.

### Convert to Template (Proxmox)

In Proxmox:

- Right-click the VM → **Convert to Template**

Or via CLI:

```bash
qm template <vmid>
```

At this point, you have a **golden base template** suitable for fast cloning.

---





---

## 8. Sanity Check: Clone and Destroy Test

Before adding CI logic, validate VM lifecycle mechanics.

```bash
qm clone <template-vmid> 2001 --full 0
qm start 2001
```

Verify:

- VM boots successfully
- cloud-init runs without errors
- VM gets a unique hostname/IP

Then clean up:

```bash
qm stop 2001
qm destroy 2001
```

---

## 9. Introducing Packer (Image-as-Code)

Once you have successfully created and used a manual template, the next step is to **encode the template build process in Packer**. This allows you to reliably recreate the same VM template in the future and track changes over time.

### Installing Packer (Ubuntu 24.04, Curl-Based)

Pinned to the latest stable version at time of writing: **1.14.3**.

```bash
sudo apt-get update
sudo apt-get install -y unzip

VERSION=1.14.3
curl -fsSLO https://releases.hashicorp.com/packer/${VERSION}/packer_${VERSION}_linux_amd64.zip
unzip packer_${VERSION}_linux_amd64.zip
sudo install -m 0755 packer /usr/local/bin/packer

packer version
```

To upgrade later, update `VERSION` and repeat the steps.

At this stage, the recommended approach is to use **Packer’s ********\`\`******** builder**, which installs Ubuntu from a vanilla ISO and then applies provisioning steps before producing a new template.

This automates the OS installation and removes the need for a pre-existing Proxmox template.

---

### Minimal Packer File (ISO-Based)

The following example demonstrates a **minimal Packer configuration** that matches the current Ubuntu 22.04 CI VM setup.

It:

- boots from an Ubuntu Server ISO with autoinstall
- installs baseline packages
- performs the same clean steps used before templating
- outputs a new Proxmox template

```hcl
// ubuntu-2204-runner-iso.pkr.hcl
packer {
  required_plugins {
    proxmox = {
      version = ">= 1.2.3"
      source  = "github.com/hashicorp/proxmox"
    }
  }
}

variable "proxmox_url" {
  type        = string
  description = "Example: https://pve.your.lan:8006/api2/json"
}

variable "proxmox_username" {
  type        = string
  description = "Example: root@pam!tokenid (API token user)"
}

variable "proxmox_token" {
  type        = string
  sensitive   = true
}

variable "proxmox_node" {
  type        = string
}

variable "new_template_name" {
  type        = string
  default     = "ubuntu-2204-runner-template"
}

variable "ssh_username" {
  type    = string
  default = "ci"
}

variable "ssh_password" {
  type      = string
  sensitive = true
}

variable "ssh_password_hash" {
  type        = string
  sensitive   = true
  description = "SHA-512 password hash for autoinstall (openssl passwd -6 'password')"
}

source "proxmox-iso" "ubuntu2204" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_name          = var.new_template_name
  tags             = "ubuntu-2204_ci_template"
  boot_iso {
    type             = "scsi"
    iso_url          = "https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-live-server-amd64.iso"
    iso_checksum     = "sha256:9bc6028870aef3f74f4e16b900008179e78b130e6b0b9a140635434a46aa98b0"
    iso_storage_pool = "local"
    iso_download_pve = true
    unmount          = true
  }
  unmount_iso      = true

  cores   = 2
  sockets = 1
  memory  = 8192

  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = "40G"
    storage_pool = "local-lvm"
    type         = "scsi"
  }

  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  http_content = {
    "/user-data" = templatefile("${path.root}/http/user-data.pkrtpl", {
      ssh_username      = var.ssh_username
      ssh_password_hash = var.ssh_password_hash
    })
    "/meta-data" = templatefile("${path.root}/http/meta-data.pkrtpl", {})
  }

  boot_wait = "5s"
  boot_command = [
    "<esc><wait>",
    "linux /casper/vmlinuz quiet autoinstall ds=nocloud-net;s=http://{{ .HTTPIP }}:{{ .HTTPPort }}/ ---",
    "<enter><wait>",
    "initrd /casper/initrd",
    "<enter><wait>",
    "boot",
    "<enter>"
  ]

  communicator = "ssh"
  ssh_username = var.ssh_username
  ssh_password = var.ssh_password
  ssh_timeout  = "30m"
}

build {
  name    = "ubuntu-2204-runner-template-from-iso"
  sources = ["source.proxmox-iso.ubuntu2204"]

  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      "sudo apt-get update",
      "sudo apt-get install -y cloud-init qemu-guest-agent curl ca-certificates git build-essential python3",
    ]
  }

  provisioner "shell" {
    inline = [
      "set -euxo pipefail",
      "sudo cloud-init clean --logs || true",
      "sudo truncate -s 0 /etc/machine-id",
    ]
  }
}
```

Note: `boot_iso.iso_download_pve = true` tells Proxmox to download the ISO directly on the node. If your Proxmox host has no outbound internet, set it to `false` and let Packer upload instead.

---

### How This Fits the Workflow

1. Upload the Ubuntu ISO to Proxmox storage
2. Packer installs Ubuntu from ISO and applies provisioning
3. Packer outputs a **new, reproducible template**
4. Old templates can be deleted or archived

This approach avoids pre-existing templates and keeps the whole build reproducible.

---

### Supplying Variable Values at Build Time

The variables defined in the Packer template (for example `proxmox_url`, `proxmox_username`, `ssh_password`, etc.) **do not have values hard-coded in the template**. Instead, their values are provided \*\*when you run \*\*\`\`.

This separation keeps the template reusable and avoids committing secrets to version control.

#### Recommended: Example Vars File + Local Secrets

This repo includes `runners/ubuntu-2204/packer.pkrvars.hcl` as a safe, tracked example. To use it locally, copy it and add secrets:

```bash
cp runners/ubuntu-2204/packer.pkrvars.hcl runners/ubuntu-2204/packer.auto.pkrvars.hcl
```

Then edit `runners/ubuntu-2204/packer.auto.pkrvars.hcl` to add your real secrets.

```hcl
proxmox_url       = "https://proxmox.lan:8006/api2/json"
proxmox_username  = "root@pam!packer"
proxmox_node      = "proxmox"
new_template_name = "ubuntu-22.04-runner-template-v1"
ssh_username      = "ci"

# Secrets are often placed here for local development,
# but should not be committed to source control.
proxmox_token      = "REDACTED"
ssh_password       = "REDACTED"
ssh_password_hash  = "REDACTED"
```

Packer automatically loads any file matching `*.auto.pkrvars.hcl`, so you can simply run:

```bash
packer init .
packer build runners/ubuntu-2204
```

Generate `ssh_password_hash` with:

```bash
openssl passwd -6 'password'
```

#### How Packer Picks Up This Template

Running `packer build .` loads **all** `*.pkr.hcl` files in the current directory, which is why `runners/ubuntu-2204/ubuntu-2204-runner-iso.pkr.hcl` is used when you run Packer from that folder. Packer also loads any `*.auto.pkrvars.hcl` file for variable values (e.g., `runners/ubuntu-2204/packer.auto.pkrvars.hcl`).

If you want to run a single template file explicitly:

```bash
packer build runners/ubuntu-2204/ubuntu-2204-runner-iso.pkr.hcl
```

---

## 13. Ephemeral GitHub Actions Runner (Next Step)

This repo now installs the GitHub Actions runner binary into the VM image, but **does not register it**. Registration is intended to happen at boot via cloud-init so each clone registers, runs a single job, and exits.

### Image Contents

During the Packer build, the runner is installed to:

```
/opt/actions-runner
```

and a helper script is placed at:

```
/opt/actions-runner/run-once.sh
```

This script expects:

```
run-once.sh <repo_or_org_url> <registration_token> [labels] [runner_name]
```

It registers, runs exactly one job (`--once`), and removes itself.

### Cloud-Init User-Data (Per-Clone)

Use the template `runners/ubuntu-2204/cloud-init/runner-user-data.pkrtpl` to register the runner at boot. Example values:

```yaml
repo_url: https://github.com/NREL/EnergyPlus
runner_name: energyplus-runner-001
runner_labels: energyplus,linux,x64,ubuntu-22.04
registration_token: <REDACTED>
```

`*.pkrtpl` files are Packer-compatible templates (used by `templatefile(...)`) with `${var}` placeholders. In this repo the same template is also rendered by the dispatcher via Python's `string.Template`.

Render the template with your values and provide it to Proxmox as user-data (CloudInit drive + snippet). The token is short-lived and should be generated just before boot.

### Token Generation (Manual)

Generate a short-lived registration token for the repo:

```bash
gh api \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  /repos/NREL/EnergyPlus/actions/runners/registration-token \
  --jq .token
```

### Labels

Default labels used by the helper script:

```
energyplus,linux,x64,ubuntu-22.04
```

Override these via cloud-init if needed.

---

## 14. Dispatcher (Ephemeral Runner Autoscaler)

The dispatcher runs outside Proxmox (recommended: LXC container) and uses the Proxmox API + GitHub API to:

1. Detect queued workflow runs in `NREL/EnergyPlus`
2. Mint a short-lived registration token
3. Render cloud-init user-data
4. Upload the user-data snippet to Proxmox
5. Clone the VM template and start a runner

It enforces a **single runner at a time** and deletes stopped runner VMs on each loop.

### Files

```
dispatcher/dispatcher.py
dispatcher/requirements.txt
runners/ubuntu-2204/cloud-init/runner-user-data.pkrtpl
```

### Environment Variables

Required:

```
PROXMOX_URL
PROXMOX_NODE
PROXMOX_TOKEN_ID
PROXMOX_TOKEN_SECRET
GITHUB_TOKEN
```

Optional:

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

### Run (LXC Example)

Inside the LXC:

```bash
python3 -m venv dispatcher/.venv
dispatcher/.venv/bin/pip install -r dispatcher/requirements.txt

export PROXMOX_URL="http://10.1.1.158:8006/api2/json"
export PROXMOX_NODE="proxmox"
export PROXMOX_TOKEN_ID="root@pam!packer"
export PROXMOX_TOKEN_SECRET="REDACTED"
export GITHUB_TOKEN="REDACTED"

python3 dispatcher/dispatcher.py
```

### Notes

- The dispatcher uses the Proxmox API to upload a cloud-init snippet and does **not** need host filesystem access.
- A dedicated Proxmox user/token is recommended instead of root.
- The GitHub token must have permission to create runner registration tokens for the repo.

### Proxmox LXC Bootstrap (Scripted)

Run this **on the Proxmox host** to create and configure a small LXC container that runs the dispatcher as a systemd service:

```bash
export PROXMOX_URL="http://10.1.1.158:8006/api2/json"
export PROXMOX_NODE="proxmox"
export PROXMOX_TOKEN_ID="root@pam!packer"
export PROXMOX_TOKEN_SECRET="REDACTED"
export GITHUB_TOKEN="REDACTED"

./dispatcher/scripts/bootstrap-dispatcher-lxc.sh
```

Any optional dispatcher environment variables you export before running the script (for example `PROXMOX_STORAGE`, `TEMPLATE_NAME`, `RUNNER_LABELS`, `POLL_INTERVAL`) will be written into `/etc/default/dispatcher` inside the LXC.

Optional overrides (examples):

```bash
export CT_ID=300
export CT_HOSTNAME=dispatcher-1
export CT_STORAGE=local-lvm
export CT_BRIDGE=vmbr0
export CT_CORES=1
export CT_MEMORY=512
export CT_DISK=4
export CT_TEMPLATE=debian-12-standard_12.2-1_amd64.tar.zst
```

The script will download a Debian 12 LXC template if needed, create the container, install Python, copy the dispatcher code, and enable the service.

### Proxmox LXC Bootstrap (API-Only)

If you want to bootstrap the dispatcher **without logging into the Proxmox host**, use:

```bash
export PROXMOX_URL="http://10.1.1.158:8006/api2/json"
export PROXMOX_NODE="proxmox"
export PROXMOX_TOKEN_ID="root@pam!packer"
export PROXMOX_TOKEN_SECRET="REDACTED"
export GITHUB_TOKEN="REDACTED"

python3 dispatcher/scripts/bootstrap-dispatcher-api.py
```

Notes:

- If the LXC template is missing, the script will request a download via the Proxmox API.
- The script uses the Proxmox `lxc/exec` API to install packages and write files.
- Override the LXC template with `CT_TEMPLATE` if needed.

#### Creating a Proxmox API Token

You can create an API token for your Proxmox user either in the UI or via CLI.

UI path:

- Datacenter → Permissions → Users
- Select your user (e.g., `root@pam`)
- API Tokens → Add
- Token ID (e.g., `packer`)
- Copy the token value (only shown once)

CLI example:

```bash
pveum user token add root@pam packer --privsep 0
```

If you keep privilege separation enabled, assign explicit roles/permissions for the token under Datacenter → Permissions.

#### Alternatives for Secrets (No Local Auto Vars File)

For improved security (especially in CI):

- Pass variables on the command line:

  ```bash
  packer build -var "ssh_password=..." runners/ubuntu-2204
  ```

- Or use environment variables:

  ```bash
  export PKR_VAR_proxmox_token="..."
  export PKR_VAR_ssh_password="..."
  packer build runners/ubuntu-2204
  ```

Packer resolves variable values in this priority order:

1. Command-line `-var` flags
2. `PKR_VAR_` environment variables
3. `*.auto.pkrvars.hcl`
4. Defaults defined in the template

---

### Important Notes

- For `proxmox-iso`, specify disk size and storage pool explicitly so the template is consistent
- Templates produced by Packer should be treated as immutable
- Clones should always be cleaned before being converted into templates

---

## 10. Known Gotchas Encountered During Prototyping

### 10.1 Cloned VM boots but has no IP address

Symptom:

- Proxmox shows the NIC (MAC address) but no IP
- Inside the VM: interface exists but is **DOWN** and has no `inet` address

Cause:

- After templating + `cloud-init clean`, the clone may boot without a usable netplan DHCP configuration, leaving the interface down and never attempting DHCP.

Quick fix on a clone (Ubuntu guest):

```bash
sudo tee /etc/netplan/01-dhcp.yaml <<'EOF'
network:
  version: 2
  ethernets:
    enp6s18:
      dhcp4: true
EOF

sudo netplan apply
```

Plan:

- Encode a robust DHCP netplan config in the **Packer build** (preferred), so all clones reliably come up with networking.
- For robustness across interface renames, use `match` in netplan (example to adopt in Packer):

```yaml
network:
  version: 2
  ethernets:
    default:
      match:
        name: "en*"
      dhcp4: true
```

---

### 10.2 Proxmox can’t show VM IP address

Symptom:

- Proxmox Summary shows "No network information"

Cause:

- The QEMU guest agent is not running, or the guest-agent virtio device was not attached.

Fix:

- Enable **QEMU Guest Agent** in Proxmox **while the VM is powered off**
- Ensure `/dev/virtio-ports/org.qemu.guest_agent.0` exists in the guest
- Start the agent: `sudo systemctl start qemu-guest-agent.service`

---

## 11. Triggering GitHub Actions from the Command Line (Control Plane Reminder)

GitHub Actions workflows are orchestrated by GitHub, not by the runner VM itself. A self-hosted runner polls GitHub for jobs; you generally cannot "push" a workflow to run by SSH’ing into a runner.

To trigger a workflow from a local machine, use a workflow that includes `workflow_dispatch` and then invoke it via the GitHub CLI:

```bash
gh workflow run <workflow-name-or-file> --ref <branch>
```

This triggers GitHub to schedule the job onto any matching runner labels.

---

## 12. Repo Organization Recommendation

Recommended split:

- **EnergyPlus repo**: workflows (`.github/workflows`) and any scripts that define how to build/test EnergyPlus
- **Separate infra repo**: Proxmox + Packer templates, VM provisioning, cloud-init snippets, runner bootstrap/dispatcher logic, and this README

---

**Status:** Manual template workflow validated. Packer introduced for reproducible template builds.
