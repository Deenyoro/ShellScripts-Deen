<#
.SYNOPSIS
    Download a list of helper scripts into C:\PSScripts (or a caller-supplied
    directory).

.NOTES
    The previous version of this script used a hashtable literal with
    duplicate "RAWLINK" keys, which PowerShell rejects at parse time. This
    rewrite uses an array of {Url, Path} pairs, supports TLS 1.2 on older
    Windows PowerShell, verifies the download, and reports per-item failures.

.EXAMPLE
    .\DownloadScripts.ps1
.EXAMPLE
    .\DownloadScripts.ps1 -DestinationDirectory D:\Tools
#>

[CmdletBinding()]
param(
    [string]$DestinationDirectory = 'C:\PSScripts'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# --- Edit this list ---------------------------------------------------------
# Each entry: @{ Url = '<raw url>'; Name = '<file name to save as>' }
$downloads = @(
    @{ Url = 'https://pastebin.com/raw/SdVbCdZy'; Name = 'ManageExecutionPolicy.bat' }
    # @{ Url = 'https://example.com/raw/foo.ps1'; Name = 'foo.ps1' }
    # @{ Url = 'https://example.com/raw/bar.ps1'; Name = 'bar.ps1' }
)
# ---------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $DestinationDirectory)) {
    New-Item -ItemType Directory -Path $DestinationDirectory -Force | Out-Null
}

# Enable TLS 1.2 (needed on Windows PowerShell 5.1 against modern endpoints).
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch { Write-Verbose "TLS 1.2 toggle skipped: $($_.Exception.Message)" }

$failed = 0
foreach ($item in $downloads) {
    $target = Join-Path $DestinationDirectory $item.Name
    Write-Host "Downloading $($item.Url) -> $target"
    try {
        Invoke-WebRequest -Uri $item.Url -OutFile $target -UseBasicParsing
        if (-not (Test-Path -LiteralPath $target) -or (Get-Item $target).Length -eq 0) {
            throw 'Downloaded file is missing or empty.'
        }
    } catch {
        Write-Warning "Failed: $($item.Url) — $($_.Exception.Message)"
        $failed++
    }
}

Write-Host ''
Write-Host "Destination: $DestinationDirectory"
Get-ChildItem -LiteralPath $DestinationDirectory | Format-Table Name, Length, LastWriteTime

if ($failed -gt 0) { exit 1 }
