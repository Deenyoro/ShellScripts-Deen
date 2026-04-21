<#
.SYNOPSIS
    Convert every .heic in a directory (optionally recursively) to .png
    using ImageMagick's `magick` binary. Installs ImageMagick via winget
    if it's missing.
#>

[CmdletBinding()]
param(
    [string]$Directory,
    [string]$OutputDirectory,
    [switch]$Recurse,
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Get-Command magick -ErrorAction SilentlyContinue)) {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        throw 'ImageMagick is not installed and winget is unavailable. Install ImageMagick manually: https://imagemagick.org/script/download.php'
    }
    Write-Host 'Installing ImageMagick via winget...'
    winget install --id ImageMagick.ImageMagick --accept-source-agreements --accept-package-agreements
    if (-not (Get-Command magick -ErrorAction SilentlyContinue)) {
        throw 'ImageMagick install completed but `magick` is still not on PATH. Open a new shell and rerun.'
    }
}

if (-not $Directory) {
    $Directory = Read-Host 'Directory containing HEIC files (Enter = current)'
    if ([string]::IsNullOrWhiteSpace($Directory)) { $Directory = (Get-Location).Path }
}
$Directory = (Resolve-Path -LiteralPath $Directory).Path

if (-not $OutputDirectory) {
    $OutputDirectory = Join-Path $Directory 'heic_to_png'
}
if (-not (Test-Path -LiteralPath $OutputDirectory)) {
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
}

$ci = @{ Path = $Directory; Filter = '*.heic'; File = $true }
if ($Recurse) { $ci['Recurse'] = $true }

$files = Get-ChildItem @ci
if (-not $files) {
    Write-Host "No .heic files found under $Directory"
    return
}

$converted = 0
$failed    = 0
foreach ($f in $files) {
    $out = Join-Path $OutputDirectory "$($f.BaseName).png"
    if ((Test-Path -LiteralPath $out) -and -not $Force) {
        Write-Host "Skip (exists): $($f.Name)"
        continue
    }
    Write-Host "Converting: $($f.FullName) -> $out"
    & magick $f.FullName $out
    if ($LASTEXITCODE -eq 0 -and (Test-Path -LiteralPath $out)) {
        $converted++
    } else {
        Write-Warning "magick failed (exit $LASTEXITCODE) on $($f.Name)"
        $failed++
    }
}

Write-Host ""
Write-Host "Converted: $converted   Failed: $failed   Output: $OutputDirectory"
if ($failed -gt 0) { exit 1 }
