<#
.SYNOPSIS
    Force an immediate Intune policy sync on the local machine.

.DESCRIPTION
    The previous revision of this script called `usoclient.exe RefreshPolicy`
    — which is the *Windows Update* client, not Intune / MDM. The correct
    way to kick off an Intune sync is to start the "PushLaunch" scheduled
    task that the MDM enrollment registers under
    \Microsoft\Windows\EnterpriseMgmt\<EnrollmentGUID>\. This script finds
    every such task and starts it.

    Falls back to Intune Management Extension's `IntuneManagementExtension.exe`
    if found. Writes a transcript to C:\MDM\intune_sync.log.

.NOTES
    Requires local admin because EnterpriseMgmt tasks run as SYSTEM.
    No scheduled-task creation needed any more — we trigger the one Intune
    already installed, which is the same thing the Settings UI "Sync" button
    does.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$LogDirectory = 'C:\MDM'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
$logFile = Join-Path $LogDirectory 'intune_sync.log'
Start-Transcript -Path $logFile -Append | Out-Null

function Write-MdmLog { param([string]$m) Write-Host ("{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $m) }

$kickedOff = 0

try {
    Write-MdmLog 'Looking for Intune PushLaunch scheduled tasks...'
    $pushTasks = Get-ScheduledTask -TaskPath '\Microsoft\Windows\EnterpriseMgmt\*' -ErrorAction SilentlyContinue |
                 Where-Object { $_.TaskName -eq 'PushLaunch' }

    if (-not $pushTasks) {
        Write-MdmLog 'No PushLaunch tasks found. Is this device actually MDM-enrolled? (Check dsregcmd /status.)'
    }

    foreach ($t in $pushTasks) {
        try {
            Start-ScheduledTask -TaskPath $t.TaskPath -TaskName $t.TaskName
            Write-MdmLog "Started $($t.TaskPath)$($t.TaskName)"
            $kickedOff++
        } catch {
            Write-Warning "Failed to start $($t.TaskPath)$($t.TaskName): $($_.Exception.Message)"
        }
    }

    # Intune Management Extension (IME) sync — triggers Win32 app / PowerShell script re-evaluation.
    $imePath = "$env:ProgramFiles\Microsoft Intune Management Extension\Microsoft.Management.Services.IntuneWindowsAgent.exe"
    if (Test-Path -LiteralPath $imePath) {
        try {
            & $imePath 'intunemanagementextension://syncapp' 2>&1 | Out-Null
            Write-MdmLog 'Triggered Intune Management Extension sync.'
            $kickedOff++
        } catch {
            Write-Warning "IME trigger failed: $($_.Exception.Message)"
        }
    } else {
        Write-MdmLog 'Intune Management Extension not installed (expected only on devices that use Win32 apps / PS scripts).'
    }

    if ($kickedOff -eq 0) {
        Write-Warning 'No sync mechanisms were triggered. Device may not be MDM-enrolled.'
        exit 1
    }

    Write-MdmLog "Sync requests submitted: $kickedOff. Results typically show up within a few minutes."
}
finally {
    Stop-Transcript | Out-Null
}
