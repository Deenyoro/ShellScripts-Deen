# Install-Shortcut.ps1

# Ensure the log directory exists
$LogDir = "C:\MDM"
if (-Not (Test-Path -Path $LogDir)) {
    try {
        New-Item -Path $LogDir -ItemType Directory -Force | Out-Null
    } catch {
        Write-Host "Failed to create log directory at $LogDir. Error: $_"
        Exit 1
    }
}

# Start logging
Start-Transcript -Path "$LogDir\helpdesk_install.log" -Append

# Define the shortcut properties
$ShortcutName = "EMAIL HELP@PLACEHOLDER.COM OR CALL 4125555555.url"
$TargetURL = "https://help.PLACEHOLDER.com"
$IconPath = "$PSScriptRoot\help-desk.ico"

# Function to log messages
function Log-Message {
    param (
        [string]$Message
    )
    Write-Output $Message
}

# Verify the icon file exists
if (-Not (Test-Path -Path $IconPath)) {
    Log-Message "Icon file not found at $IconPath. Exiting script."
    Stop-Transcript
    Exit 1
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

# Determine Desktop Path
$DesktopPath = [Environment]::GetFolderPath("Desktop")

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

try {
    if (-Not (Test-Path -Path $ShortcutPath)) {
        Log-Message "Creating Help Desk shortcut for user: $env:USERNAME"
        
        $Created = Create-UrlShortcut -ShortcutPath $ShortcutPath -URL $TargetURL -IconPath $IconPath
        
        if ($Created) {
            Log-Message "Help Desk shortcut created successfully for user: $env:USERNAME"
        } else {
            Log-Message "Failed to create Help Desk shortcut for user: $env:USERNAME"
        }
    } else {
        Log-Message "Help Desk shortcut already exists for user: $env:USERNAME. Skipping."
    }
} catch {
    Log-Message "An unexpected error occurred for user: $env:USERNAME. Error: $_"
}

# If script is run as admin, also create shortcut in Public Desktop
$IsAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if ($IsAdmin) {
    $PublicDesktopPath = "C:\Users\Public\Desktop"
    $PublicShortcutPath = Join-Path -Path $PublicDesktopPath -ChildPath $ShortcutName

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
}

# Stop logging
Stop-Transcript
