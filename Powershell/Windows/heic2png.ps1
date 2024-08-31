# Check if ImageMagick is installed
$imagemagickInstalled = Get-Command magick -ErrorAction SilentlyContinue

if (-not $imagemagickInstalled) {
    Write-Host "ImageMagick is not installed. Installing ImageMagick..."
    winget install ImageMagick.ImageMagick.Q16
} else {
    Write-Host "ImageMagick is already installed."
}

# Prompt user for directory
$directory = Read-Host "Enter the directory containing HEIC files (press Enter to use the current directory)"

# Use current directory if none specified
if ([string]::IsNullOrWhiteSpace($directory)) {
    $directory = Get-Location
}

# Create a subdirectory for the converted files
$outputDirectory = Join-Path -Path $directory -ChildPath "heic_to_png"
if (-not (Test-Path -Path $outputDirectory)) {
    New-Item -ItemType Directory -Path $outputDirectory | Out-Null
}

# Convert HEIC files to PNG and save them in the output directory with verbosity
Get-ChildItem -Path $directory -Filter *.heic | ForEach-Object {
    $outputFile = Join-Path -Path $outputDirectory -ChildPath "$($_.BaseName).png"
    Write-Host "Converting $($_.Name) to PNG..."
    magick $_.FullName $outputFile
}

Write-Host "Conversion completed. Files are saved in $outputDirectory"
