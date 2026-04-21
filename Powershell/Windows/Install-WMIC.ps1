<#
.SYNOPSIS
    Ensure the WMIC Windows capability is installed and WMIC.exe is working.

.DESCRIPTION
    Tries Add-WindowsCapability first, then falls back to the DISM CLI.
    Writes a timestamped log to C:\MDM\wmic_install.log and drops a marker
    file at C:\MDM\wmic_install_complete.txt on success (useful as a
    detection rule target in Intune Win32 apps).
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter','CapabilityName',Justification='Used inside nested functions via script scope.')]
param(
    [string]$CapabilityName = 'WMIC~~~~',
    [string]$MarkerFile     = 'C:\MDM\wmic_install_complete.txt',
    [string]$LogFile        = 'C:\MDM\wmic_install.log'
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

function Test-WmicOperational {
    if (-not (Test-Path -LiteralPath $wmicPath)) { return $false }
    try {
        $null = & $wmicPath /? 2>&1
        return $LASTEXITCODE -eq 0
    } catch {
        return $false
    }
}

function Install-WmicCapability {
    try {
        Write-MdmLog 'Attempting Add-WindowsCapability...'
        Add-WindowsCapability -Online -Name $CapabilityName -ErrorAction Stop | Out-Null
        Write-MdmLog 'Add-WindowsCapability succeeded.'
        return $true
    } catch {
        Write-MdmLog "Add-WindowsCapability failed: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Install-WmicViaDism {
    try {
        Write-MdmLog 'Falling back to DISM...'
        $proc = Start-Process -FilePath 'dism.exe' `
            -ArgumentList '/Online','/Add-Capability',"/CapabilityName:$CapabilityName" `
            -Wait -NoNewWindow -PassThru
        if ($proc.ExitCode -eq 0) {
            Write-MdmLog 'DISM succeeded.'
            return $true
        }
        Write-MdmLog "DISM failed (exit $($proc.ExitCode))." 'ERROR'
        return $false
    } catch {
        Write-MdmLog "DISM threw: $($_.Exception.Message)" 'ERROR'
        return $false
    }
}

function Set-MarkerFile {
    if (Test-Path -LiteralPath $MarkerFile) { return }
    New-Item -Path $MarkerFile -ItemType File -Force | Out-Null
    Write-MdmLog "Created marker $MarkerFile"
}

function Remove-MarkerFile {
    if (Test-Path -LiteralPath $MarkerFile) {
        Remove-Item -LiteralPath $MarkerFile -Force
        Write-MdmLog "Removed stale marker $MarkerFile"
    }
}

Write-MdmLog '----- WMIC install starting -----'

if (Test-WmicOperational) {
    Write-MdmLog 'WMIC is already installed and operational.'
    Set-MarkerFile
    Write-MdmLog '----- Done -----'
    return
}

$ok = Install-WmicCapability
if (-not $ok) { $ok = Install-WmicViaDism }

if (-not $ok) {
    Write-MdmLog 'Both install methods failed.' 'ERROR'
    Remove-MarkerFile
    exit 1
}

if (Test-WmicOperational) {
    Write-MdmLog 'Post-install verification succeeded.'
    Set-MarkerFile
} else {
    Write-MdmLog 'Install command reported success, but WMIC still not operational.' 'ERROR'
    Remove-MarkerFile
    exit 1
}

Write-MdmLog '----- Done -----'
