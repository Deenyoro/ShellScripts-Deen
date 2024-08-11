# This script assumes you are running it with administrative privileges

# Function to get secure password input
function Get-SecurePassword {
    param (
        [string]$prompt = "Enter password: "
    )
    $SecureString = Read-Host -Prompt $prompt -AsSecureString
    return $SecureString
}

# Function to get yes or no input
function Get-YesOrNo {
    param (
        [string]$prompt
    )
    do {
        $input = Read-Host -Prompt $prompt
    } while ($input -ne 'Y' -and $input -ne 'N')
    return $input
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

# Variables for domain credentials
$username = Read-Host -Prompt "Enter your domain username (format: DOMAIN\username)"
$password = Get-SecurePassword -Prompt "Enter your domain password"
$credential = New-Object System.Management.Automation.PSCredential($username, $password)

# Ask to create local admin account
$createLocalAdmin = Get-YesOrNo -prompt "Do you want to create a local admin account? (Y/N)"
if ($createLocalAdmin -eq 'Y') {
    $localAdminUsername = Get-InputWithDefault -prompt "Enter the new local admin username" -default "Admin"
    $localAdminPassword = Get-SecurePassword -Prompt "Enter the new local admin password (Default: Pass1!Word)"
    
    if ($localAdminPassword.Length -eq 0) {
        $localAdminPassword = ConvertTo-SecureString "Pass1!Word" -AsPlainText -Force
    }
    
    Write-Host "Creating local admin account..."
    $localAdminAccount = New-LocalUser -Name $localAdminUsername -Password $localAdminPassword -FullName "Local Administrator" -Description "Local admin account" -UserMayNotChangePassword -PasswordNeverExpires
    Add-LocalGroupMember -Group "Administrators" -Member $localAdminAccount.Name
    Write-Host "Local admin account created."
}

# Ask to remove Duo registry keys
$removeDuo = Get-YesOrNo -prompt "Do you want to remove Duo registry keys? (Y/N)"
if ($removeDuo -eq 'Y') {
    $duoRegistryPaths = @(
        "HKLM:\Software\Wow6432Node\Duo Security",
        "HKLM:\Software\Duo Security",
        "HKCU:\Software\Duo Security"
    )
    
    foreach ($path in $duoRegistryPaths) {
        if (Test-Path $path) {
            try {
                Remove-Item $path -Recurse -Force
                Write-Host "Removed Duo registry entry at $path"
            } catch {
                Write-Host "Failed to remove Duo registry entry at ${path}: $($_.Exception.Message)"
            }
        } else {
            Write-Host "No Duo registry entry found at $path"
        }
    }

    try {
        $duoRelatedEntries = Get-ChildItem -Path HKLM:\Software, HKCU:\Software -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.PSPath -like "*Duo*" }
        
        foreach ($entry in $duoRelatedEntries) {
            try {
                Remove-Item $entry.PSPath -Recurse -Force
                Write-Host "Removed Duo-related registry entry at $($entry.PSPath)"
            } catch {
                Write-Host "Failed to remove Duo-related registry entry at $($entry.PSPath): $($_.Exception.Message)"
            }
        }
    } catch {
        Write-Host "Failed to enumerate Duo-related registry entries: $($_.Exception.Message)"
    }
}

# Ask to unjoin the domain and restart
$unjoinDomain = Get-YesOrNo -prompt "Do you want to unjoin the domain and restart? (Y/N)"
if ($unjoinDomain -eq 'Y') {
    Write-Host "Unjoining from on-premises domain..."
    Remove-Computer -UnjoinDomainCredential $credential -Force -Restart

    # The system will restart after this command
    # The script must be restarted manually after reboot to continue
}
