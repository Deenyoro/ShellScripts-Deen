<#
.SYNOPSIS
    Filters a Message Trace CSV by a substring (e.g. a TLD) in a chosen
    column and writes a sorted subset back out.

.DESCRIPTION
    Uses Import-Csv (proper CSV parsing with quoted-field handling) rather
    than hand-splitting on `","`. Streams through the file so memory stays
    flat on large traces. Writes UTF-8 output.
#>

[CmdletBinding()]
param(
    [string]$InputFile,
    [string]$OutputFile,
    [string]$SearchColumn,
    [string]$FilterValue
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$SearchableColumns = @(
    'origin_timestamp_utc'
    'sender_address'
    'recipient_status'
    'message_subject'
)

$ColumnsToKeep = @(
    'origin_timestamp_utc'
    'sender_address'
    'recipient_status'
    'message_subject'
    'total_bytes'
    'message_id'
    'network_message_id'
    'original_client_ip'
    'directionality'
    'connector_id'
    'delivery_priority'
)

# --- Resolve input file ----------------------------------------------------
if (-not $InputFile) {
    Write-Host 'CSV files in the current directory:'
    Get-ChildItem -File -Filter '*.csv' | ForEach-Object { Write-Host "  $($_.Name)" }
    $InputFile = Read-Host 'Enter the input file path (or just the file name)'
}

if (-not $InputFile.EndsWith('.csv', [StringComparison]::OrdinalIgnoreCase)) {
    $InputFile += '.csv'
}
if (-not [System.IO.Path]::IsPathRooted($InputFile)) {
    $InputFile = Join-Path (Get-Location).Path $InputFile
}
if (-not (Test-Path -LiteralPath $InputFile)) {
    throw "Input file not found: $InputFile"
}

# --- Pick the column to search --------------------------------------------
if (-not $SearchColumn -or $SearchableColumns -notcontains $SearchColumn) {
    Write-Host 'Searchable columns:'
    $SearchableColumns | ForEach-Object { Write-Host "  $_" }
    $choice = Read-Host "Column to search (Enter for 'recipient_status')"
    if ([string]::IsNullOrWhiteSpace($choice) -or $SearchableColumns -notcontains $choice) {
        $SearchColumn = 'recipient_status'
    } else {
        $SearchColumn = $choice
    }
}

# --- Pick the filter value -------------------------------------------------
if (-not $FilterValue) {
    $raw = Read-Host "Value to match in '$SearchColumn' (Enter for '.ru')"
    if ([string]::IsNullOrWhiteSpace($raw)) { $FilterValue = '.ru' } else { $FilterValue = $raw }
}

# --- Output path -----------------------------------------------------------
if (-not $OutputFile) {
    $tag = if ($FilterValue -eq '.ru') { 'FilteredRU_' } else { 'Filtered_' }
    $OutputFile = $tag + [System.IO.Path]::GetFileNameWithoutExtension($InputFile) + '.csv'
}
if (-not [System.IO.Path]::IsPathRooted($OutputFile)) {
    $OutputFile = Join-Path (Get-Location).Path $OutputFile
}

Write-Host "Filtering $InputFile where $SearchColumn matches '$FilterValue'..."

# --- Filter ----------------------------------------------------------------
$pattern = [regex]::Escape($FilterValue)

# Stream the CSV; Import-Csv handles quoted commas properly. We still run the
# null-char strip because some Exchange exports are UTF-16 with NULs interleaved
# when the source was copied wrong.
$rows = Import-Csv -LiteralPath $InputFile |
    Where-Object {
        $val = $_.$SearchColumn
        if ($null -eq $val) { return $false }
        # Strip NULs and normalize the '##' escape Exchange uses for spaces in recipient_status.
        $val = ($val -replace "`0", '') -replace '##', ' '
        $_.$SearchColumn = $val
        $val -match $pattern
    } |
    Sort-Object origin_timestamp_utc

$rows | Select-Object $ColumnsToKeep |
    Export-Csv -LiteralPath $OutputFile -NoTypeInformation -Encoding UTF8

Write-Host ("Wrote {0} matching rows to {1}" -f ($rows | Measure-Object).Count, $OutputFile)
