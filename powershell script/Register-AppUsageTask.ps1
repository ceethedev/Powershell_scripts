[CmdletBinding()] # Enables standard PowerShell parameter binding and common command options.
param() # This setup script uses the collector beside itself and needs no parameters.

$ErrorActionPreference = 'Stop' # Stops setup when a command fails rather than reporting false success.

if ($env:OS -ne 'Windows_NT') { # Confirms this script is running on Windows.
    throw 'Task Scheduler setup requires Windows.' # Stops because scheduled tasks are a Windows feature.
} # Ends the operating-system check.

$collectorPath = Join-Path $PSScriptRoot 'Start-AppUsageLogging.ps1' # Finds the collector script in the same folder.
if (-not (Test-Path -LiteralPath $collectorPath -PathType Leaf)) { # Checks that the collector file exists.
    throw "Collector script was not found: $collectorPath" # Reports the missing file instead of registering a broken task.
} # Ends collector file validation.

$userName = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name # Gets the current user's Windows account name.
$taskName = 'Foreground App Usage Logger' # Sets a stable Task Scheduler name for this collector.
$engineName = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh.exe' } else { 'powershell.exe' } # Chooses the executable matching the current PowerShell edition.
$enginePath = Join-Path $PSHOME $engineName # Locates that PowerShell executable in its installation directory.
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) { # Checks that the selected PowerShell executable exists.
    throw "PowerShell executable was not found: $enginePath" # Reports the invalid executable path.
} # Ends executable validation.

$action = New-ScheduledTaskAction -Execute $enginePath -Argument "-NoProfile -File `"$collectorPath`"" # Starts the collector in a separate PowerShell window without loading user profiles.
$trigger = New-ScheduledTaskTrigger -AtLogOn -User $userName # Runs the collector each time this user signs in.
$principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited # Runs with this user's interactive, non-elevated session so foreground-window APIs work.
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([timespan]::Zero) -MultipleInstances IgnoreNew -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) # Keeps the collector running without a time limit and retries unexpected failures.

Register-ScheduledTask -TaskName $taskName -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Visible, per-user foreground app usage interval collector.' -Force | Out-Null # Registers or replaces the per-user logon task.
Start-ScheduledTask -TaskName $taskName # Starts collection now without requiring the user to sign out and back in.

Write-Host "Registered '$taskName' for $userName and started it in the interactive session." # Confirms setup and immediate start.
Write-Host "The collector window remains visible. Stop collection with Ctrl+C in that window or run Unregister-AppUsageTask.ps1." # Explains how to stop the collector and remove autostart.
