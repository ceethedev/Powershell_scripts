[CmdletBinding()] # Enables standard PowerShell parameter binding and common command options.
param() # This removal script uses a fixed task name and needs no parameters.

$ErrorActionPreference = 'Stop' # Stops removal when a task operation fails.

if ($env:OS -ne 'Windows_NT') { # Confirms this script is running on Windows.
    throw 'Task Scheduler cleanup requires Windows.' # Stops because scheduled tasks are a Windows feature.
} # Ends the operating-system check.

$taskName = 'Foreground App Usage Logger' # Matches the task name used by the registration script.
$task = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue # Looks up the task without failing when it is absent.
if ($null -eq $task) { # Checks whether there is a registered collector task to remove.
    Write-Host "Task '$taskName' is not registered; nothing to remove." # Reports that no change was necessary.
    return # Ends the script because there is no task to stop or unregister.
} # Ends the missing-task check.

if ($task.State -eq 'Running') { # Checks whether the collector task is currently running.
    Stop-ScheduledTask -TaskName $taskName # Stops the collector process launched by Task Scheduler.
} # Ends running-task handling.

Unregister-ScheduledTask -TaskName $taskName -Confirm:$false # Removes the task so it will not start at the next sign-in.
Write-Host "Stopped and removed '$taskName'." # Confirms task removal.
