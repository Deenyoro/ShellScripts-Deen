<#
.SYNOPSIS
    Insert a blank line before each `function` or comment block in a
    PowerShell script, without ever producing two blank lines in a row.

.EXAMPLE
    .\CodeLineSpacingFix.ps1 -InputScript .\myscript.ps1
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$InputScript,
    [string]$OutputScript
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $InputScript)) {
    throw "Input file not found: $InputScript"
}

if (-not $OutputScript) {
    $dir  = [IO.Path]::GetDirectoryName((Resolve-Path $InputScript).Path)
    $name = [IO.Path]::GetFileNameWithoutExtension($InputScript)
    $ext  = [IO.Path]::GetExtension($InputScript)
    $OutputScript = Join-Path $dir "$name.spacing$ext"
}

$lines = Get-Content -LiteralPath $InputScript
$out = New-Object System.Collections.Generic.List[string]

foreach ($line in $lines) {
    $wantsBlankBefore = $line -match '^\s*(function\b|#)'
    $lastLineBlank = ($out.Count -gt 0) -and [string]::IsNullOrWhiteSpace($out[$out.Count - 1])
    $firstLine = $out.Count -eq 0

    if ($wantsBlankBefore -and -not $lastLineBlank -and -not $firstLine) {
        $out.Add('')
    }
    $out.Add($line)
}

Set-Content -LiteralPath $OutputScript -Value $out -Encoding UTF8
Write-Host "Wrote $($out.Count) lines to $OutputScript"
