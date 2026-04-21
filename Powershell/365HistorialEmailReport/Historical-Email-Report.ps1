<#
.SYNOPSIS
    Kicks off an Exchange Online Historical Search (Message Trace).

.DESCRIPTION
    Prompts for the admin UPN, a start/end date (defaults to the previous
    calendar month), a sender filter, and a notify address. Installs the
    ExchangeOnlineManagement module if it is not already present.

.NOTES
    Requires: Exchange Online admin role with permission to run
    Start-HistoricalSearch. Results land in the notify mailbox when the
    search completes (can take hours).
#>

[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-WithDefault {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][string]$Default
    )
    $answer = Read-Host "$Prompt [Default: $Default]"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $Default }
    return $answer
}

function Read-DateWithDefault {
    param(
        [Parameter(Mandatory)][string]$Prompt,
        [Parameter(Mandatory)][datetime]$Default
    )
    while ($true) {
        $raw = Read-Host "$Prompt [Default: $($Default.ToString('MM/dd/yyyy'))]"
        if ([string]::IsNullOrWhiteSpace($raw)) { return $Default }
        try {
            return [datetime]::ParseExact($raw, 'MM/dd/yyyy', $null)
        } catch {
            Write-Warning "Could not parse '$raw' as MM/DD/YYYY. Try again."
        }
    }
}

# --- Module bootstrap ------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Write-Host 'Installing ExchangeOnlineManagement module (CurrentUser scope)...'
    Install-Module -Name ExchangeOnlineManagement -Scope CurrentUser -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement

# --- Prompts ---------------------------------------------------------------
$upn = Read-WithDefault -Prompt 'Admin UPN' -Default 'admin@example.com'

$today = Get-Date
$firstOfPrev = $today.AddMonths(-1).Date.AddDays(-($today.Day - 1))
$lastOfPrev  = $today.Date.AddDays(-$today.Day)

$startDate = Read-DateWithDefault -Prompt 'Start date (MM/DD/YYYY)' -Default $firstOfPrev
$endDate   = Read-DateWithDefault -Prompt 'End date (MM/DD/YYYY)'   -Default $lastOfPrev

if ($endDate -lt $startDate) {
    throw "End date ($endDate) is before start date ($startDate)."
}

$senderAddress = Read-WithDefault -Prompt 'Sender address filter (wildcard ok)' -Default '*@yandex.com'
$notifyAddress = Read-WithDefault -Prompt 'Notify address (mailbox to receive the report)' -Default $upn

# --- Run the search --------------------------------------------------------
try {
    Connect-ExchangeOnline -UserPrincipalName $upn -ShowBanner:$false
    $reportTitle = "HistoricalSearch_$($startDate.ToString('MM-dd-yyyy'))_to_$($endDate.ToString('MM-dd-yyyy'))"

    Start-HistoricalSearch `
        -ReportType MessageTrace `
        -StartDate $startDate `
        -EndDate $endDate `
        -ReportTitle $reportTitle `
        -NotifyAddress $notifyAddress `
        -SenderAddress $senderAddress | Out-Null

    Write-Host ("Historical search started for {0} between {1:MM/dd/yyyy} and {2:MM/dd/yyyy}." -f $senderAddress, $startDate, $endDate)
    Write-Host "Notification will be sent to $notifyAddress when the report is ready."
}
finally {
    try { Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue }
    catch { Write-Verbose "Disconnect-ExchangeOnline ignored error: $($_.Exception.Message)" }
}
