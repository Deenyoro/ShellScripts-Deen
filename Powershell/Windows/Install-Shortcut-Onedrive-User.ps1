# Install-UserShortcut.ps1

# -------------------------------
# Configuration
# -------------------------------

# Define the log directory and file
$LogDir = "C:\MDM"
$LogFile = Join-Path -Path $LogDir -ChildPath "user_helpdesk_install.log"

# Define the shortcut properties
$ShortcutName = "EMAIL HELP@PLACEHOLDER OR CALL 4125555555.url"
$TargetURL = "https://help.PLACEHOLDER.com"
$IconPath = "$PSScriptRoot\help-desk.ico"

# -------------------------------
# Functions
# -------------------------------

# Function to log messages
function Log-Message {
    param (
        [string]$Message
    )
    Write-Output $Message
}

# Function to create a .url shortcut
function Create-UrlShortcut {
    param (
        [string]$ShortcutPath,
        [string]$URL,
        [string]$IconPath
    )
    try {
        $ShortcutContent = "[InternetShortcut]`nURL=$URL`nIconFile=$IconPath`nIconIndex=0"
        Set-Content -Path $ShortcutPath -Value $ShortcutContent -Encoding ASCII
        return $true
    } catch {
        Log-Message "Failed to create URL shortcut at $ShortcutPath. Error: $_"
        return $false
    }
}

# -------------------------------
# Script Execution
# -------------------------------

# Ensure the log directory exists
if (-Not (Test-Path -Path $LogDir)) {
    try {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    } catch {
        Write-Host "Failed to create log directory at $LogDir. Error: $_"
        Exit 1
    }
}

# Start logging
Start-Transcript -Path $LogFile -Append

Log-Message "Starting User Desktop shortcut installation."

# Verify the icon file exists
if (-Not (Test-Path -Path $IconPath)) {
    Log-Message "Icon file not found at $IconPath. Exiting script."
    Stop-Transcript
    Exit 1
}

# Determine Desktop Path
$DesktopPath = [Environment]::GetFolderPath("Desktop")

# Check if Desktop path is redirected to OneDrive
# Typically, if OneDrive is set to backup Desktop, the path includes 'OneDrive'
$IsOneDriveDesktop = $DesktopPath -like "*OneDrive*"

if ($IsOneDriveDesktop) {
    Log-Message "Detected OneDrive Desktop path at $DesktopPath."
} else {
    Log-Message "OneDrive Desktop path not detected. Using standard Desktop at $DesktopPath."
}

# Verify Desktop path exists
if (-Not (Test-Path -Path $DesktopPath)) {
    Log-Message "Desktop path not found at $DesktopPath. Attempting to create it."
    try {
        New-Item -Path $DesktopPath -ItemType Directory -Force | Out-Null
        Log-Message "Created Desktop folder at $DesktopPath."
    } catch {
        Log-Message "Failed to create Desktop folder at $DesktopPath. Error: $_"
        Stop-Transcript
        Exit 1
    }
}

# Define the Shortcut Path
$ShortcutPath = Join-Path -Path $DesktopPath -ChildPath $ShortcutName

# Create the shortcut if it doesn't exist
try {
    if (-Not (Test-Path -Path $ShortcutPath)) {
        Log-Message "Creating Help Desk shortcut for user: $env:USERNAME"

        $Created = Create-UrlShortcut -ShortcutPath $ShortcutPath -URL $TargetURL -IconPath $IconPath

        if ($Created) {
            Log-Message "Help Desk shortcut created successfully on user Desktop."
        } else {
            Log-Message "Failed to create Help Desk shortcut on user Desktop."
        }
    } else {
        Log-Message "Help Desk shortcut already exists on user Desktop. Skipping."
    }
} catch {
    Log-Message "An unexpected error occurred while creating the User Desktop shortcut. Error: $_"
}

# Stop logging
Stop-Transcript

Log-Message "User Desktop shortcut installation completed."
