# Manage-WMIC.ps1
# Script to ensure WMIC is installed and operational

# Enable strict mode for better error handling
Set-StrictMode -Version Latest

# Define Variables
$capabilityName = "WMIC~~~~"
$markerFilePath = "C:\MDM\wmic_install_complete.txt"
$logFilePath = "C:\MDM\wmic_install.log"
$dismCommand = "DISM /Online /Add-Capability /CapabilityName:$capabilityName"

# Function to log messages with timestamps
function Write-Log {
    param (
        [string]$Message,
        [string]$Severity = "INFO"
    )
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logEntry = "$timestamp [$Severity] $Message"

    # Ensure the log directory exists
    $logDir = Split-Path $logFilePath -Parent
    if (-not (Test-Path $logDir)) {
        New-Item -Path $logDir -ItemType Directory -Force | Out-Null
    }

    # Write log entry to file
    $logEntry | Out-File -FilePath $logFilePath -Append -Encoding UTF8

    # Optionally output to console (remove if not needed)
    Write-Output $logEntry
}

# Function to check if WMIC is installed and operational
function Verify-WMIC {
    # Check if wmic.exe exists
    $wmicPath = "C:\Windows\System32\wbem\WMIC.exe"
    $wmicExists = Test-Path $wmicPath

    if ($wmicExists) {
        try {
            # Test WMIC functionality
            $wmicTest = & $wmicPath /?
            if ($wmicTest) {
                Write-Log "WMIC is installed and operational."
                return $true
            } else {
                Write-Log "WMIC executable found but not operational." "ERROR"
                return $false
            }
        } catch {
            Write-Log "Error executing WMIC: $_" "ERROR"
            return $false
        }
    } else {
        Write-Log "WMIC executable not found." "ERROR"
        return $false
    }
}

# Function to install WMIC using Add-WindowsCapability
function Install-WMIC {
    try {
        Write-Log "Attempting to install WMIC using Add-WindowsCapability..."
        Add-WindowsCapability -Online -Name $capabilityName -ErrorAction Stop | Out-Null
        Write-Log "Add-WindowsCapability command executed successfully."
        return $true
    } catch {
        Write-Log "Add-WindowsCapability failed: $_" "ERROR"
        return $false
    }
}

# Function to install WMIC using DISM
function Install-WMIC_Dism {
    try {
        Write-Log "Attempting to install WMIC using DISM..."
        # Execute DISM command
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $dismCommand" -Wait -NoNewWindow -PassThru
        if ($process.ExitCode -eq 0) {
            Write-Log "DISM command executed successfully."
            return $true
        } else {
            Write-Log "DISM command failed with Exit Code: $($process.ExitCode)" "ERROR"
            return $false
        }
    } catch {
        Write-Log "DISM command failed: $_" "ERROR"
        return $false
    }
}

# Function to create the marker file
function Create-MarkerFile {
    try {
        if (-not (Test-Path $markerFilePath)) {
            # Ensure the directory exists
            $markerDir = Split-Path $markerFilePath -Parent
            if (-not (Test-Path $markerDir)) {
                New-Item -Path $markerDir -ItemType Directory -Force | Out-Null
                Write-Log "Created directory $markerDir."
            }
            New-Item -Path $markerFilePath -ItemType File -Force | Out-Null
            Write-Log "Created marker file at $markerFilePath."
        } else {
            Write-Log "Marker file already exists at $markerFilePath."
        }
    } catch {
        Write-Log "Failed to create marker file: $_" "ERROR"
    }
}

# Function to delete the marker file
function Delete-MarkerFile {
    try {
        if (Test-Path $markerFilePath) {
            Remove-Item -Path $markerFilePath -Force
            Write-Log "Deleted marker file at $markerFilePath."
        } else {
            Write-Log "Marker file does not exist at $markerFilePath."
        }
    } catch {
        Write-Log "Failed to delete marker file: $_" "ERROR"
    }
}

# Main Execution Flow
Write-Log "----- Starting WMIC Management Script -----"

# Check if WMIC is already installed and operational
if (Verify-WMIC) {
    Write-Log "WMIC is already installed and operational."
    # Create marker file if not already present
    Create-MarkerFile
} else {
    Write-Log "WMIC is not installed or not operational. Proceeding with installation..."

    # Attempt installation using Add-WindowsCapability
    $installResult = Install-WMIC

    if (-not $installResult) {
        Write-Log "Initial installation attempt failed. Trying DISM command..."
        $installResult = Install-WMIC_Dism
    }

    if ($installResult) {
        Write-Log "Installation command executed. Verifying installation..."
        if (Verify-WMIC) {
            Write-Log "WMIC installation verified successfully."
            # Create marker file
            Create-MarkerFile
        } else {
            Write-Log "WMIC verification failed after installation." "ERROR"
            # Delete marker file if it exists
            Delete-MarkerFile
        }
    } else {
        Write-Log "Both installation methods failed. Exiting script." "ERROR"
        # Delete marker file if it exists
        Delete-MarkerFile
    }
}

Write-Log "----- WMIC Management Script Completed -----"
