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

variable "runner_version" {
  type        = string
  description = "GitHub Actions runner version"
  default     = "2.316.0"
}

variable "runner_arch" {
  type        = string
  description = "GitHub Actions runner architecture"
  default     = "x64"
}

variable "http_bind_address" {
  type        = string
  description = "IP on the Packer host to bind the autoinstall HTTP server to"
  default     = "0.0.0.0"
}
#
#variable "http_seed_ip" {
#  type        = string
#  description = "IP on the Packer host that the VM can reach for autoinstall seed"
#}

source "proxmox-iso" "ubuntu2204" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_name    = var.new_template_name
  tags       = "ubuntu-2204_ci_template"
  qemu_agent = true
  cloud_init = true
  cloud_init_storage_pool = "local"
  boot_iso {
    type             = "scsi"
    iso_url          = "https://releases.ubuntu.com/22.04.5/ubuntu-22.04.5-live-server-amd64.iso"
    iso_checksum     = "sha256:9bc6028870aef3f74f4e16b900008179e78b130e6b0b9a140635434a46aa98b0"
    iso_storage_pool = "local"
    iso_download_pve = true
    unmount          = true
  }

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
    "/user-data" = templatefile("${abspath(path.root)}/http/user-data.pkrtpl", {
      ssh_username      = var.ssh_username
      ssh_password_hash = var.ssh_password_hash
    })
    "/meta-data" = templatefile("${abspath(path.root)}/http/meta-data.pkrtpl", {})
  }
  http_bind_address = var.http_bind_address

  boot_wait         = "15s"
  boot_key_interval = "100ms"
  boot_command = [
    "<esc><wait>",
    "c<wait>",
    "linux /casper/vmlinuz quiet ip=dhcp autoinstall ds=nocloud-net\\;s=http://{{ .HTTPIP}}:{{ .HTTPPort }}/ ---",
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

  provisioner "file" {
    source      = "${abspath(path.root)}/scripts/runner-once.sh"
    destination = "/tmp/runner-once.sh"
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "sudo apt-get update",
      "sudo apt-get install -y cloud-init qemu-guest-agent curl ca-certificates git build-essential python3",
      "sudo snap install --classic cmake --channel=4.0",
      "sudo mkdir -p /opt/actions-runner",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/actions-runner",
      "cd /opt/actions-runner",
      "curl -fsSLO https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-${var.runner_arch}-${var.runner_version}.tar.gz",
      "tar -xzf actions-runner-linux-${var.runner_arch}-${var.runner_version}.tar.gz",
      "rm -f actions-runner-linux-${var.runner_arch}-${var.runner_version}.tar.gz",
      "sudo /opt/actions-runner/bin/installdependencies.sh",
      "sudo install -m 0755 /tmp/runner-once.sh /opt/actions-runner/run-once.sh"
    ]
  }

  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",
      "sudo rm -f /etc/cloud/cloud-init.disabled",
      "sudo cloud-init clean --logs || true",
      "sudo truncate -s 0 /etc/machine-id",
    ]
  }
}
