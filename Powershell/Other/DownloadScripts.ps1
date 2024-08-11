# Create the directory if it does not exist
$directoryPath = "C:\PSScripts"
if (-not (Test-Path $directoryPath)) {
    New-Item -ItemType Directory -Path $directoryPath
}

# Define URLs and destination file paths
$downloads = @{
    "https://pastebin.com/raw/SdVbCdZy" = "$directoryPath\ManageExecutionPolicy.bat"
    "RAWLINK" = "$directoryPath\.ps1"
    "RAWLINK" = "$directoryPath\.ps1"
    "RAWLINK" = "$directoryPath\.ps1"
    "RAWLINK" = "$directoryPath\.ps1"
}

# Download each file
foreach ($url in $downloads.Keys) {
    Invoke-WebRequest -Uri $url -OutFile $downloads[$url]
}

# Output the files that have been downloaded
"Downloaded files to ${directoryPath}:"
$downloads.Values