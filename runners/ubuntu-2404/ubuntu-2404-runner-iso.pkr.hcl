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
  type      = string
  sensitive = true
}

variable "proxmox_node" {
  type = string
}

variable "new_template_name" {
  type        = string
  default     = "ubuntu-2404-runner-template"
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
  default     = "2.327.0"
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

variable "cloud_init_storage_pool" {
  type        = string
  description = "Proxmox storage pool for the cloud-init drive"
  default     = "local-lvm"
}

variable "iso_url" {
  type        = string
  description = "Ubuntu 24.04 live server ISO URL"
  default     = "https://releases.ubuntu.com/24.04.1/ubuntu-24.04.1-live-server-amd64.iso"
}

variable "iso_file" {
  type        = string
  description = "Existing Proxmox ISO path (example: local:iso/ubuntu-24.04.1-live-server-amd64.iso). When set, iso_url is ignored."
  default     = ""
}

variable "iso_checksum" {
  type        = string
  description = "ISO checksum (set to 'none' to disable)"
  default     = "none"
}

variable "iso_download_pve" {
  type        = bool
  description = "When true, Proxmox downloads the ISO directly; when false, Packer uploads it."
  default     = true
}

#
#variable "http_seed_ip" {
#  type        = string
#  description = "IP on the Packer host that the VM can reach for autoinstall seed"
#}

source "proxmox-iso" "ubuntu2404" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_name    = var.new_template_name
  tags       = "ubuntu-2404_ci_template"
  qemu_agent = true
  cloud_init = true
  cloud_init_storage_pool = var.cloud_init_storage_pool
  boot_iso {
    type             = "scsi"
    iso_url          = var.iso_file != "" ? null : var.iso_url
    iso_file         = var.iso_file != "" ? var.iso_file : null
    iso_checksum     = var.iso_checksum
    iso_storage_pool = "local"
    iso_download_pve = var.iso_download_pve
    unmount          = true
  }
  task_timeout = "45m"

  cores   = 4
  sockets = 1
  memory  = 4096

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
  name    = "ubuntu-2404-runner-template-from-iso"
  sources = ["source.proxmox-iso.ubuntu2404"]

  provisioner "file" {
    source      = "${abspath(path.root)}/scripts/runner-once.sh"
    destination = "/tmp/runner-once.sh"
  }

  # Shell provisioner #1: base tooling + GCC/G++/gfortran + netplan + cmake + actions-runner
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",

      "sudo apt-get update",
      # ADD patchelf here
      "sudo apt-get install -y cloud-init qemu-guest-agent curl ca-certificates git build-essential python3 software-properties-common patchelf",

      "sudo add-apt-repository -y ppa:ubuntu-toolchain-r/test",
      "sudo apt-get update",

      # GCC toolchain (adds Fortran compiler too)
      "sudo apt-get install -y gcc-13 g++-13 gfortran-13",
      "sudo update-alternatives --install /usr/bin/gcc gcc /usr/bin/gcc-13 100",
      "sudo update-alternatives --install /usr/bin/g++ g++ /usr/bin/g++-13 100",
      "sudo update-alternatives --install /usr/bin/gfortran gfortran /usr/bin/gfortran-13 100",

      # Tell CMake/Autotools where to find Fortran compiler
      "echo 'export FC=/usr/bin/gfortran' | sudo tee /etc/profile.d/fortran.sh >/dev/null",
      "sudo chmod 0644 /etc/profile.d/fortran.sh",

      # Netplan DHCP config for Proxmox NICs
      "sudo tee /etc/netplan/01-proxmox-dhcp.yaml >/dev/null <<'EOF'\nnetwork:\n  version: 2\n  renderer: networkd\n  ethernets:\n    all:\n      match:\n        name: \"en*\"\n      dhcp4: true\n      dhcp6: false\nEOF",

      "sudo snap install --classic cmake --channel=4.0",

      "sudo mkdir -p /opt/actions-runner",
      "sudo chown -R ${var.ssh_username}:${var.ssh_username} /opt/actions-runner",
      "cd /opt/actions-runner",
      "curl -fsSLO https://github.com/actions/runner/releases/download/v${var.runner_version}/actions-runner-linux-${var.runner_arch}-${var.runner_version}.tar.gz",
      "tar -xzf actions-runner-linux-${var.runner_arch}-${var.runner_version}.tar.gz",
      "rm -f actions-runner-linux-${var.runner_arch}-${var.runner_version}.tar.gz",
      "sudo /opt/actions-runner/bin/installdependencies.sh",
      "sudo install -m 0755 /tmp/runner-once.sh /opt/actions-runner/run-once.sh",

      # Quick sanity checks
      "patchelf --version",
      "gfortran --version",
      "command -v gfortran",
      "bash -lc 'echo FC=$FC; command -v \"$FC\" || true'"
    ]
  }

