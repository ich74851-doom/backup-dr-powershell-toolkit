# Backup & DR PowerShell Toolkit

[![CI](https://github.com/ich74851-doom/backup-dr-powershell-toolkit/actions/workflows/ci.yml/badge.svg)](https://github.com/ich74851-doom/backup-dr-powershell-toolkit/actions/workflows/ci.yml)
![PowerShell](https://img.shields.io/badge/PowerShell-5.1%20%7C%207%2B-5391FE?logo=powershell&logoColor=white)
![Platform](https://img.shields.io/badge/Platform-Windows%20Server-0078D6?logo=windows&logoColor=white)
![Veeam](https://img.shields.io/badge/Veeam-B%26R%20module-00B336)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

PowerShell scripts for the daily checks behind backup monitoring and disaster recovery
work: VSS writer health, repository capacity, backup-related event log errors, Veeam
job results, and a combined HTML health report that can be emailed.

> The sample report in `examples/` is built from fictional data.

## Overview

Backup monitoring is mostly the same few questions every morning: are the VSS writers
healthy, is there space on the repositories, did anything log backup errors overnight, and
did every job succeed? This toolkit answers each one with a standalone script and combines
them into one HTML report.

Each script runs on its own, has comment-based help (`Get-Help .\script.ps1 -Full`),
validates its parameters, handles errors, and contains no hard-coded credentials.
Most also return a meaningful **exit code**, so they can run as **RMM script monitors**
(NinjaOne, Datto RMM, Syncro, ConnectWise).

## Features

| Script | What it does |
|---|---|
| [`Get-VssWriterHealth.ps1`](scripts/Get-VssWriterHealth.ps1) | Parses `vssadmin list writers` into objects and flags writers that are failed, waiting, or reporting errors. Can also parse saved output. |
| [`Test-BackupDiskSpace.ps1`](scripts/Test-BackupDiskSpace.ps1) | Checks free space on local volumes, mount points or UNC/NAS repository paths against % thresholds and an optional GB floor. |
| [`Get-WindowsBackupEventSummary.ps1`](scripts/Get-WindowsBackupEventSummary.ps1) | Reads Application, System, Windows Server Backup and Veeam logs for backup, VSS, volsnap, disk and iSCSI errors over the last *N* hours, grouped by provider and event ID. |
| [`Get-VeeamJobReport.ps1`](scripts/Get-VeeamJobReport.ps1) | Uses `Get-VBRJob` / `Get-VBRBackupSession` to summarise the last result of each job plus session counts in a window, and exports CSV/HTML. |
| [`Send-BackupReport.ps1`](scripts/Send-BackupReport.ps1) | Runs the checks above and builds one self-contained HTML report with an overall OK / Warning / Failed status. It can send the report over SMTP and supports `-WhatIf`. |

## Quick start

Requirements:

- Windows PowerShell 5.1 or PowerShell 7+
- Windows Server / Windows for the live checks. `vssadmin` and the event log checks
  need an **elevated** session.
- `Get-VeeamJobReport.ps1`: the Veeam Backup & Replication console or server, which
  provides the `Veeam.Backup.PowerShell` module (v11+) or `VeeamPSSnapIn` (v10 and earlier)
- `Send-BackupReport.ps1` email: an SMTP relay you are allowed to use

Parsing, capacity checks and report building also work on PowerShell 7 on Linux and
macOS, which is how CI tests them.

```powershell
git clone https://github.com/ich74851-doom/backup-dr-powershell-toolkit.git
cd backup-dr-powershell-toolkit\scripts

# If scripts are blocked after download:
Get-ChildItem *.ps1 | Unblock-File

Get-Help .\Get-VssWriterHealth.ps1 -Full
```

## Usage

### VSS writer health

```powershell
# All writers with computed status
.\Get-VssWriterHealth.ps1 | Format-Table WriterName, State, LastError, Status

# Only the writers that need attention
.\Get-VssWriterHealth.ps1 -FailedOnly

# RMM monitor: exit code 1 when any writer is not healthy
.\Get-VssWriterHealth.ps1 -ExitWithCode

# Parse output collected earlier (for example through an RMM tool)
.\Get-VssWriterHealth.ps1 -Path .\writers.txt
```

| Status | Rule |
|---|---|
| Healthy | `[1] Stable` and `No error` |
| Warning | `Waiting for ...` states, or stable with a last error such as `Retryable error` |
| Failed | any `Failed` state (codes 6-15) or `[0] Unknown` |

### Repository / volume capacity

```powershell
# All fixed local volumes, default thresholds (warning < 20%, critical < 10%)
.\Test-BackupDiskSpace.ps1

# Specific repositories, including a NAS share, with custom thresholds
.\Test-BackupDiskSpace.ps1 -Path 'D:\Backups', '\\nas01\backup-repo' -WarningPercent 25 -CriticalPercent 15

# Absolute floor: less than 500 GB free is Critical. Exit code 2 = critical, 1 = warning.
.\Test-BackupDiskSpace.ps1 -Path 'R:\' -MinFreeGB 500 -ExitWithCode
```

### Backup and VSS event errors

```powershell
# Grouped summary for the last 24 hours
.\Get-WindowsBackupEventSummary.ps1 | Format-Table Count, LogName, ProviderName, Id, LastSeen -AutoSize

# Every error and warning from the last 72 hours
.\Get-WindowsBackupEventSummary.ps1 -Hours 72 -IncludeWarnings -Detailed

# Several servers, plus a custom backup agent provider
.\Get-WindowsBackupEventSummary.ps1 -ComputerName HV01, FS01 -AdditionalProvider 'Backup Service Controller'
```

### Veeam job report

```powershell
# Last result of every enabled job on the local VBR server
.\Get-VeeamJobReport.ps1 | Format-Table JobName, LastResult, LastStart, LastDuration, FailedInWindow

# 3-day window, CSV + HTML export
.\Get-VeeamJobReport.ps1 -HoursBack 72 -OutputDirectory 'C:\Reports\Veeam'

# Remote VBR server; you are prompted for the credential, nothing is stored
.\Get-VeeamJobReport.ps1 -Server vbr01.example.local -Credential (Get-Credential) -Format Html -OutputDirectory .\out
```

### Combined HTML report and email

```powershell
# Build and save the report (no email)
.\Send-BackupReport.ps1 -OutputPath C:\Reports\backup-health.html

# Add Veeam results and specific repositories
.\Send-BackupReport.ps1 -RepositoryPath 'D:\Backups', '\\nas01\repo' -IncludeVeeam -Hours 48

# Email through an authenticated relay
$cred = Get-Credential
.\Send-BackupReport.ps1 -SmtpServer smtp.example.com -Port 587 -UseSsl `
    -From 'backup-alerts@example.com' -To 'it-team@example.com' -Credential $cred

# Dry run: build the report and show what would be sent
.\Send-BackupReport.ps1 -SmtpServer smtp.example.com -From a@example.com -To b@example.com -WhatIf
```

To see what the report looks like, download
[`examples/sample-backup-report.html`](examples/sample-backup-report.html) and open it
in a browser. It is **sample output built from fictional data**.

### Scheduling

Run the combined report every morning with Task Scheduler:

```powershell
$action  = New-ScheduledTaskAction -Execute 'powershell.exe' `
    -Argument '-NoProfile -ExecutionPolicy Bypass -File "C:\Tools\toolkit\scripts\Send-BackupReport.ps1" -OutputPath "C:\Reports\backup-health.html"'
$trigger = New-ScheduledTaskTrigger -Daily -At 7:30am
Register-ScheduledTask -TaskName 'Daily Backup Health Report' -Action $action -Trigger $trigger -User 'SYSTEM' -RunLevel Highest
```

If you add SMTP credentials to a scheduled run, keep them in a secret store
(for example `Microsoft.PowerShell.SecretManagement`), not in the task arguments.

### Notes and limitations

- `vssadmin` output is parsed in English. On other display languages, collect the
  output from an English-language system or change the regexes.
- In Veeam v12, agent (computer) backup jobs are managed with `Get-VBRComputerBackupJob`,
  and `Get-VBRJob` may leave them out.
- `Send-MailMessage` is obsolete but still works. For Microsoft 365 tenants with SMTP AUTH
  turned off, use a relay connector or Microsoft Graph.
- Test in a lab or a maintenance window before rolling out to production.

## Project structure

```text
backup-dr-powershell-toolkit/
├── scripts/                     # the toolkit
├── examples/
│   ├── sample-backup-report.html   # SAMPLE OUTPUT (fictional data)
│   └── New-SampleReport.ps1        # regenerates the sample
├── tests/                       # Pester tests + vssadmin fixture
├── PSScriptAnalyzerSettings.psd1
└── .github/workflows/ci.yml     # lint + tests on every push
```

## Testing

```powershell
Install-Module Pester -MinimumVersion 5.5 -Scope CurrentUser
Install-Module PSScriptAnalyzer -Scope CurrentUser

Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
Invoke-Pester -Path .\tests -Output Detailed
```

CI runs both on every push. The tests use a saved `vssadmin` fixture and pre-collected
data, so they need neither Windows nor Veeam.

## Roadmap

- Pester coverage for the Veeam report using recorded session objects
- Microsoft Graph mail delivery for tenants with SMTP AUTH turned off
- JSON output for every script, for ticketing and n8n workflows
- Optional Veeam v12 computer backup job support in `Get-VeeamJobReport.ps1`

## License

[MIT](LICENSE)
