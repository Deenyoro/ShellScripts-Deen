<#
.SYNOPSIS
    Scrub Duo Security registry keys from a workstation (HKLM + HKCU).

.NOTES
    Must run elevated. Returns non-zero if any removal failed so deployment
    tooling can flag it.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$NoPrompt
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $ans = (Read-Host "$Prompt (Y/N)").Trim().ToUpperInvariant()
        if ($ans -eq 'Y') { return $true }
        if ($ans -eq 'N') { return $false }
    }
}

if (-not $NoPrompt -and -not (Read-YesNo 'Remove Duo Security registry keys?')) {
    return
}

$paths = @(
    'HKLM:\Software\Wow6432Node\Duo Security'
    'HKLM:\Software\Duo Security'
    'HKCU:\Software\Duo Security'
)

$errors = 0
foreach ($p in $paths) {
    if (-not (Test-Path $p)) {
        Write-Host "Not present: $p"
        continue
    }
    try {
        Remove-Item $p -Recurse -Force
        Write-Host "Removed: $p"
    } catch {
        Write-Warning "Failed to remove $p — $($_.Exception.Message)"
        $errors++
    }
}

# Sweep up any stragglers whose key name contains 'Duo' directly under Software\.
try {
    $stragglers = Get-ChildItem -Path 'HKLM:\Software','HKCU:\Software' -ErrorAction SilentlyContinue |
        Where-Object { $_.PSChildName -like '*Duo*' }
    foreach ($s in $stragglers) {
        try {
            Remove-Item -LiteralPath $s.PSPath -Recurse -Force
            Write-Host "Removed: $($s.PSPath)"
        } catch {
            Write-Warning "Failed to remove $($s.PSPath) — $($_.Exception.Message)"
            $errors++
        }
    }
} catch {
    Write-Warning "Duo sweep failed: $($_.Exception.Message)"
    $errors++
}

if ($errors -gt 0) { exit 1 }
