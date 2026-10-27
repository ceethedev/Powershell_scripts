[CmdletBinding()] # Enables standard PowerShell parameter binding and common command options.
param( # Declares the script's command-line parameters.
    [Parameter(Mandatory)] # Requires the caller to provide the input CSV path or paths.
    [string[]]$Path, # Holds one or more files containing app-usage intervals.

    [string]$OutputPath # Optionally specifies where to write the summary CSV.
) # Ends the parameter declaration.

$ErrorActionPreference = 'Stop' # Makes unhandled command errors terminate the script.

$requiredColumns = @( # Lists the columns that each input CSV must provide.
    'ComputerName', # Identifies the computer that produced the interval.
    'UserName', # Identifies the logged-in user for the interval.
    'State', # Distinguishes active app time from idle time.
    'ProcessName', # Identifies the foreground application process.
    'StartTime', # Provides the interval's start timestamp.
    'EndTime', # Provides the interval's end timestamp.
    'DurationSeconds' # Provides the recorded interval duration.
) # Ends the required-column list.
$rows = foreach ($file in (Get-ChildItem -Path $Path -File -ErrorAction Stop)) { # Resolves each supplied input file and processes it.
    $csvRows = Import-Csv -LiteralPath $file.FullName # Reads the current CSV without wildcard interpretation of its resolved path.
    if ($csvRows.Count -eq 0) { # Checks whether this file contains any data rows.
        continue # Skips an empty CSV and moves to the next file.
    } # Ends the empty-file check.

    $missingColumns = @($requiredColumns | Where-Object { $_ -notin $csvRows[0].PSObject.Properties.Name }) # Finds required columns absent from the CSV header.
    if ($missingColumns.Count -gt 0) { # Checks whether the input schema is incomplete.
        throw "CSV '$($file.FullName)' is missing required column(s): $($missingColumns -join ', ')." # Reports the file and missing headers.
    } # Ends input schema validation.

    foreach ($row in $csvRows) { # Processes each interval row in the current CSV.
        if ($row.State -ne 'Active') { # Checks whether this interval represents idle time.
            continue # Excludes idle intervals from app-use totals.
        } # Ends the active-state check.

        $parsedStart = [datetimeoffset]::MinValue # Initializes a typed value for parsing the start timestamp.
        if (-not [datetimeoffset]::TryParse($row.StartTime, [ref]$parsedStart)) { # Parses the start timestamp while preserving its UTC offset.
            throw "CSV '$($file.FullName)' contains an invalid StartTime value: '$($row.StartTime)'." # Reports malformed start-time data.
        } # Ends start-timestamp validation.

        $parsedEnd = [datetimeoffset]::MinValue # Initializes a typed value for parsing the end timestamp.
        if (-not [datetimeoffset]::TryParse($row.EndTime, [ref]$parsedEnd)) { # Parses the end timestamp while preserving its UTC offset.
            throw "CSV '$($file.FullName)' contains an invalid EndTime value: '$($row.EndTime)'." # Reports malformed end-time data.
        } # Ends end-timestamp validation.
        if ($parsedEnd -lt $parsedStart) { # Ensures the interval ends no earlier than it starts.
            throw "CSV '$($file.FullName)' contains an EndTime before StartTime." # Rejects an interval with reversed timestamps.
        } # Ends chronological-order validation.

        $duration = 0.0 # Initializes a numeric variable for validating the CSV duration field.
        if (-not [double]::TryParse( # Attempts culture-independent numeric validation of the duration field.
            $row.DurationSeconds, # Supplies the duration text from this CSV row.
            [System.Globalization.NumberStyles]::Float, # Allows standard floating-point number formatting.
            [System.Globalization.CultureInfo]::InvariantCulture, # Avoids differences in decimal separators between locales.
            [ref]$duration # Stores the parsed numeric value in the duration variable.
        )) { # Runs this block if duration validation fails.
            throw "CSV '$($file.FullName)' contains an invalid DurationSeconds value: '$($row.DurationSeconds)'." # Reports malformed duration data.
        } # Ends duration validation.

        $duration = ($parsedEnd - $parsedStart).TotalSeconds # Recomputes duration from timestamps to keep the totals consistent.
        [pscustomobject]@{ # Creates a normalized active interval record for summary grouping.
            Date            = $parsedStart.ToString('yyyy-MM-dd') # Uses the start timestamp's date as the local reporting day.
            ComputerName    = $row.ComputerName # Carries the source computer into the summary input.
            UserName        = $row.UserName # Carries the source user into the summary input.
            ProcessName     = if ([string]::IsNullOrWhiteSpace($row.ProcessName)) { 'Unknown' } else { $row.ProcessName } # Supplies a readable fallback for missing process names.
            DurationSeconds = $duration # Stores the validated duration computed from the timestamps.
        } # Ends construction of the normalized interval record.
    } # Ends processing of this file's rows.
} # Ends reading and normalizing all input files.

