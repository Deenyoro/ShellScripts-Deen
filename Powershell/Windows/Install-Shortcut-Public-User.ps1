<#
.SYNOPSIS
    Install a Help Desk .url shortcut on the machine-wide / Public desktop.

.NOTES
    Must run elevated (or as SYSTEM via Intune). The Public desktop path is
    resolved through the known-folder API, so it works on relocated
    installs too.
#>

#Requires -RunAsAdministrator
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
Start-Transcript -Path (Join-Path $LogDirectory 'public_helpdesk_install.log') -Append | Out-Null

try {
    $publicDesktop = [Environment]::GetFolderPath('CommonDesktopDirectory')
    if (-not (Test-Path -LiteralPath $publicDesktop)) {
        New-Item -Path $publicDesktop -ItemType Directory -Force | Out-Null
    }

    $shortcut = Join-Path $publicDesktop $ShortcutName
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
    Write-Error "Public-desktop install failed: $($_.Exception.Message)"
    Stop-Transcript | Out-Null
    exit 1
}
Stop-Transcript | Out-Null
