<#
.SYNOPSIS
    Install PSWindowsUpdate (first run only), scan, and install all
    available Windows Updates. Does not auto-reboot.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$AutoReboot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# PSGallery + TLS bootstrap (Windows PowerShell 5.1 needs TLS 1.2).
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { Write-Verbose "TLS 1.2 toggle skipped: $($_.Exception.Message)" }

if (-not (Get-PackageProvider -Name NuGet -ErrorAction SilentlyContinue)) {
    Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 -Force | Out-Null
}
if ((Get-PSRepository -Name PSGallery).InstallationPolicy -ne 'Trusted') {
    Set-PSRepository -Name PSGallery -InstallationPolicy Trusted
}

if (-not (Get-Module -ListAvailable -Name PSWindowsUpdate)) {
    Write-Host 'Installing PSWindowsUpdate...'
    Install-Module -Name PSWindowsUpdate -Force -Scope AllUsers
}

Import-Module PSWindowsUpdate -Force

Write-Host 'Scanning for available updates...'
$available = Get-WindowsUpdate -MicrosoftUpdate
if (-not $available) {
    Write-Host 'No updates available.'
    return
}

$available | Format-Table -AutoSize KB, Title, Size

Write-Host 'Installing all available updates...'
$installArgs = @{
    AcceptAll       = $true
    MicrosoftUpdate = $true
    Verbose         = $true
}
if ($AutoReboot) { $installArgs['AutoReboot']   = $true }
else             { $installArgs['IgnoreReboot'] = $true }
Install-WindowsUpdate @installArgs
