[CmdletBinding()] # Enables standard PowerShell parameter binding and common command options.
param( # Declares the collector's command-line parameters.
    [string]$OutputPath, # Optionally selects the CSV file path; otherwise a timestamped file is created beside this script.
    [ValidateRange(1, 1440)] # Restricts the idle threshold to 1 through 1440 minutes.
    [int]$IdleThresholdMinutes = 5, # Sets how long without input before activity is classified as idle.
    [ValidateRange(1, 30)] # Restricts the polling interval to 1 through 30 seconds.
    [int]$PollIntervalSeconds = 1 # Sets how often the foreground app and input-idle state are sampled.
) # Ends the parameter declaration.

$ErrorActionPreference = 'Stop' # Makes unhandled command errors terminate the collector.

if ($env:OS -ne 'Windows_NT') { # Checks that the script is running on Windows.
    throw 'This collector requires Windows.' # Stops because its APIs are Windows-specific.
} # Ends the operating-system check.

if (-not ('AppUsageNativeMethods' -as [type])) { # Avoids defining the native API wrapper type more than once.
    # The next here-string contains C# declarations compiled for Windows API access.
    Add-Type -TypeDefinition @'
using System; // Imports core .NET types such as IntPtr.
using System.Runtime.InteropServices; // Imports attributes and marshaling support for native API calls.

public static class AppUsageNativeMethods // Defines a static wrapper for the required Windows functions.
{ // Opens the native-method wrapper class.
    [StructLayout(LayoutKind.Sequential)] // Ensures this structure matches the native Windows memory layout.
    public struct LASTINPUTINFO // Represents Windows' last keyboard/mouse input information.
    { // Opens the last-input structure.
        public uint cbSize; // Stores the structure size required by the Windows API.
        public uint dwTime; // Stores the tick count of the most recent user input.
    } // Closes the last-input structure.

    [DllImport("user32.dll")] // Imports the Windows API that returns the current foreground window handle.
    public static extern IntPtr GetForegroundWindow(); // Returns the handle of the window currently in the foreground.

    [DllImport("user32.dll")] // Imports the Windows API that finds the process owning a window.
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId); // Writes the process ID for the supplied window.

    [DllImport("user32.dll")] // Imports the Windows API that reads the most recent keyboard/mouse input tick.
    public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii); // Fills the last-input structure and reports success.

    [DllImport("kernel32.dll")] // Imports the Windows API that returns the system tick count.
    public static extern ulong GetTickCount64(); // Returns a 64-bit monotonic tick count since the system started.
} // Closes the native-method wrapper class.
// The following here-string terminator returns to PowerShell.
'@
} # Ends the one-time native type definition check.

if ([string]::IsNullOrWhiteSpace($OutputPath)) { # Checks whether the user omitted the output CSV path.
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss' # Creates a timestamp for a unique default filename.
    $OutputPath = Join-Path $PSScriptRoot "AppUsage-$stamp.csv" # Places the default CSV beside this script.
} # Ends default path selection.
else { # Handles a path explicitly provided by the caller.
    $OutputPath = [System.IO.Path]::GetFullPath($OutputPath) # Normalizes the supplied path to an absolute path.
} # Ends explicit path handling.

$parentDirectory = Split-Path -Parent $OutputPath # Gets the directory that should contain the output CSV.
if (-not [string]::IsNullOrWhiteSpace($parentDirectory) -and -not (Test-Path -LiteralPath $parentDirectory)) { # Checks whether that directory is missing.
    New-Item -ItemType Directory -Path $parentDirectory -Force | Out-Null # Creates the directory without displaying its object.
} # Ends output directory preparation.

