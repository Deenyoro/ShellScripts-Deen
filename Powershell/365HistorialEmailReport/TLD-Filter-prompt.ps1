# List all files in the current directory
Write-Host "Listing all files in the current directory:"
Get-ChildItem -File | ForEach-Object { Write-Host $_.Name }

# Prompt for the input file path
$inputFile = Read-Host "Enter the input file path (or file name if it's in the same folder as this script)"
$outputFile = Read-Host "Enter the output file path (optional, press Enter to use default name)"

# Add .csv extension if not present
if (-not $inputFile.EndsWith(".csv")) {
    $inputFile += ".csv"
}

# Handle relative paths by getting the full path
if (-not [System.IO.Path]::IsPathRooted($inputFile)) {
    $inputFile = [System.IO.Path]::Combine((Get-Location).Path, $inputFile)
}

# Define the searchable columns
$searchableColumns = @(
    "origin_timestamp_utc",
    "sender_address",
    "recipient_status",
    "message_subject"
)

# List the searchable columns
Write-Host "Searchable columns:"
$searchableColumns | ForEach-Object { Write-Host $_ }

# Prompt for the column to search
$searchColumn = Read-Host "Enter the column to search (press Enter for default 'recipient_status')"
if (-not $searchColumn -or -not $searchableColumns -contains $searchColumn) {
    $searchColumn = "recipient_status"
}

# Prompt for the recipient status to filter
$filterStatus = Read-Host "Enter the $searchColumn to filter (e.g., '.ru'; press Enter for default '.ru')"
if (-not $filterStatus) {
    $filterStatus = ".ru"
    $defaultOutputName = "FilteredRU_" + [System.IO.Path]::GetFileNameWithoutExtension($inputFile) + ".csv"
}
else {
    $defaultOutputName = "Filtered_" + [System.IO.Path]::GetFileNameWithoutExtension($inputFile) + ".csv"
}

# Set the default output file name if not provided
if (-not $outputFile) {
    $outputFile = $defaultOutputName
}

# Handle relative paths by getting the full path for the output file
if (-not [System.IO.Path]::IsPathRooted($outputFile)) {
    $outputFile = [System.IO.Path]::Combine((Get-Location).Path, $outputFile)
}

# Define the columns to keep
$columnsToKeep = @(
    "origin_timestamp_utc",
    "sender_address",
    "recipient_status",
    "message_subject",
    "total_bytes",
    "message_id",
    "network_message_id",
    "original_client_ip",
    "directionality",
    "connector_id",
    "delivery_priority"
)

# Create a function to clean null characters
function Remove-NullChars {
    param ($string)
    return $string -replace "`0", ""
}

# Create a function to handle each line of the CSV file
function Process-CSVLine {
    param ($line)
    
    # Split the line into columns
    $columns = $line -split '","'
 
    # Create a PSCustomObject to hold the column values
    $obj = [PSCustomObject]@{
        origin_timestamp_utc = $columns[0] -replace '"', ''
        sender_address       = $columns[1] -replace '"', ''
        recipient_status     = $columns[2] -replace '"', '' -replace '##', ' '
        message_subject      = $columns[3] -replace '"', ''
        total_bytes          = $columns[4] -replace '"', ''
        message_id           = $columns[5] -replace '"', ''
        network_message_id   = $columns[6] -replace '"', ''
        original_client_ip   = $columns[7] -replace '"', ''
        directionality       = $columns[8] -replace '"', ''
        connector_id         = $columns[9] -replace '"', ''
        delivery_priority    = $columns[10] -replace '"', ''
    }

    return $obj
}

# Initialize an array to hold the filtered data
$filteredData = @()

# Read the CSV file line by line
Get-Content -Path $inputFile | ForEach-Object {
    $line = $_

    # Clean null characters
    $cleanLine = Remove-NullChars $line

    # Process the line into an object
    $obj = Process-CSVLine $cleanLine

    # Filter rows where the specified column contains the specified filter status
    if ($obj.$searchColumn -match [regex]::Escape($filterStatus)) {
        $filteredData += $obj
    }
}

# Sort the data by origin_timestamp_utc
$sortedData = $filteredData | Sort-Object -Property origin_timestamp_utc

# Export the sorted and filtered data to a new CSV file
$sortedData | Select-Object $columnsToKeep | Export-Csv -Path $outputFile -NoTypeInformation
