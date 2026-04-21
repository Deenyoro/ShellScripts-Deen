<#
.SYNOPSIS
    Install a Help Desk .url shortcut on the current user's desktop
    (OneDrive-redirected or classic) and — if running elevated — on the
    All-Users / Public desktop as well.

.NOTES
    Intune-friendly: writes a transcript to C:\MDM\helpdesk_install.log
    and returns non-zero on hard failures so the deployment shows the
    correct state.
#>

[CmdletBinding()]
param(
    [string]$ShortcutName = 'EMAIL HELP@PLACEHOLDER.COM OR CALL 4125555555.url',
    [string]$TargetUrl    = 'https://help.PLACEHOLDER.com',
    [string]$IconPath     = (Join-Path $PSScriptRoot 'help-desk.ico'),
    [string]$LogDirectory = 'C:\MDM'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
Start-Transcript -Path (Join-Path $LogDirectory 'helpdesk_install.log') -Append | Out-Null

function Write-UrlShortcut {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Url,
        [string]$Icon
    )
    $content = "[InternetShortcut]`r`nURL=$Url"
    if ($Icon -and (Test-Path -LiteralPath $Icon)) {
        $content += "`r`nIconFile=$Icon`r`nIconIndex=0"
    }
    Set-Content -LiteralPath $Path -Value $content -Encoding ASCII
}

function Install-Shortcut {
    param(
        [Parameter(Mandatory)][string]$DesktopPath,
        [Parameter(Mandatory)][string]$ShortcutName,
        [Parameter(Mandatory)][string]$TargetUrl,
        [string]$IconPath
    )
    if (-not (Test-Path -LiteralPath $DesktopPath)) {
        New-Item -Path $DesktopPath -ItemType Directory -Force | Out-Null
    }
    $full = Join-Path $DesktopPath $ShortcutName
    if (Test-Path -LiteralPath $full) {
        Write-Host "Skip (exists): $full"
        return
    }
    Write-UrlShortcut -Path $full -Url $TargetUrl -Icon $IconPath
    Write-Host "Created: $full"
}

$failed = $false
try {
    if (-not (Test-Path -LiteralPath $IconPath)) {
        Write-Warning "Icon file not found at $IconPath. Shortcut will fall back to the default globe icon."
    }

    # Per-user desktop (works for both classic and OneDrive-redirected Desktop).
    $userDesktop = [Environment]::GetFolderPath('Desktop')
    try {
        Install-Shortcut -DesktopPath $userDesktop -ShortcutName $ShortcutName `
            -TargetUrl $TargetUrl -IconPath $IconPath
    } catch {
        Write-Warning "User-desktop install failed: $($_.Exception.Message)"
        $failed = $true
    }

    # Public desktop (only meaningful when running elevated / as SYSTEM).
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).
        IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if ($isAdmin) {
        $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
        try {
            Install-Shortcut -DesktopPath $publicDesktop -ShortcutName $ShortcutName `
                -TargetUrl $TargetUrl -IconPath $IconPath
        } catch {
            Write-Warning "Public-desktop install failed: $($_.Exception.Message)"
            $failed = $true
        }
    } else {
        Write-Host 'Not elevated; skipping Public desktop.'
    }
}
finally {
    Stop-Transcript | Out-Null
}

if ($failed) { exit 1 }
