# Copy me to packer.auto.pkrvars.hcl and define variables / secrets

proxmox_url      = "https://proxmox.lan:8006/api2/json" # REPLACE_ME with name/ip of proxmox server
proxmox_username = "root@pam!packer"
proxmox_node     = "proxmox"
proxmox_token    = "REPLACE_ME"

winrm_password = "REPLACE_ME"

# Use iso_file for Windows ISOs provided on Proxmox storage.
# iso_file       = "local:iso/Windows_Server_2022.iso"
# iso_checksum   = "none"

# Virtio driver ISO path on Proxmox (download from Fedora virtio-win).
# virtio_iso_file = "local:iso/virtio-win.iso"

# Optional: override the Windows image name inside the ISO.
# windows_image_name = "Windows Server 2022 SERVERSTANDARD"

# Optional: GitHub Actions runner version/arch baked into the image.
# runner_version = "2.327.0"
# runner_arch = "x64"
