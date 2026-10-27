# App usage CSV scripts

These Windows PowerShell scripts create a local CSV of the foreground application on a computer and a daily per-app summary. They record process names, process IDs, computer/user names, timestamps, and durations. They do not record window titles, keystrokes, screenshots, document contents, or network activity.

Use them only with appropriate employee notice, organizational approval, and applicable privacy/legal review. The collector runs visibly in the current user's interactive session and does not transmit data. By default, it does not install a service or start automatically; the optional Task Scheduler setup below enables per-user logon startup.

## Requirements

- Windows PowerShell 5.1 or PowerShell 7 on Windows
- Run the collector in each user's interactive desktop session

## Collect intervals

```powershell
.\Start-AppUsageLogging.ps1
```

By default, the script creates a timestamped `AppUsage-*.csv` file beside the script. It samples the foreground process once per second and marks the session idle after five minutes without keyboard/mouse input. Idle time is recorded as `State=Idle` and excluded from active app totals. If the collector starts after the idle threshold has already been reached, it begins recording from the estimated threshold-crossing time; it cannot report activity from before it started. Intervals crossing local midnight are split so daily totals are attributed to the correct date. Press `Ctrl+C` to stop and flush the current interval.

Use one collector process per output file. Do not run multiple collectors at once with the same `-OutputPath`: concurrent writes can corrupt or mix the CSV data. If specifying an output path, use a new file for each collection run. The default timestamped filename has one-second precision, so avoid starting multiple collectors in the same second.

Options:

```powershell
.\Start-AppUsageLogging.ps1 -OutputPath C:\Reports\employee-activity.csv -IdleThresholdMinutes 3 -PollIntervalSeconds 1
```

## Run automatically at sign-in

To register a per-user Task Scheduler task and start collecting immediately:

```powershell
.\Register-AppUsageTask.ps1
```

The task runs only in the current user's interactive session, at limited (non-administrator) privileges, and starts again at each sign-in. Its PowerShell window stays visible. It does not run before sign-in or while that user is signed out. Task Scheduler prevents a second scheduled instance while the task is running, but it does not prevent a collector started manually from running at the same time.

The registration script uses the task name **Foreground App Usage Logger**. Registering it again replaces a task with that same name, and the removal script removes that named task. Check Task Scheduler before using these scripts if you already have another task with that name. Your organization's PowerShell execution policy may also prevent scripts from running; follow your administrator's approved process rather than weakening the policy.

To stop collection for the current session, press `Ctrl+C` in the collector's visible PowerShell window. To stop it and remove automatic startup:

```powershell
.\Unregister-AppUsageTask.ps1
```

You can also stop the scheduled task in Task Scheduler by finding **Foreground App Usage Logger**. If the task is stopped there, it will start again at the user's next sign-in unless it is unregistered.

`StartTime` and `EndTime` are local timestamps in ISO 8601 format with their UTC offset. The collector uses a monotonic timer for its timeline, so system clock adjustments while it runs do not distort interval durations. Windows provides the last-input timestamp as a 32-bit tick count. If the computer has been running for more than about 49.7 days when collection starts, an initial idle-age estimate can be ambiguous; the script warns about this, and a newly observed keyboard or mouse event resolves the ambiguity.

Time is attributed to the foreground process, not proof of work or productivity; an app may remain foreground while its user is doing something else. Sampling can also miss brief app switches or attribute a transition imprecisely by up to the polling interval.

## Summarize

```powershell
.\Export-AppUsageSummary.ps1 -Path .\AppUsage-20261027-*.csv
```

The example selects timestamped collector files for one date and avoids matching summary files. The summary groups active intervals by local date, computer, user, and process. Avoid broad patterns such as `AppUsage-*.csv`, because they also match earlier `AppUsage-Summary-*.csv` files. Do not set the summary `-OutputPath` to an input log path: the exporter can overwrite that file.

```powershell
.\Export-AppUsageSummary.ps1 -Path C:\Reports\AppUsage-20261027-*.csv -OutputPath C:\Reports\daily-summary.csv
```
