$ErrorActionPreference = "Stop"

Write-Host "Configuring WinRM..."
winrm quickconfig -q
winrm set winrm/config/service/auth "@{Basic=\"true\"}"
winrm set winrm/config/service "@{AllowUnencrypted=\"true\"}"
winrm set winrm/config/winrs "@{MaxMemoryPerShellMB=\"1024\"}"

Enable-NetFirewallRule -DisplayGroup "Windows Remote Management"

Write-Host "WinRM configured."