function Get-LastInputAgeMilliseconds { # Defines a helper that measures time since the last keyboard/mouse input.
    $lastInput = New-Object AppUsageNativeMethods+LASTINPUTINFO # Creates the structure that receives Windows' last-input time.
    $lastInput.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($lastInput) # Sets the structure size required by the API.
    if (-not [AppUsageNativeMethods]::GetLastInputInfo([ref]$lastInput)) { # Requests the last input time from Windows.
        throw 'Windows could not read the last keyboard/mouse activity time.' # Stops if the operating system call fails.
    } # Ends last-input API error handling.

    $currentTick64 = [uint64][AppUsageNativeMethods]::GetTickCount64() # Reads the full-width monotonic system tick count.
    $currentTick32 = [uint32]($currentTick64 -band 0xFFFFFFFF) # Extracts the low 32 bits used by LASTINPUTINFO.
    $ageSinceInputModulo = [uint32](([uint64]$currentTick32 + 4294967296 - [uint64]$lastInput.dwTime) % 4294967296) # Finds the wrapped tick difference since the last input.

    if ($null -eq $script:LastObservedInputTick64) { # Initializes the extended input timestamp on the first sample.
        $script:LastObservedInputTick64 = $currentTick64 - [uint64]$ageSinceInputModulo # Estimates the full-width input tick from the first observed wrapped age.
        $script:LastObservedInputTick32 = $lastInput.dwTime # Remembers the 32-bit input tick for change detection.
        if ($currentTick64 -ge 4294967296) { # Checks whether Windows' 32-bit input timestamp may have wrapped before collection began.
            Write-Warning 'The first idle-age estimate is ambiguous because Windows exposes a 32-bit last-input tick. After 49.7 days of uptime, input older than one tick cycle cannot be distinguished until new input is observed.' # Discloses the unavoidable first-sample limitation.
        } # Ends first-sample ambiguity notice.
    } # Ends first-sample initialization.
    elseif ($lastInput.dwTime -ne $script:LastObservedInputTick32) { # Detects a new keyboard/mouse event since the previous sample.
        $script:LastObservedInputTick64 = $currentTick64 - [uint64]$ageSinceInputModulo # Extends the new input time using its short observed age.
        $script:LastObservedInputTick32 = $lastInput.dwTime # Stores the new 32-bit tick value.
    } # Ends new-input timestamp extension.

    return [uint64]($currentTick64 - $script:LastObservedInputTick64) # Returns elapsed time without recurring 32-bit rollover after initialization.
} # Ends the idle-age helper.

function Get-ForegroundProcess { # Defines a helper that identifies the foreground window's process.
    $window = [AppUsageNativeMethods]::GetForegroundWindow() # Reads the handle of the current foreground window.
    [uint32]$processId = 0 # Initializes the process ID output variable.
    [void][AppUsageNativeMethods]::GetWindowThreadProcessId($window, [ref]$processId) # Obtains the process ID owning the foreground window.

    if ($processId -eq 0) { # Checks whether Windows returned no process identifier.
        return [pscustomobject]@{ ProcessName = 'Unknown'; ProcessId = $null } # Returns an explicit unknown-process record.
    } # Ends the missing-process check.

    try { # Attempts to retrieve the process name while handling processes that exit during sampling.
        $process = Get-Process -Id $processId -ErrorAction Stop # Reads process details for the foreground process ID.
        return [pscustomobject]@{ # Returns the foreground app's identifying fields.
            ProcessName = $process.ProcessName # Records the process name, without window contents or title.
            ProcessId   = $processId # Records the numeric Windows process ID.
        } # Ends the process information record.
    } # Ends the process lookup attempt.
    catch { # Handles inaccessible or already-exited foreground processes.
        Write-Warning "Could not read foreground process ${processId}: $($_.Exception.Message)" # Makes the lookup failure visible to the operator.
        return [pscustomobject]@{ # Returns a fallback record while retaining the known process ID.
            ProcessName = 'Unknown' # Marks the unavailable process name explicitly.
            ProcessId   = $processId # Retains the process ID returned by Windows.
        } # Ends the fallback process record.
    } # Ends process lookup error handling.
} # Ends the foreground-process helper.

