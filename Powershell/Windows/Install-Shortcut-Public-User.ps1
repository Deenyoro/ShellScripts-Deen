# Install-PublicShortcut.ps1

# -------------------------------
# Configuration
# -------------------------------

# Define the log directory and file
$LogDir = "C:\MDM"
$LogFile = Join-Path -Path $LogDir -ChildPath "public_helpdesk_install.log"

# Define the shortcut properties
$ShortcutName = "EMAIL HELP@PLACEHOLDER.COM OR CALL 4125555555.url"
$TargetURL = "https://help.PLACEHOLDER.com"
$IconPath = "$PSScriptRoot\help-desk.ico"

# Define the Public Desktop path
$PublicDesktopPath = "C:\Users\Public\Desktop"
$PublicShortcutPath = Join-Path -Path $PublicDesktopPath -ChildPath $ShortcutName

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

Log-Message "Starting Public Desktop shortcut installation."

# Verify the icon file exists
if (-Not (Test-Path -Path $IconPath)) {
    Log-Message "Icon file not found at $IconPath. Exiting script."
    Stop-Transcript
    Exit 1
}

# Verify Public Desktop path exists
if (-Not (Test-Path -Path $PublicDesktopPath)) {
    Log-Message "Public Desktop path not found at $PublicDesktopPath. Attempting to create it."
    try {
        New-Item -Path $PublicDesktopPath -ItemType Directory -Force | Out-Null
        Log-Message "Created Public Desktop folder at $PublicDesktopPath."
    } catch {
        Log-Message "Failed to create Public Desktop folder at $PublicDesktopPath. Error: $_"
        Stop-Transcript
        Exit 1
    }
}

# Create the shortcut if it doesn't exist
try {
    if (-Not (Test-Path -Path $PublicShortcutPath)) {
        Log-Message "Creating Help Desk shortcut in Public Desktop."

        $Created = Create-UrlShortcut -ShortcutPath $PublicShortcutPath -URL $TargetURL -IconPath $IconPath

        if ($Created) {
            Log-Message "Help Desk shortcut created successfully in Public Desktop."
        } else {
            Log-Message "Failed to create Help Desk shortcut in Public Desktop."
        }
    } else {
        Log-Message "Help Desk shortcut already exists in Public Desktop. Skipping."
    }
} catch {
    Log-Message "An unexpected error occurred while creating the Public Desktop shortcut. Error: $_"
}

# Stop logging
Stop-Transcript

Log-Message "Public Desktop shortcut installation completed."
