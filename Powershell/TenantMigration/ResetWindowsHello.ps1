# Script to Reset Windows Hello
# Must be run as Administrator

# Check if the script is running as an Administrator
if (-NOT ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))
{
    Write-Host "Please run PowerShell as an Administrator."
    exit
}

# Define the path to the Ngc folder
$ngcPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Local\Microsoft\Ngc"

# Define services related to authentication that need to be stopped and restarted
$services = @("VaultSvc", "UserManager", "WbioSrvc")

# Stop services
foreach ($service in $services) {
    $serviceStatus = Get-Service -Name $service
    if ($serviceStatus.Status -eq 'Running') {
        Stop-Service -Name $service
        Write-Host "Stopped service: $service"
    }
}

# Take ownership and modify permissions of the Ngc folder
takeown /f $ngcPath /r /d Y
icacls $ngcPath /grant "${env:USERNAME}:(F)" /t /c

# Attempt to remove the Ngc directory and its contents
if (Test-Path $ngcPath) {
    try {
        Remove-Item -Path $ngcPath -Recurse -Force
        Write-Host "Windows Hello has been reset: Ngc folder removed successfully."
    } catch {
        Write-Host "Failed to remove Ngc folder: $($_.Exception.Message)"
    }
} else {
    Write-Host "Ngc folder does not exist, no need to remove."
}

# Restart services
foreach ($service in $services) {
    Start-Service -Name $service
    Write-Host "Restarted service: $service"
}

Write-Host "Script execution complete. Please check Windows Hello settings."