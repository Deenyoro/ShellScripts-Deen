<#
.SYNOPSIS
    Install a Help Desk .url shortcut on the current user's Desktop,
    following OneDrive redirection automatically via the Desktop
    known-folder API.

.NOTES
    Deploy per-user (Intune "user" install context). For the machine-wide
    / Public desktop variant see Install-Shortcut-Public-User.ps1, or use
    Install-Shortcut-Combined-Public-Onedrive.ps1 to do both in one run.
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
Start-Transcript -Path (Join-Path $LogDirectory 'user_helpdesk_install.log') -Append | Out-Null

try {
    $desktop = [Environment]::GetFolderPath('Desktop')
    if ($desktop -like '*OneDrive*') {
        Write-Host "OneDrive-redirected desktop detected at $desktop."
    } else {
        Write-Host "Classic desktop at $desktop."
    }

    if (-not (Test-Path -LiteralPath $desktop)) {
        New-Item -Path $desktop -ItemType Directory -Force | Out-Null
    }

    $shortcut = Join-Path $desktop $ShortcutName
    if (Test-Path -LiteralPath $shortcut) {
        Write-Host "Shortcut already present: $shortcut"
        return
    }

    if (-not (Test-Path -LiteralPath $IconPath)) {
        Write-Warning "Icon file not found at $IconPath; shortcut will use the default globe icon."
        $IconPath = $null
    }

    $content = "[InternetShortcut]`r`nURL=$TargetUrl"
    if ($IconPath) { $content += "`r`nIconFile=$IconPath`r`nIconIndex=0" }

    Set-Content -LiteralPath $shortcut -Value $content -Encoding ASCII
    Write-Host "Created $shortcut"
}
catch {
    Write-Error "User-desktop install failed: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
