<#
.SYNOPSIS
    Copy or move an old (on-prem) user profile's contents into the new
    (Azure AD) profile's folder, fix ACLs for the new SID, and optionally
    reset Windows Hello and rebuild the Start Menu.

.NOTES
    Must run elevated. This operation is destructive when in "move" mode;
    a log is written to C:\NACMigration\UserFolderTransferLog.txt.
#>

#Requires -RunAsAdministrator
[CmdletBinding()]
param(
    [string]$LogDirectory = 'C:\NACMigration'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Logging ---------------------------------------------------------------
if (-not (Test-Path $LogDirectory)) {
    New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
}
$logFile = Join-Path $LogDirectory 'UserFolderTransferLog.txt'

function Write-MigrationLog {
    param([Parameter(Mandatory)][string]$Message)
    $stamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line  = "$stamp  $Message"
    Add-Content -LiteralPath $logFile -Value $line
    Write-Host $line
}

Write-MigrationLog '=== User folder transfer started ==='

# --- Helpers ---------------------------------------------------------------

function Get-LocalUserSidTable {
    Get-CimInstance -ClassName Win32_UserAccount -Filter 'LocalAccount=TRUE' |
        Select-Object Name, SID
}

function Read-YesNo {
    param([Parameter(Mandatory)][string]$Prompt)
    while ($true) {
        $ans = (Read-Host "$Prompt (y/n)").Trim().ToLowerInvariant()
        if ($ans -eq 'y') { return $true }
        if ($ans -eq 'n') { return $false }
    }
}

function Confirm-OrExit {
    param([Parameter(Mandatory)][string]$Message)
    if (-not (Read-YesNo $Message)) {
        Write-MigrationLog 'User declined confirmation. Aborting.'
        exit 1
    }
}

function Get-ProfileInput {
    Write-Host 'Profiles under C:\Users:'
    Get-ChildItem 'C:\Users' -Directory | ForEach-Object { Write-Host "  $($_.Name)" }

    Write-Host ''
    Write-Host 'Local user SIDs (you will usually want the new Azure AD profile''s SID, which starts with S-1-12-1):'
    Get-LocalUserSidTable | Format-Table -AutoSize | Out-String | Write-Host

    while ($true) {
        $old  = Read-Host 'Old (source) profile folder name'
        $new  = Read-Host 'New (target) profile folder name'
        $sid  = Read-Host 'SID of the new/target user'

        $src = Join-Path 'C:\Users' $old
        $dst = Join-Path 'C:\Users' $new

        if (-not (Test-Path $src)) { Write-Warning "Source profile not found: $src"; continue }
        if (-not (Test-Path $dst)) { Write-Warning "Target profile not found: $dst"; continue }
        if ($sid -notmatch '^S-1-') { Write-Warning "SID doesn't look right: $sid"; continue }

        return [pscustomobject]@{
            OldName = $old
            NewName = $new
            NewSID  = $sid
            Source  = $src
            Target  = $dst
        }
    }
}

function Grant-ProfileAcl {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Sid
    )
    Write-MigrationLog "icacls $Path /grant *${Sid}:(OI)(CI)F /T"
    & icacls.exe $Path /grant "*${Sid}:(OI)(CI)F" /T | Out-Null
    if ($LASTEXITCODE -ne 0) { Write-Warning "icacls returned $LASTEXITCODE on $Path" }
}

function Reset-WindowsHello {
    param([Parameter(Mandatory)][string]$Sid)

    $ngc = 'C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc'
    $services = 'VaultSvc','UserManager','WbioSrvc'

    foreach ($s in $services) {
        try { Stop-Service -Name $s -Force -ErrorAction Stop; Write-MigrationLog "Stopped $s" }
        catch { Write-Warning "Could not stop ${s}: $($_.Exception.Message)" }
    }

    if (Test-Path $ngc) {
        & takeown.exe /f $ngc /r /d Y | Out-Null
        & icacls.exe  $ngc /grant "*${Sid}:(F)" /t /c | Out-Null
        Remove-Item $ngc -Recurse -Force -ErrorAction SilentlyContinue
        Write-MigrationLog 'Ngc folder removed.'
    } else {
        Write-MigrationLog 'Ngc folder not present.'
    }

    foreach ($s in $services) {
        try { Start-Service -Name $s -ErrorAction Stop; Write-MigrationLog "Started $s" }
        catch { Write-Warning "Could not start ${s}: $($_.Exception.Message)" }
    }
}

function Repair-StartMenu {
    Write-MigrationLog 'Re-registering AppX packages for all users (this can take a few minutes)...'
    Get-AppxPackage -AllUsers | ForEach-Object {
        try {
            Add-AppxPackage -DisableDevelopmentMode -Register (Join-Path $_.InstallLocation 'AppXManifest.xml') -ErrorAction Stop
        } catch {
            Write-Warning "Failed to re-register $($_.Name): $($_.Exception.Message)"
        }
    }
}

# --- Gather inputs ---------------------------------------------------------
$p = Get-ProfileInput

Write-MigrationLog "Old profile:  $($p.OldName)  ($($p.Source))"
Write-MigrationLog "New profile:  $($p.NewName)  ($($p.Target))"
Write-MigrationLog "New SID:      $($p.NewSID)"
Write-MigrationLog 'WARNING: This script can move files and is not reversible.'

Confirm-OrExit 'Proceed with the profile migration?'

if (Read-YesNo 'Grant the new SID full control over the OLD profile folder first?') {
    Grant-ProfileAcl -Path $p.Source -Sid $p.NewSID
}

if (Read-YesNo 'Grant the new SID full control over the NEW profile folder?') {
    Grant-ProfileAcl -Path $p.Target -Sid $p.NewSID
}

# --- Move / copy -----------------------------------------------------------
while ($true) {
    $op = (Read-Host 'Move (m) or copy (c) the profile data?').Trim().ToLowerInvariant()
    if ($op -eq 'm' -or $op -eq 'c') { break }
}

# Use robocopy — much faster, hardlink-safe, and logs attribute/ACL issues we care about.
$robocopyArgs = @('/E','/COPY:DAT','/DCOPY:DAT','/R:1','/W:2','/NFL','/NDL','/NP')
if ($op -eq 'm') {
    Confirm-OrExit "Confirm MOVE from $($p.Source) → $($p.Target)"
    $robocopyArgs += '/MOVE'
} else {
    Confirm-OrExit "Confirm COPY from $($p.Source) → $($p.Target)"
}

Write-MigrationLog "robocopy $($p.Source) $($p.Target) $($robocopyArgs -join ' ')"
& robocopy.exe $p.Source $p.Target @robocopyArgs | Tee-Object -Variable robocopyOutput | Write-Host
# robocopy exit codes 0–7 are success (8+ indicate real failures).
if ($LASTEXITCODE -ge 8) {
    Write-MigrationLog "robocopy reported failure (exit $LASTEXITCODE). See output above."
    throw "robocopy failed (exit $LASTEXITCODE)"
}
Write-MigrationLog "robocopy finished (exit $LASTEXITCODE)."

# --- Optional extras -------------------------------------------------------
if (Read-YesNo 'Reset Windows Hello?')          { Reset-WindowsHello -Sid $p.NewSID }
if (Read-YesNo 'Rebuild the Start Menu tiles?') { Repair-StartMenu }

if (Read-YesNo 'Restart now?') {
    Write-MigrationLog 'Restarting computer.'
    Restart-Computer -Force
} else {
    Write-MigrationLog 'Restart skipped by user.'
}
