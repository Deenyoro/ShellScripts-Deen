<#
.SYNOPSIS
    Reset Windows Hello by removing the NGC container.

.DESCRIPTION
    Stops the auth-related services, takes ownership of
    %WinDir%\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc,
    wipes it, and restarts the services. The user will be prompted to
    re-enroll fingerprint / PIN / face on next logon.

.NOTES
    Must run elevated. Grants ownership to BUILTIN\Administrators
    (previous revision granted it to $env:USERNAME, which is only useful
    when that account is the one you want to reset — under SYSTEM it was
    the SYSTEM SID, which silently worked but wasn't the intent).
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ngcPath  = Join-Path $env:WinDir 'ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc'
$services = 'VaultSvc','UserManager','WbioSrvc'

foreach ($svc in $services) {
    $s = Get-Service -Name $svc -ErrorAction SilentlyContinue
    if ($s -and $s.Status -eq 'Running') {
        try {
            Stop-Service -Name $svc -Force -ErrorAction Stop
            Write-Host "Stopped $svc"
        } catch {
            Write-Warning "Could not stop ${svc}: $($_.Exception.Message)"
        }
    }
}

if (Test-Path -LiteralPath $ngcPath) {
    & takeown.exe /f $ngcPath /r /d Y | Out-Null
    & icacls.exe  $ngcPath /grant '*S-1-5-32-544:(F)' /t /c | Out-Null   # BUILTIN\Administrators
    try {
        Remove-Item -LiteralPath $ngcPath -Recurse -Force
        Write-Host "Removed $ngcPath"
    } catch {
        Write-Warning "Failed to remove ${ngcPath}: $($_.Exception.Message)"
    }
} else {
    Write-Host "$ngcPath does not exist; nothing to reset."
}

foreach ($svc in $services) {
    try {
        Start-Service -Name $svc -ErrorAction Stop
        Write-Host "Started $svc"
    } catch {
        Write-Warning "Could not start ${svc}: $($_.Exception.Message)"
    }
}

Write-Host 'Windows Hello reset complete. Re-enroll PIN / biometrics in Settings → Sign-in options.'
