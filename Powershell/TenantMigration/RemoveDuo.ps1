# This script assumes you are running it with administrative privileges

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

# Ask to remove Duo registry keys
$removeDuo = Get-YesOrNo -Prompt "Do you want to remove Duo registry keys? (Y/N)"
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