# Shell provisioner #2: pyenv + Python 3.12.3
provisioner "shell" {
  inline_shebang = "/usr/bin/env bash"
  inline = [
    "set -euxo pipefail",

    "sudo apt-get update",
    "sudo apt-get install -y make build-essential libssl-dev zlib1g-dev libbz2-dev libreadline-dev libsqlite3-dev curl llvm libncursesw5-dev xz-utils tk-dev libxml2-dev libxmlsec1-dev libffi-dev liblzma-dev",

    # Install pyenv
    "sudo -u ${var.ssh_username} -H bash -lc 'test -d ~/.pyenv || git clone --depth 1 https://github.com/pyenv/pyenv.git ~/.pyenv'",

    # Persist pyenv env for interactive shells
    "sudo -u ${var.ssh_username} -H bash -lc 'grep -q \"PYENV_ROOT\" ~/.bashrc || cat >> ~/.bashrc <<\"EOF\"\nexport PYENV_ROOT=\"$HOME/.pyenv\"\nexport PATH=\"$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH\"\neval \"$(pyenv init -)\"\nEOF'",

    # Persist pyenv env for login shells / non-interactive invocations that source .profile
    "sudo -u ${var.ssh_username} -H bash -lc 'grep -q \"PYENV_ROOT\" ~/.profile || cat >> ~/.profile <<\"EOF\"\nexport PYENV_ROOT=\"$HOME/.pyenv\"\nexport PATH=\"$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH\"\nEOF'",

    # Build + activate Python
    "sudo -u ${var.ssh_username} -H bash -lc 'export PYENV_ROOT=\"$HOME/.pyenv\"; export PATH=\"$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH\"; eval \"$(pyenv init -)\"; pyenv install -s 3.12.3'",
    "sudo -u ${var.ssh_username} -H bash -lc 'export PYENV_ROOT=\"$HOME/.pyenv\"; export PATH=\"$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH\"; eval \"$(pyenv init -)\"; pyenv global 3.12.3; pyenv rehash'",

    # Upgrade pip using the pyenv-selected python
    "sudo -u ${var.ssh_username} -H bash -lc 'export PYENV_ROOT=\"$HOME/.pyenv\"; export PATH=\"$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH\"; eval \"$(pyenv init -)\"; python -m pip install --upgrade pip'",

    # Verify pip/python in the same initialized environment (this was your failure point)
    "sudo -u ${var.ssh_username} -H bash -lc 'export PYENV_ROOT=\"$HOME/.pyenv\"; export PATH=\"$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH\"; eval \"$(pyenv init -)\"; python -m pip --version'",
    "sudo -u ${var.ssh_username} -H bash -lc 'export PYENV_ROOT=\"$HOME/.pyenv\"; export PATH=\"$PYENV_ROOT/bin:$PYENV_ROOT/shims:$PATH\"; eval \"$(pyenv init -)\"; python --version; which python'"
  ]
}


  # Shell provisioner #3: cleanup / template hygiene
  provisioner "shell" {
    inline_shebang = "/usr/bin/env bash"
    inline = [
      "set -euxo pipefail",

      "sudo rm -f /tmp/runner-once.sh",

      "sudo apt-get -y autoremove --purge",
      "sudo apt-get -y clean",
      "sudo rm -rf /var/lib/apt/lists/*",

      "sudo rm -f /etc/cloud/cloud-init.disabled",
      "sudo cloud-init clean --logs || true",
      "sudo truncate -s 0 /etc/machine-id",
      "if [ -f /var/lib/dbus/machine-id ]; then sudo truncate -s 0 /var/lib/dbus/machine-id; fi",

      "sudo rm -f /root/.bash_history || true",
      "sudo -u ${var.ssh_username} -H bash -lc 'rm -f ~/.bash_history || true'",
      "sudo find /var/log -type f -exec truncate -s 0 {} + || true"
    ]
  }
}