function Write-UsageInterval { # Defines a helper that splits and writes one active or idle interval.
    param( # Declares the interval writer's inputs.
        [Parameter(Mandatory)][string]$State, # Requires the interval's Active or Idle state.
        [Parameter(Mandatory)][datetimeoffset]$StartTime, # Requires the interval's start timestamp with its UTC offset.
        [Parameter(Mandatory)][datetimeoffset]$EndTime, # Requires the interval's end timestamp with its UTC offset.
        [string]$ProcessName, # Optionally identifies the foreground process for active intervals.
        [Nullable[uint32]]$ProcessId # Optionally identifies the Windows process ID for active intervals.
    ) # Ends the interval writer's parameter list.

    if ($EndTime -lt $StartTime) { # Guards against negative-duration intervals.
        $EndTime = $StartTime # Clamps an invalid end timestamp to the start timestamp.
    } # Ends interval timestamp validation.

    $segmentStart = $StartTime # Initializes the start of the first date-bounded CSV segment.
    while ($segmentStart -lt $EndTime) { # Writes segments until the full interval has been recorded.
        $segmentStartLocal = [System.TimeZoneInfo]::ConvertTime($segmentStart, [System.TimeZoneInfo]::Local) # Converts the current segment boundary to local time before calculating its date.
        $nextLocalMidnight = $segmentStartLocal.Date.AddDays(1) # Finds the next local midnight for daily report grouping.
        $midnightUtc = [System.TimeZoneInfo]::ConvertTimeToUtc($nextLocalMidnight, [System.TimeZoneInfo]::Local) # Converts the next local midnight to UTC using the correct daylight-saving rule.
        $dayEnd = [datetimeoffset]::new($midnightUtc, [timespan]::Zero) # Creates the midnight boundary as a UTC timestamp for safe comparison.
        $segmentEnd = if ($EndTime -lt $dayEnd) { $EndTime } else { $dayEnd } # Ends this CSV segment at the interval end or midnight, whichever comes first.

        $row = [pscustomobject][ordered]@{ # Creates a CSV row with a stable column order.
            ComputerName    = $env:COMPUTERNAME # Records which computer produced this interval.
            UserName        = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name # Records the current Windows identity.
            State           = $State # Records whether this segment is Active or Idle.
            ProcessName     = $ProcessName # Records the foreground process name when applicable.
            ProcessId       = $ProcessId # Records the foreground process ID when applicable.
            StartTime       = $segmentStart.ToString('o') # Serializes the segment start in round-trip ISO format with offset.
            EndTime         = $segmentEnd.ToString('o') # Serializes the segment end in round-trip ISO format with offset.
            DurationSeconds = ($segmentEnd - $segmentStart).TotalSeconds.ToString( # Computes and begins invariant formatting of segment duration.
                '0.0', # Formats the duration with one decimal place.
                [System.Globalization.CultureInfo]::InvariantCulture # Uses a consistent decimal point independent of machine locale.
            ) # Completes duration formatting.
        } # Ends construction of the CSV row.

        if (Test-Path -LiteralPath $OutputPath) { # Checks whether the CSV already exists and has a header.
            $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8 -Append # Appends this row without repeating the header.
        } # Ends the existing-file export path.
        else { # Handles the first row written to a new CSV.
            $row | Export-Csv -LiteralPath $OutputPath -NoTypeInformation -Encoding UTF8 # Creates the CSV and writes its header and first row.
        } # Ends the new-file export path.

        $segmentStart = $segmentEnd # Advances to the next date segment if the interval crossed midnight.
    } # Ends date-bounded interval writing.
} # Ends the interval writer helper.

$state = $null # Initializes the collector's current tracking state.
$intervalStart = $null # Initializes the start timestamp for the current state interval.
$intervalStartElapsedSeconds = $null # Initializes the monotonic start time for duration measurement.
$activeProcess = $null # Initializes the process currently attributed active time.
$idleThresholdMilliseconds = [uint64]$IdleThresholdMinutes * 60 * 1000 # Converts the configured idle threshold to milliseconds.
$script:LastObservedInputTick64 = $null # Stores an extended last-input tick so runtime wraparounds do not reset idle age.
$script:LastObservedInputTick32 = $null # Stores the last 32-bit input tick to detect new user activity.
$script:TrackingClock = [System.Diagnostics.Stopwatch]::StartNew() # Starts monotonic elapsed-time measurement unaffected by clock adjustments.
$script:TrackingAnchorUtc = [datetimeoffset]::UtcNow # Anchors output timestamps to UTC when collection begins.

function Get-TrackingTime { # Defines a stable timeline based on the monotonic timer.
    $utcTime = $script:TrackingAnchorUtc.AddSeconds($script:TrackingClock.Elapsed.TotalSeconds) # Advances the initial UTC timestamp by monotonic elapsed time.
    return [System.TimeZoneInfo]::ConvertTime($utcTime, [System.TimeZoneInfo]::Local) # Converts the stable UTC timeline to local time for CSV reporting.
} # Ends the stable timestamp helper.

Write-Host "Recording foreground app intervals to: $OutputPath" # Announces the local CSV destination.
Write-Host "Idle threshold: $IdleThresholdMinutes minute(s). Press Ctrl+C to stop." # Explains idle handling and how to stop collection.

