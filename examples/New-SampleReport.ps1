<#
.SYNOPSIS
    Regenerates examples/sample-backup-report.html from fictional data.

.DESCRIPTION
    Builds the sample report in this folder. It runs Send-BackupReport.ps1 with
    made-up results (plus the VSS fixture used by the tests), so the report can be
    previewed without a Windows or Veeam server. None of the data is real.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$OutputPath = (Join-Path $PSScriptRoot 'sample-backup-report.html')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scripts = Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts'
$fixture = Join-Path (Split-Path $PSScriptRoot -Parent) 'tests/fixtures/vssadmin-writers-sample.txt'
$now = Get-Date

$vss = & (Join-Path $scripts 'Get-VssWriterHealth.ps1') -Path $fixture

$disk = @(
    [pscustomobject]@{ Path = 'C:\'; TotalGB = 126.45; FreeGB = 48.12; FreePercent = 38.1; Status = 'OK' }
    [pscustomobject]@{ Path = 'D:\Backups'; TotalGB = 3725.9; FreeGB = 612.4; FreePercent = 16.4; Status = 'Warning' }
    [pscustomobject]@{ Path = '\\nas-sample\repo'; TotalGB = 7451.8; FreeGB = 2980.7; FreePercent = 40.0; Status = 'OK' }
)

$events = @(
    [pscustomobject]@{ Count = 3; LogName = 'Application'; ProviderName = 'VSS'; Id = 8229; LastSeen = $now.AddHours(-2)
        SampleMessage = 'A VSS writer has rejected an event with error 0x800423f4. (sample message)' }
    [pscustomobject]@{ Count = 1; LogName = 'System'; ProviderName = 'volsnap'; Id = 36; LastSeen = $now.AddHours(-7)
        SampleMessage = 'The shadow copies of volume D: were aborted because the shadow copy storage could not grow due to a user imposed limit. (sample message)' }
)

$veeam = @(
    [pscustomobject]@{ JobName = 'SAMPLE - SQL Server VMs'; JobType = 'Backup'; LastResult = 'Failed'; LastStart = $now.AddHours(-5); LastDuration = '00:41:12'; FailedInWindow = 1 }
    [pscustomobject]@{ JobName = 'SAMPLE - File Servers'; JobType = 'Backup'; LastResult = 'Warning'; LastStart = $now.AddHours(-6); LastDuration = '01:12:40'; FailedInWindow = 0 }
    [pscustomobject]@{ JobName = 'SAMPLE - Domain Controllers'; JobType = 'Backup'; LastResult = 'Success'; LastStart = $now.AddHours(-6); LastDuration = '00:18:05'; FailedInWindow = 0 }
    [pscustomobject]@{ JobName = 'SAMPLE - Offsite Copy'; JobType = 'BackupSync'; LastResult = 'Success'; LastStart = $now.AddHours(-3); LastDuration = '02:03:51'; FailedInWindow = 0 }
)

$previousName = $env:COMPUTERNAME
try {
    $env:COMPUTERNAME = 'SAMPLE-SRV01'
    & (Join-Path $scripts 'Send-BackupReport.ps1') -OutputPath $OutputPath `
        -Title 'SAMPLE OUTPUT - Backup Health Report (fictional data)' `
        -VssResult $vss -DiskResult $disk -EventResult $events -VeeamResult $veeam
}
finally {
    $env:COMPUTERNAME = $previousName
}
