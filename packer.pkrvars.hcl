# Copy me to packer.auto.pkrvar.hcl and define variables / secrets

proxmox_url       = "https://proxmox.lan:8006/api2/json" # REPLACE_ME with name/ip of proxmox server
proxmox_username  = "root@pam!packer"
proxmox_node      = "proxmox"
proxmox_token     = "REPLACE_ME"
ssh_username      = "ci"
ssh_password      = "REPLACE_ME"
ssh_password_hash = "REPLACE_ME"
