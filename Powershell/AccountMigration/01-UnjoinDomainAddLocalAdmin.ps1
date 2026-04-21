<#
.SYNOPSIS
    Prep a domain-joined machine for Azure AD / Autopilot migration:
      1. (Optional) create a local admin account.
      2. (Optional) scrub Duo registry keys.
      3. (Optional) unjoin the on-prem domain and reboot.

.NOTES
    Must run elevated. If you enter a blank password for the new local admin
    you will be re-prompted; the "Pass1!Word" default from the previous
    revision was a security footgun and has been removed.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Helpers ---------------------------------------------------------------

function Read-NonEmptySecureString {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $secure = Read-Host -Prompt $Prompt -AsSecureString
        # Length > 0 means at least one character was entered.
        if ($secure.Length -gt 0) { return $secure }
        Write-Warning 'Password cannot be empty.'
    }
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $answer = (Read-Host "$Prompt (Y/N)").Trim().ToUpperInvariant()
        if ($answer -eq 'Y') { return $true }
        if ($answer -eq 'N') { return $false }
    }
}

function Read-WithDefault {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Default
    )
    $answer = Read-Host "$Prompt (Default: $Default)"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

# --- Gather credential for the unjoin (only if we're going to unjoin) ------

function Get-DomainCredential {
    $username = Read-Host 'Domain username for unjoin (DOMAIN\user)'
    $password = Read-NonEmptySecureString -Prompt 'Domain password'
    return [System.Management.Automation.PSCredential]::new($username, $password)
}

# --- Step: local admin -----------------------------------------------------

function New-LocalAdminAccount {
    $userName = Read-WithDefault -Prompt 'New local admin username' -Default 'Admin'

    if (Get-LocalUser -Name $userName -ErrorAction SilentlyContinue) {
        Write-Warning "Local user '$userName' already exists. Skipping creation."
        return
    }

    $password = Read-NonEmptySecureString -Prompt "New local admin password for '$userName'"

    Write-Host "Creating local admin account '$userName'..."
    $null = New-LocalUser -Name $userName -Password $password `
        -FullName 'Local Administrator' -Description 'Local admin account' `
        -UserMayNotChangePassword -PasswordNeverExpires
    Add-LocalGroupMember -Group 'Administrators' -Member $userName
    Write-Host "Local admin account '$userName' created."
}

# --- Step: Duo cleanup -----------------------------------------------------

function Remove-DuoRegistryKey {
    $paths = @(
        'HKLM:\Software\Wow6432Node\Duo Security'
        'HKLM:\Software\Duo Security'
        'HKCU:\Software\Duo Security'
    )

    foreach ($path in $paths) {
        if (Test-Path $path) {
            try {
                Remove-Item $path -Recurse -Force
                Write-Host "Removed $path"
            } catch {
                Write-Warning "Failed to remove ${path}: $($_.Exception.Message)"
            }
        }
    }

    # Catch any stragglers under Software\* named like *Duo*.
    try {
        Get-ChildItem -Path 'HKLM:\Software','HKCU:\Software' -ErrorAction SilentlyContinue |
            Where-Object { $_.PSChildName -like '*Duo*' } |
            ForEach-Object {
                try {
                    Remove-Item $_.PSPath -Recurse -Force
                    Write-Host "Removed $($_.PSPath)"
                } catch {
                    Write-Warning "Failed to remove $($_.PSPath): $($_.Exception.Message)"
                }
            }
    } catch {
        Write-Warning "Duo sweep failed: $($_.Exception.Message)"
    }
}

# --- Step: unjoin ----------------------------------------------------------

function Invoke-DomainUnjoin {
    param([Parameter(Mandatory)][pscredential]$Credential)
    Write-Host 'Unjoining on-prem domain. The machine will restart.'
    Remove-Computer -UnjoinDomainCredential $Credential -Force -Restart
}

# --- Orchestration ---------------------------------------------------------

if (Read-YesNo 'Create a local admin account?') {
    New-LocalAdminAccount
}

if (Read-YesNo 'Remove Duo registry keys?') {
    Remove-DuoRegistryKey
}

if (Read-YesNo 'Unjoin the domain and restart now?') {
    $cred = Get-DomainCredential
    Invoke-DomainUnjoin -Credential $cred
}
