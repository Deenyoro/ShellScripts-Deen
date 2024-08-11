# Autopilot
Install-Script -Name Get-WindowsAutoPilotInfo -Force
Get-WindowsAutoPilotInfo -Online
# Open the Azure AD join UI 
Start-Process "ms-settings:workplace"