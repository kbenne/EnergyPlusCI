proxmox_url       = "http://proxmox.lan:8006/api2/json"
proxmox_username  = "root@pam!packer"
proxmox_node      = "proxmox"
new_template_name = "ubuntu-22.04-runner-template-v1"
ssh_username      = "ci"

# Secrets are often placed here for local development,
# but should not be committed to source control.
proxmox_token     = "REPLACE_ME"
ssh_password      = "REPLACE_ME"
ssh_password_hash = "REPLACE_ME"
