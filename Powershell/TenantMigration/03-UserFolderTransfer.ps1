# Script must be run as Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Please run PowerShell as an Administrator."
    exit
}

function List-UserSIDs {
    Get-WmiObject -Class Win32_UserAccount | Select-Object Name, SID | Format-Table -AutoSize | Out-String
}

function Confirm-Step {
    param (
        [string]$message
    )
    $response = Read-Host "$message (y/n)"
    if ($response -ne 'y') {
        Write-Host "Operation cancelled."
        exit
    }
}

function Check-AndListUserProfiles {
    param (
        [string]$profilePath,
        [string]$profileType
    )
    if (-Not (Test-Path $profilePath)) {
        Write-Host "$profileType profile does not exist. Please select a valid profile."
        Write-Host "Available profiles in C:\Users:"
        Get-ChildItem -Path "C:\Users" -Directory | ForEach-Object {
            Write-Host $_.Name
        }
        return $false
    }
    return $true
}

$logDirectory = "C:\NACMigration"
$logFile = "$logDirectory\UserFolderTransferLog.txt"

# Ensure the log directory exists
if (-Not (Test-Path $logDirectory)) {
    New-Item -Path $logDirectory -ItemType Directory
}

# Initialize log file
Write-Output "Log initialized at $(Get-Date)" | Out-File -FilePath $logFile -Append

function Log-Message {
    param (
        [string]$message
    )
    Write-Output "$message" | Out-File -FilePath $logFile -Append
    Write-Host "$message"
}

function Get-UserProfileDetails {
    # List all user profiles in the C:\Users directory
    Write-Host "Available profiles in C:\Users:"
    Get-ChildItem -Path "C:\Users" -Directory | ForEach-Object {
        Write-Host $_.Name
    }

    # Display User SIDs
    Write-Host "Displaying user SIDs:"
    $userSIDs = List-UserSIDs
    Write-Host $userSIDs

    $validProfiles = $false
    while (-not $validProfiles) {
        # Get user input for old and new profile names and new profile SID
        $oldProfileName = Read-Host "Enter the old/source profile name"
        $newProfileName = Read-Host "Enter the new/target Azure AD profile name"
        $newProfileSID = Read-Host "Enter the SID for the new/target profile"

        # Define source and target user profiles based on user input
        $sourceProfile = "C:\Users\$oldProfileName"
        $targetProfile = "C:\Users\$newProfileName"

        # Check existence of source and target profiles
        $sourceExists = Check-AndListUserProfiles $sourceProfile "Source"
        $targetExists = Check-AndListUserProfiles $targetProfile "Target"

        if ($sourceExists -and $targetExists) {
            $validProfiles = $true
        }
    }

    return @($oldProfileName, $newProfileName, $newProfileSID, $sourceProfile, $targetProfile)
}

$details = Get-UserProfileDetails
$oldProfileName = $details[0]
$newProfileName = $details[1]
$newProfileSID = $details[2]
$sourceProfile = $details[3]
$targetProfile = $details[4]

# Log entered details
Log-Message "You have entered the following details:"
Log-Message "Old/source profile name: $oldProfileName"
Log-Message "New/target profile name: $newProfileName"
Log-Message "New/target profile SID: $newProfileSID"
Log-Message "Source profile path: $sourceProfile"
Log-Message "Target profile path: $targetProfile"
Log-Message "Warning: This script moves or copies files based on your choice and is irreversible. Use at your own risk."

# Confirm before proceeding
Confirm-Step "Do you want to proceed with the profile changes?"

# Ask if the user wants to change permissions on the source profile
$changeSourcePerms = Read-Host "Do you want to change permissions on the old/source profile? (y/n)"
if ($changeSourcePerms -eq 'y') {
    Log-Message "Setting permissions for *$newProfileSID on $sourceProfile..."
    icacls $sourceProfile /grant ("*${newProfileSID}:(OI)(CI)F") /T
}

# Ask if the user wants to change permissions on the target profile
$changeTargetPerms = Read-Host "Do you want to change permissions on the new/target profile? (y/n)"
if ($changeTargetPerms -eq 'y') {
    Log-Message "Setting permissions for *$newProfileSID on $targetProfile..."
    icacls $targetProfile /grant ("*${newProfileSID}:(OI)(CI)F") /T
}

# Ask if the user wants to move or copy the profile data
$operation = Read-Host "Do you want to move (m) or copy (c) the profile data?"
if ($operation -eq 'm') {
    Confirm-Step "Confirm moving all contents from $sourceProfile to $targetProfile"
    Move-Item -Path "$sourceProfile\*" -Destination $targetProfile -Force
} elseif ($operation -eq 'c') {
    Confirm-Step "Confirm copying all contents from $sourceProfile to $targetProfile"
    Copy-Item -Path "$sourceProfile\*" -Destination $targetProfile -Recurse -Force
} else {
    Log-Message "Invalid operation selected. Operation cancelled."
}

# Ask if the user wants to reset Windows Hello
$resetWindowsHello = Read-Host "Do you want to reset Windows Hello? (y/n)"
if ($resetWindowsHello -eq 'y') {
    # Handle Windows Hello reset
    $ngcPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"
    $services = @("VaultSvc", "UserManager", "WbioSrvc")
    foreach ($service in $services) {
        Stop-Service -Name $service
        Log-Message "Stopped service: $service"
    }

    takeown /f $ngcPath /r /d Y
    icacls $ngcPath /grant ("*${newProfileSID}:(F)") /t /c
    Remove-Item -Path $ngcPath -Recurse -Force -ErrorAction SilentlyContinue
    Log-Message "Windows Hello reset: Ngc folder modified."

    foreach ($service in $services) {
        Start-Service -Name $service
        Log-Message "Restarted service: $service"
    }
}

# Ask if the user wants to rebuild the Start Menu
$rebuildStartMenu = Read-Host "Do you want to rebuild the Start Menu? (y/n)"
if ($rebuildStartMenu -eq 'y') {
    # Rebuild the Start Menu
    Get-AppXPackage -AllUsers | Foreach {Add-AppxPackage -DisableDevelopmentMode -Register "$($_.InstallLocation)\AppXManifest.xml"}
}

# Final confirmation before restart
$restart = Read-Host "Operation complete. Do you want to restart the PC now? (y/n)"
if ($restart -eq 'y') {
    Restart-Computer
} else {
    Log-Message "Restart aborted by the user."
}
