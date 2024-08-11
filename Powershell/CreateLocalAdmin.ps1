# This script assumes you are running it with administrative privileges
# Function to get secure password input
function Get-SecurePassword {
    param (
        [string]$prompt = "Enter password: ",
        [string]$default = "Pass1Word"
    )
    $input = Read-Host -Prompt $prompt
    if ($input -eq "") {
        Write-Host "No password entered, using default password: Pass1Word"
        $SecureString = ConvertTo-SecureString $default -AsPlainText -Force
    } else {
        $SecureString = $input | ConvertTo-SecureString -AsPlainText -Force
    }
    return $SecureString
}
# Function to get input with a default value
function Get-InputWithDefault {
    param (
        [string]$prompt,
        [string]$default
    )
    $input = Read-Host -Prompt "$prompt (Default: $default)"
    if ($input -eq "") {
        return $default
    }
    return $input
}
# Ask to create local admin account
$createLocalAdmin = Read-Host -Prompt "Do you want to create a local admin account? (Y/N)"
if ($createLocalAdmin -eq 'Y') {
    $localAdminUsername = Get-InputWithDefault -prompt "Enter the new local admin username" -default "Admin"
    $localAdminPassword = Get-SecurePassword -Prompt "Enter the new local admin password"
Write-Host "Creating local admin account..."
    $localAdminAccount = New-LocalUser -Name $localAdminUsername -Password $localAdminPassword -FullName "Local Administrator" -Description "Local admin account" -UserMayNotChangePassword -PasswordNeverExpires
    Add-LocalGroupMember -Group "Administrators" -Member $localAdminAccount.Name
    Write-Host "Local admin account created."
# Ask to enable RDP for the admin account
    $enableRDP = Read-Host -Prompt "Do you want to enable RDP for this admin account? (Y/N)"
    if ($enableRDP -eq 'Y') {
        Set-ItemProperty -Path 'HKLM:\System\CurrentControlSet\Control\Terminal Server' -name "fDenyTSConnections" -Value 0
        Enable-NetFirewallRule -DisplayGroup "Remote Desktop"
        Write-Host "RDP has been enabled for the account: $localAdminUsername"
    }
}
