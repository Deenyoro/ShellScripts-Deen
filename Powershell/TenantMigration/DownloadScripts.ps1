# Create the directory if it does not exist
$directoryPath = "C:\NACMigration"
if (-not (Test-Path $directoryPath)) {
    New-Item -ItemType Directory -Path $directoryPath
}

# Define URLs and destination file paths
$downloads = @{
    "https://pastebin.com/raw/SdVbCdZy" = "$directoryPath\ManageExecutionPolicy.bat"
    "https://pastebin.com/raw/yjwLPL8Y" = "$directoryPath\AutoPilotDomain.ps1"
    "https://pastebin.com/raw/DumyUqFu" = "$directoryPath\ManualWindowsHelloReset.ps1"
    "https://pastebin.com/raw/8kL4yhRd" = "$directoryPath\UnjoinDomainAddLocalAdmin.ps1"
    "https://pastebin.com/raw/u9aTuAp4" = "$directoryPath\UserFolderTransfer.ps1"
}

# Download each file
foreach ($url in $downloads.Keys) {
    Invoke-WebRequest -Uri $url -OutFile $downloads[$url]
}

# Output the files that have been downloaded
"Downloaded files to ${directoryPath}:"
$downloads.Values