$summary = @( # Collects the grouped app-use totals into an array.
    $rows | # Passes normalized active intervals to the grouping pipeline.
        Group-Object Date, ComputerName, UserName, ProcessName | # Groups intervals by day, computer, user, and process.
        ForEach-Object { # Computes totals and output fields for each group.
            $first = $_.Group[0] # Reads a representative row for the group's shared identifiers.
            $totalSeconds = ($_.Group | Measure-Object -Property DurationSeconds -Sum).Sum # Adds the durations for all intervals in this group.
            [pscustomobject][ordered]@{ # Creates a summary record with a stable column order.
                Date               = $first.Date # Adds the reporting day.
                ComputerName       = $first.ComputerName # Adds the computer identifier.
                UserName           = $first.UserName # Adds the user identifier.
                ProcessName        = $first.ProcessName # Adds the app process name.
                TotalActiveSeconds = [math]::Round($totalSeconds, 1) # Rounds the total seconds to one decimal place.
                TotalActiveHours   = [math]::Round($totalSeconds / 3600, 2) # Converts seconds to hours and rounds to two decimals.
                IntervalCount      = $_.Count # Counts how many active intervals contributed to this total.
            } # Ends creation of the grouped summary record.
        } | # Passes all grouped records to the sorting command.
        Sort-Object Date, ComputerName, UserName, ProcessName # Sorts rows consistently for easier review.
) # Ends construction of the complete summary array.

if ($summary.Count -eq 0) { # Checks whether any active intervals were found.
    throw 'No active app intervals were found in the input CSV file(s).' # Prevents silently producing an empty summary.
} # Ends the empty-summary check.

if ([string]::IsNullOrWhiteSpace($OutputPath)) { # Checks whether the caller omitted an output path.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss' # Generates a timestamp to make the default output name unique.
    $OutputPath = Join-Path (Get-Location) "AppUsage-Summary-$stamp.csv" # Places the default summary in the current directory.
} # Ends default output-path selection.
else { # Handles an explicitly supplied output path.
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath) # Converts the specified path to an absolute path.
} # Ends explicit output-path handling.

$parentDirectory = Split-Path -Parent $OutputPath # Gets the directory that will contain the summary file.
if (-not [string]::IsNullOrWhiteSpace($parentDirectory) -and -not (Test-Path -LiteralPath $parentDirectory)) { # Checks whether the output directory needs to be created.
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null # Creates the missing directory without printing the directory object.
} # Ends output-directory preparation.

$summary | # Sends the summary records to the output-column selection step.
    Select-Object Date, ComputerName, UserName, ProcessName, # Keeps identifiers and app name at the start of each output row.
        @{ Name = 'TotalActiveSeconds'; Expression = { $_.TotalActiveSeconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) } }, # Formats seconds with a consistent decimal point.
        @{ Name = 'TotalActiveHours'; Expression = { $_.TotalActiveHours.ToString('0.00', [System.Globalization.CultureInfo]::InvariantCulture) } }, # Formats hours with two decimal places.
        IntervalCount | # Keeps the interval count and sends the selected columns to CSV export.
    Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8 # Writes the summary CSV without PowerShell type metadata.
Write-Host "Daily app summary saved to: $OutputPath" # Displays the path of the completed summary file.
