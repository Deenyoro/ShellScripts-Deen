# Function to format the script
function Format-Script {
    param (
        [string]$InputScript,
        [string]$OutputScript
    )

    # Read the content of the script
    $content = Get-Content $InputScript

    # Initialize a new array to store the formatted content
    $formattedContent = @()

    # Process each line
    foreach ($line in $content) {
        if ($line -match "^function") {
            $formattedContent += ""
        }
        if ($line -match "^#") {
            $formattedContent += ""
        }
        $formattedContent += $line
    }

    # Write the formatted content to the output file
    $formattedContent | Out-File -FilePath $OutputScript -Encoding utf8

    Write-Output "Formatting complete. Output written to $OutputScript"
}

# Prompt user for the script name
$inputScript = Read-Host "Enter the name of the input script"
$outputScript = [System.IO.Path]::ChangeExtension($inputScript, "spacing" + [System.IO.Path]::GetExtension($inputScript))

# Call the function to format the script
Format-Script -InputScript $inputScript -OutputScript $outputScript
