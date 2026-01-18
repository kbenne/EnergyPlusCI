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
  type    = string
  default = "windows-2022-runner-template"
}

variable "winrm_username" {
  type    = string
  default = "Administrator"
}

variable "winrm_password" {
  type      = string
  sensitive = true
}

variable "iso_url" {
  type        = string
  description = "Windows Server 2022 ISO URL"
  default     = ""
}

variable "iso_file" {
  type        = string
  description = "Existing Proxmox ISO path (example: local:iso/Windows_Server_2022.iso). When set, iso_url is ignored."
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

variable "virtio_iso_file" {
  type        = string
  description = "Proxmox ISO path for virtio-win drivers (example: local:iso/virtio-win.iso)"
  default     = "local:iso/virtio-win.iso"
}

variable "windows_image_name" {
  type        = string
  description = "Image name inside install.wim (example: Windows Server 2022 SERVERSTANDARD)"
  default     = "Windows Server 2022 SERVERSTANDARD"
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

source "proxmox-iso" "windows2022" {
  proxmox_url              = var.proxmox_url
  username                 = var.proxmox_username
  token                    = var.proxmox_token
  node                     = var.proxmox_node
  insecure_skip_tls_verify = true

  vm_name    = var.new_template_name
  tags       = "windows-2022_ci_template"
  qemu_agent = true

  boot_iso {
    type             = "scsi"
    iso_url          = var.iso_file != "" ? null : var.iso_url
    iso_file         = var.iso_file != "" ? var.iso_file : null
    iso_checksum     = var.iso_checksum
    iso_storage_pool = "local"
    iso_download_pve = var.iso_download_pve
    unmount          = true
  }

  additional_iso_files {
    type     = "sata"
    iso_file = var.virtio_iso_file
  }

  cd_content = {
    "Autounattend.xml" = templatefile("${abspath(path.root)}/answer_files/Autounattend.pkrtpl", {
      admin_password     = var.winrm_password
      windows_image_name = var.windows_image_name
    })
  }
  cd_files = [
    "${abspath(path.root)}/scripts/setup-winrm.ps1",
    "${abspath(path.root)}/scripts/install.ps1",
  ]
  cd_label = "CIDATA"

  task_timeout = "60m"

  cores   = 2
  sockets = 1
  memory  = 8192

  scsi_controller = "virtio-scsi-pci"

  disks {
    disk_size    = "60G"
    storage_pool = "local-lvm"
    type         = "scsi"
  }

  network_adapters {
    bridge = "vmbr0"
    model  = "virtio"
  }

  boot_wait         = "10s"
  boot_key_interval = "100ms"
  boot_command = [
    "<enter>"
  ]

  communicator = "winrm"
  winrm_username = var.winrm_username
  winrm_password = var.winrm_password
  winrm_insecure = true
  winrm_timeout  = "30m"
}

build {
  name    = "windows-2022-runner-template-from-iso"
  sources = ["source.proxmox-iso.windows2022"]

  provisioner "powershell" {
    environment_vars = [
      "RUNNER_VERSION=${var.runner_version}",
      "RUNNER_ARCH=${var.runner_arch}",
    ]
    inline = [
      "PowerShell -ExecutionPolicy Bypass -File C:\\install.ps1",
      "PowerShell -ExecutionPolicy Bypass -File C:\\setup-winrm.ps1",
    ]
  }
}
