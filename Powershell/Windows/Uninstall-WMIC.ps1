<#
.SYNOPSIS
    Remove the WMIC Windows capability (via Remove-WindowsCapability first,
    DISM fallback second) and clean up the install-marker file.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','CapabilityName',Justification='Used inside nested functions via script scope.')]
param(
    [string]$CapabilityName = 'WMIC~~~~',
    [string]$MarkerFile     = 'C:\MDM\wmic_install_complete.txt',
    [string]$LogFile        = 'C:\MDM\wmic_uninstall.log'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$wmicPath = Join-Path $env:WinDir 'System32\wbem\WMIC.exe'

foreach ($p in ($LogFile, $MarkerFile)) {
    $parent = Split-Path -Parent $p
    if (-not (Test-Path -LiteralPath $parent)) { New-Item -Path $parent -ItemType Directory -Force | Out-Null }
}

function Write-MdmLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Severity = 'INFO'
    )
    $line = "{0} [{1}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Severity, $Message
    Add-Content -LiteralPath $LogFile -Value $line
    Write-Host $line
}

function Test-WmicCapabilityInstalled {
    try {
        $c = Get-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop
        return ($c.State -eq 'Installed')
    } catch {
        return $false
    }
}

function Uninstall-WmicCapability {
    try {
        Remove-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop | Out-Null
        Write-MdmLog 'Remove-WindowsCapability succeeded.'
        return $true
    } catch {
        Write-MdmLog "Remove-WindowsCapability failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Uninstall-WmicViaDism {
    try {
        $proc = Start-Process -FilePath 'dism.exe' `
            -ArgumentList '/Online','/Remove-Capability',"/CapabilityName:$CapabilityName" `
            -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-MdmLog 'DISM remove succeeded.'
            return $true
        }
        Write-MdmLog "DISM remove failed (exit $($proc.ExitCode))." 'ERROR'
        return $false
    } catch {
        Write-MdmLog "DISM remove threw: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

Write-MdmLog '----- WMIC uninstall starting -----'

if (-not (Test-WmicCapabilityInstalled)) {
    Write-MdmLog 'WMIC capability not installed; nothing to do.'
} else {
    if (-not (Uninstall-WmicCapability)) {
        if (-not (Uninstall-WmicViaDism)) {
            Write-MdmLog 'Uninstall failed via both methods.' 'ERROR'
            exit 1
        }
    }
}

$stillInstalled = Test-WmicCapabilityInstalled
$exeStillThere  = Test-Path -LiteralPath $wmicPath

if (-not ($stillInstalled -or $exeStillThere)) {
    Write-MdmLog 'Uninstall verified.'
    if (Test-Path -LiteralPath $MarkerFile) {
        Remove-Item -LiteralPath $MarkerFile -Force
        Write-MdmLog "Removed marker $MarkerFile"
    }
} else {
    Write-MdmLog "Verification failed (capability installed: $stillInstalled, wmic.exe present: $exeStillThere)." 'ERROR'
    exit 1
}

Write-MdmLog '----- Done -----'