try { # Ensures the current interval is flushed even if the user interrupts the loop.
    while ($true) { # Repeats app and idle sampling until interrupted.
        $now = Get-TrackingTime # Captures the current monotonic-derived local timestamp with its UTC offset.
        $nowElapsedSeconds = $script:TrackingClock.Elapsed.TotalSeconds # Captures monotonic elapsed time for reliable duration calculations.
        $idleAgeMilliseconds = Get-LastInputAgeMilliseconds # Measures elapsed time since the most recent keyboard/mouse input.
        $isIdle = [uint64]$idleAgeMilliseconds -ge $idleThresholdMilliseconds # Classifies the user as idle after the configured threshold.

        if ($isIdle) { # Handles periods beyond the idle threshold.
            if ($state -eq 'Active') { # Checks whether an active interval needs to be closed at the idle boundary.
                $idleExcessSeconds = [double]($idleAgeMilliseconds - $idleThresholdMilliseconds) / 1000 # Calculates time elapsed beyond the configured idle threshold.
                $activeDurationSeconds = [math]::Max(0, $nowElapsedSeconds - $intervalStartElapsedSeconds - $idleExcessSeconds) # Measures active duration using the monotonic clock.
                $idleStart = $intervalStart.AddSeconds($activeDurationSeconds) # Places the idle boundary after the measured active duration.
                if ($idleStart -lt $intervalStart) { # Avoids placing the inferred boundary before this tracked interval began.
                    $idleStart = $intervalStart # Clamps the boundary to the current interval's start.
                } # Ends boundary clamping.
                # The following command closes the active interval at the estimated idle boundary.
                Write-UsageInterval -State 'Active' -StartTime $intervalStart -EndTime $idleStart `
                    -ProcessName $activeProcess.ProcessName -ProcessId $activeProcess.ProcessId
                $state = 'Idle' # Changes tracking state to idle after writing active time.
                $intervalStart = $idleStart # Begins the idle interval at the threshold boundary.
                $intervalStartElapsedSeconds = $nowElapsedSeconds - $idleExcessSeconds # Tracks the idle boundary on the monotonic timeline.
                $activeProcess = $null # Clears the process attribution while the user is idle.
            } # Ends transition from active to idle.
            elseif ($null -eq $state) { # Handles a collector started after the user is already idle.
                $idleExcessSeconds = [double]($idleAgeMilliseconds - $idleThresholdMilliseconds) / 1000 # Finds when the idle threshold was first crossed.
                $state = 'Idle' # Starts tracking idle state immediately.
                $intervalStart = $now.AddSeconds(-$idleExcessSeconds) # Estimates the start of the reportable idle interval.
                $intervalStartElapsedSeconds = $nowElapsedSeconds - $idleExcessSeconds # Sets its monotonic start for duration measurement.
            } # Ends initial idle-state handling.
        } # Ends idle-state handling.
        else { # Handles intervals with recent keyboard/mouse input.
            $foregroundProcess = Get-ForegroundProcess # Reads the process currently in the foreground.
            $processChanged = $state -ne 'Active' -or # Detects a transition from idle/uninitialized to active.
                $activeProcess.ProcessId -ne $foregroundProcess.ProcessId -or # Detects a change in the foreground process ID.
                $activeProcess.ProcessName -ne $foregroundProcess.ProcessName # Detects a process-name change.

            if ($state -eq 'Idle') { # Checks whether recent input ended a recorded idle period.
                Write-UsageInterval -State 'Idle' -StartTime $intervalStart -EndTime $now # Closes the idle interval at the current time.
            } # Ends idle interval closing.
            elseif ($state -eq 'Active' -and $processChanged) { # Checks whether the foreground app changed during active use.
                # The following command closes the previous app interval before attributing time to the new app.
                Write-UsageInterval -State 'Active' -StartTime $intervalStart -EndTime $now `
                    -ProcessName $activeProcess.ProcessName -ProcessId $activeProcess.ProcessId
            } # Ends active app change handling.

            if ($processChanged) { # Starts a new active interval after a state or foreground process change.
                $state = 'Active' # Marks the current tracked period as active.
                $intervalStart = $now # Sets the start timestamp for the new active interval.
                $intervalStartElapsedSeconds = $nowElapsedSeconds # Sets the monotonic start used to measure this active interval.
                $activeProcess = $foregroundProcess # Attributes new active time to the current foreground process.
            } # Ends new active interval initialization.
        } # Ends recent-input handling.

        Start-Sleep -Seconds $PollIntervalSeconds # Waits the configured period before sampling again.
    } # Ends the continuous collection loop.
} # Ends the protected collection block.
finally { # Runs on normal termination or interruption to flush the interval in progress.
    if ($state -eq 'Active') { # Checks whether the current interval is active.
        # The following command writes the active interval through the current time.
        Write-UsageInterval -State 'Active' -StartTime $intervalStart -EndTime (Get-TrackingTime) `
            -ProcessName $activeProcess.ProcessName -ProcessId $activeProcess.ProcessId
    } # Ends active interval finalization.
    elseif ($state -eq 'Idle') { # Checks whether the current interval is idle.
        Write-UsageInterval -State 'Idle' -StartTime $intervalStart -EndTime (Get-TrackingTime) # Writes the idle interval through the current time.
    } # Ends idle interval finalization.

    Write-Host "Activity intervals saved to: $OutputPath" # Confirms the output CSV location when collection stops.
} # Ends final cleanup and interval flushing.
