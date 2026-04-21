<#
.SYNOPSIS
    Create a local administrator account (interactively) and optionally
    enable Remote Desktop for it.

.NOTES
    Must be run elevated. Will not clobber an existing account of the same
    name. No default password is used — the user is re-prompted until a
    non-empty password is entered.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$UserName,
    [switch]$EnableRdp
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-NonEmptySecureString {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        if ($secure.Length -gt 0) { return $secure }
        Write-Warning 'Password cannot be empty.'
    }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $ans = (Read-Host "$Prompt (Y/N)").Trim().ToUpperInvariant()
        if ($ans -eq 'Y') { return $true }
        if ($ans -eq 'N') { return $false }
    }
}

if (-not (Read-YesNo 'Create a local admin account?')) {
    return
}

if (-not $UserName) {
    $answer = Read-Host 'New local admin username (Default: Admin)'
    $UserName = if ([string]::IsNullOrWhiteSpace($answer)) { 'Admin' } else { $answer }
}

if (Get-LocalUser -Name $UserName -ErrorAction SilentlyContinue) {
    throw "Local user '$UserName' already exists."
}

$password = Read-NonEmptySecureString -Prompt "Password for '$UserName'"

Write-Host "Creating local admin '$UserName'..."
$null = New-LocalUser -Name $UserName -Password $password `
    -FullName 'Local Administrator' -Description 'Local admin account' `
    -UserMayNotChangePassword -PasswordNeverExpires
Add-LocalGroupMember -Group 'Administrators' -Member $UserName
Write-Host "Created '$UserName' and added to Administrators."

if (-not $EnableRdp) {
    $EnableRdp = Read-YesNo 'Enable RDP for this machine?'
}
if ($EnableRdp) {
    Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' `
        -Name 'fDenyTSConnections' -Value 0
    Enable-NetFirewallRule -DisplayGroup 'Remote Desktop'
    # Also grant the new account RDP rights explicitly.
    Add-LocalGroupMember -Group 'Remote Desktop Users' -Member $UserName -ErrorAction SilentlyContinue
    Write-Host 'RDP enabled.'
}
