# Prompt the user to enter the User Principal Name (UPN) with a default value
$UserPrincipalName = Read-Host "Enter the User Principal Name (UPN) [Default: ADMIN@DOMAIN.COM]"
if ([string]::IsNullOrEmpty($UserPrincipalName)) { $UserPrincipalName = "ADMIN@DOMAIN.COM" }

# Check if the ExchangeOnlineManagement module is installed and load it, or install it if not present
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Install-Module -Name ExchangeOnlineManagement -Force -AllowClobber
}
Import-Module ExchangeOnlineManagement

# Connect to Exchange Online
Connect-ExchangeOnline -UserPrincipalName $UserPrincipalName -ShowProgress $true

# Calculate the default first and last day of the previous month
$today = Get-Date
$firstDayOfPreviousMonth = $today.AddMonths(-1).Date.AddDays( - ($today.Day - 1))
$lastDayOfPreviousMonth = $today.AddDays(-$today.Day).Date

# Prompt the user for the start date with a default value, converting to DateTime
$startDateInput = Read-Host "Enter the start date (MM/DD/YYYY) [Default: $($firstDayOfPreviousMonth.ToString('MM/dd/yyyy'))]"
$startDate = if ([string]::IsNullOrEmpty($startDateInput)) { $firstDayOfPreviousMonth } else { [DateTime]::ParseExact($startDateInput, 'MM/dd/yyyy', $null) }

# Prompt the user for the end date with a default value, converting to DateTime
$endDateInput = Read-Host "Enter the end date (MM/DD/YYYY) [Default: $($lastDayOfPreviousMonth.ToString('MM/dd/yyyy'))]"
$endDate = if ([string]::IsNullOrEmpty($endDateInput)) { $lastDayOfPreviousMonth } else { [DateTime]::ParseExact($endDateInput, 'MM/dd/yyyy', $null) }

# Prompt the user for the sender address with a default
$senderAddress = Read-Host "Enter the sender address [Default: *@yandex.com]"
if ([string]::IsNullOrEmpty($senderAddress)) { $senderAddress = "*@yandex.com" }

# Prompt the user for the notify address with a default
$notifyAddress = Read-Host "Enter the notify address [Default: ADMIN@DOMAIN.COM]"
if ([string]::IsNullOrEmpty($notifyAddress)) { $notifyAddress = "ADMIN@DOMAIN.COM" }

# Start the historical search
Start-HistoricalSearch -ReportType MessageTrace -StartDate $startDate -EndDate $endDate -ReportTitle "HistoricalSearch_$($startDate.ToString('MM-dd-yyyy'))_to_$($endDate.ToString('MM-dd-yyyy'))" -NotifyAddress $notifyAddress -SenderAddress $senderAddress

Write-Output "Historical search started for emails from $senderAddress between $($startDate.ToString('MM/dd/yyyy')) and $($endDate.ToString('MM/dd/yyyy')). You will receive a notification at $notifyAddress when the report is ready."