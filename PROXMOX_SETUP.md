# Proxmox Setup Notes

This file contains Proxmox-specific setup guidance and explanations. It assumes Proxmox VE is already installed and working.

---

## Storage Concepts in Proxmox

Proxmox typically provides two default storage backends:

- `local`
  - Directory-backed storage (usually `/var/lib/vz`)
  - Used for:
    - ISO images
    - Cloud-init snippets
    - Backups

- `local-lvm`
  - LVM-thin pool
  - Used for:
    - VM disks
    - Supports copy-on-write (CoW) linked clones

Rule of thumb:

- ISOs → `local`
- VM disks → `local-lvm`

---

## Uploading an Ubuntu ISO to Proxmox

### Option A: Upload via Proxmox Web UI

1. In the Proxmox web interface, select the **node**
2. Click **local** → **ISO Images**
3. Click **Upload**
4. Upload an Ubuntu Server ISO (e.g., Ubuntu 24.04 LTS)

### Option B: Upload via `scp`

```bash
scp ubuntu-24.04.1-live-server-amd64.iso \
    root@<proxmox-ip>:/var/lib/vz/template/iso/
```

Or download directly on the Proxmox host:

```bash
ssh root@<proxmox-ip>
cd /var/lib/vz/template/iso
wget https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso
```

---

## Creating the Base Ubuntu VM (Manual Build)

Use the Proxmox web UI to create a baseline VM before automating with Packer.

Recommended settings:

- Name: `ubuntu-24.04-runner-base`
- ISO image: Ubuntu Server 24.04 LTS (from `local`)
- Machine: `q35`
- BIOS: `OVMF (UEFI)`
- EFI disk: enabled
- Disk: 40–80 GB, VirtIO SCSI, storage `local-lvm`
- CPU: type `host`, 2–4 cores
- Memory: 4–8 GB
- Network: VirtIO, bridge `vmbr0`

---

## Base Package Installation Inside the VM

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

### QEMU Guest Agent

The guest agent is required for Proxmox to report IPs and guest status.

Enable in Proxmox (VM powered off):

- VM → **Options** → **QEMU Guest Agent** → **Enabled**

Inside the guest, the device should appear as:

```bash
/dev/virtio-ports/org.qemu.guest_agent.0
```

Start the service:

```bash
sudo systemctl start qemu-guest-agent.service
```

---

## Enabling Cloud-Init Support in Proxmox

Cloud-init lets each clone receive unique configuration.

1. Shut down the VM
2. Hardware → **Add → CloudInit Drive**
3. Use default storage (`local` is fine)
4. Set boot order so CloudInit comes before the main disk

---

## Cloud-Init Drive vs Main VM Storage

- Main VM disk (`scsi0`) lives on `local-lvm` and contains the OS.
- CloudInit drive (`ide2` or `scsi1`) lives on `local` and contains only config.

For `local` storage, ensure **Disk image** and **Snippets** content types are enabled.

Example VM device list:

```
scsi0   local-lvm:vm-XXX-disk-0   (main OS disk)
ide2    local:cloudinit           (cloud-init config disk)
net0    virtio
```

---

## Preparing the VM for Templating

Run inside the guest **before** converting to a template:

```bash
sudo cloud-init clean --logs
sudo truncate -s 0 /etc/machine-id
sudo shutdown now
```

Then convert to a template (VM powered off):

```bash
qm template <vmid>
```

---

## Sanity Check: Clone and Destroy Test

```bash
qm clone <template-vmid> 2001 --full 0
qm start 2001
```

Verify boot, cloud-init, and networking. Then clean up:

```bash
qm stop 2001
qm destroy 2001
```

---

## Known Gotchas

### Cloned VM boots but has no IP address

Use a netplan config that matches all interfaces:

```yaml
network:
  version: 2
  ethernets:
    default:
      match:
        name: "en*"
      dhcp4: true
```

### Proxmox can’t show VM IP address

- Ensure QEMU guest agent is enabled in Proxmox
- Confirm `/dev/virtio-ports/org.qemu.guest_agent.0` exists in the guest
- Start the agent: `sudo systemctl start qemu-guest-agent.service`
