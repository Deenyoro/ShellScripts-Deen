# Uninstall-WMIC.ps1
# Script to remove WMIC and clean up marker file

# Enable strict mode for better error handling
Set-StrictMode -Version Latest

# Define Variables
$capabilityName = "WMIC~~~~"
$markerFilePath = "C:\MDM\wmicinstalled.txt"
$dismRemoveCommand = "DISM /Online /Remove-Capability /CapabilityName:$capabilityName"

# Function to log messages with timestamps
function Write-Log {
    param (
        [string]$Message
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Output "$timestamp - $Message"
}

# Function to check if WMIC is installed
function Is-WMICInstalled {
    $wmicCapability = Get-WindowsCapability -Online -Name $capabilityName -ErrorAction SilentlyContinue
    if ($wmicCapability -and $wmicCapability.State -eq "Installed") {
        return $true
    } else {
        return $false
    }
}

# Function to uninstall WMIC using DISM
function Uninstall-WMIC_Dism {
    try {
        Write-Log "Attempting to uninstall WMIC using DISM..."
        # Execute DISM command
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $dismRemoveCommand" -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Log "DISM command executed successfully."
            return $true
        } else {
            Write-Log "DISM command failed with Exit Code: $($process.ExitCode)"
            return $false
        }
    } catch {
        Write-Log "DISM command failed: $_"
        return $false
    }
}

# Function to delete the marker file
function Delete-MarkerFile {
    try {
        if (Test-Path $markerFilePath) {
            Remove-Item -Path $markerFilePath -Force
            Write-Log "Deleted marker file at $markerFilePath."
        } else {
            Write-Log "Marker file does not exist. No action needed."
        }
    } catch {
        Write-Log "Failed to delete marker file: $_"
    }
}

# Main Execution Flow
Write-Log "----- Starting WMIC Uninstallation Script -----"

# Check if WMIC is installed
if (Is-WMICInstalled) {
    Write-Log "WMIC is installed. Proceeding with uninstallation..."
    $uninstallResult = Uninstall-WMIC_Dism
    if ($uninstallResult) {
        Write-Log "WMIC uninstallation command executed. Verifying..."
    } else {
        Write-Log "Failed to uninstall WMIC using DISM."
    }
} else {
    Write-Log "WMIC is not installed. No uninstallation needed."
}

# Verify uninstallation
$wmicPathExists = Test-Path "C:\Windows\System32\wbem\wmic.exe"
$wmicCapabilityState = Is-WMICInstalled

if (-not ($wmicPathExists -or $wmicCapabilityState)) {
    Write-Log "WMIC uninstallation verified."
    # Delete marker file
    Delete-MarkerFile
} else {
    Write-Log "WMIC uninstallation verification failed."
}

Write-Log "----- WMIC Uninstallation Script Completed -----"
