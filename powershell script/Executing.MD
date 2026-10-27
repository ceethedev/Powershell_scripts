# Executing the App Usage Logging Scripts

To run these app usage logging scripts on a Windows 11 machine, use **Windows PowerShell 5.1 or PowerShell 7** and run them within an interactive user desktop session.

## 1. Run Logging Manually

Open PowerShell in the directory containing the scripts and run:

```powershell
.\Start-AppUsageLogging.ps1
```

- **Default behavior:** Creates a timestamped `AppUsage-*.csv` file in the same folder. It samples once per second and marks the session idle after five minutes without keyboard/mouse input.
- **Stopping:** Press `Ctrl+C` in the PowerShell window to stop collection and flush the current interval.
- **Custom options example:**

```powershell
.\Start-AppUsageLogging.ps1 -OutputPath C:\Reports\employee-activity.csv -IdleThresholdMinutes 3 -PollIntervalSeconds 1
```

## 2. Run Automatically at Sign-In (Task Scheduler)

To start the logger automatically every time the user signs in, register a per-user Task Scheduler task.

Register the task and start collection:

```powershell
.\Register-AppUsageTask.ps1
```

The task runs in the current user's interactive, non-elevated session so it can access foreground-window APIs. Its PowerShell window remains visible.

To stop collection and remove automatic startup:

```powershell
.\Unregister-AppUsageTask.ps1
```

You can also stop the task named **Foreground App Usage Logger** directly in Windows Task Scheduler. It will run again at the next sign-in unless you unregister it.

## 3. Generate a Daily Summary

Use the summary script to process raw log files into a daily summary CSV.

Basic summary generation:

```powershell
.\Export-AppUsageSummary.ps1 -Path .\AppUsage-20261027-*.csv
```

Custom output summary example:

```powershell
.\Export-AppUsageSummary.ps1 -Path C:\Reports\AppUsage-20261027-*.csv -OutputPath C:\Reports\daily-summary.csv
```

Use input patterns that match only raw collector CSVs. Avoid broad patterns such as `AppUsage-*.csv`, which can also match existing summary files. Do not set the summary output path to the same path as an input log.
