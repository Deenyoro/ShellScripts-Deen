<#
.SYNOPSIS
    Upload this machine's Autopilot hardware hash to Intune, then open
    Settings → Access work or school so the tech can join Azure AD.

.NOTES
    Requires: local admin, an Azure AD account with permission to register
    Autopilot devices (Intune Administrator or custom role), and internet
    access. Installs the Get-WindowsAutoPilotInfo script on first run.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$GroupTag,
    [string]$AssignedUser
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PSGallery bootstrap (one-time on fresh images).
if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -Force -Scope CurrentUser | Out-Null
}
if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

if (-not (Get-InstalledScript -Name Get-WindowsAutoPilotInfo -ErrorAction SilentlyContinue)) {
    Write-Host 'Installing Get-WindowsAutoPilotInfo...'
    Install-Script -Name Get-WindowsAutoPilotInfo -Force -Scope CurrentUser
}

$splat = @{ Online = $true }
if ($GroupTag)     { $splat['GroupTag']     = $GroupTag }
if ($AssignedUser) { $splat['AssignedUser'] = $AssignedUser }

Write-Host 'Uploading Autopilot hardware hash (you will be prompted to sign in)...'
Get-WindowsAutoPilotInfo @splat

Write-Host 'Opening Settings → Access work or school so you can join Azure AD.'
Start-Process 'ms-settings:workplace'
