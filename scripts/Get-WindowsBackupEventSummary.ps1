<#
.SYNOPSIS
    Summarises backup, VSS and storage-related errors from Windows event logs.

.DESCRIPTION
    When a backup fails, the vendor console often shows a generic error. The real
    cause (a VSS writer timeout, a volsnap shadow copy being deleted, disk or iSCSI
    errors, an agent service crash) is usually in the Windows event logs.

    This script reads these logs for the last N hours:

      Application                - VSS, plus providers whose name matches common
                                   backup products (Veeam, Acronis, Datto, 'Backup')
      System                     - volsnap, disk, Ntfs, iScsiPrt, Microsoft-Windows-Ntfs
      Microsoft-Windows-Backup   - Windows Server Backup (if the log exists)
      Veeam Backup / Veeam Agent - Veeam's own logs (if they exist)

    By default it returns a grouped summary (one row for each provider and event ID,
    with a count, first and last time seen, and a sample message). Use -Detailed to
    get the individual events instead.

.PARAMETER Hours
    How many hours back to search. Default 24.

.PARAMETER ComputerName
    Computers to query. Default is the local computer. Remote queries need the
    Remote Event Log Management firewall rules and suitable permissions.

.PARAMETER IncludeWarnings
    Include Warning-level events. By default only Critical and Error are returned.

.PARAMETER AdditionalProvider
    Extra provider-name regular expressions to match in the Application and System
    logs, for example 'Backup Service Controller' or 'ShadowProtect'.

.PARAMETER Detailed
    Return individual events instead of the grouped summary.

.EXAMPLE
    .\Get-WindowsBackupEventSummary.ps1 | Format-Table Count, LogName, ProviderName, Id, LastSeen -AutoSize

    Grouped summary of backup and VSS errors from the last 24 hours.

.EXAMPLE
    .\Get-WindowsBackupEventSummary.ps1 -Hours 72 -IncludeWarnings -Detailed | Out-GridView

    Every error and warning from the last 3 days, for interactive review.

.EXAMPLE
    .\Get-WindowsBackupEventSummary.ps1 -ComputerName HV01, FS01 -AdditionalProvider 'Backup Service Controller'

    Queries two servers and adds a custom backup agent provider to the filter.

.OUTPUTS
    PSCustomObject (summary rows, or event rows with -Detailed).
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateRange(1, 8760)]
    [int]$Hours = 24,

    [Parameter()]
    [string[]]$ComputerName = @($env:COMPUTERNAME),

    [Parameter()]
    [switch]$IncludeWarnings,

    [Parameter()]
    [string[]]$AdditionalProvider = @(),

    [Parameter()]
    [switch]$Detailed
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
    throw 'This script reads Windows event logs and must run on Windows.'
}

# Event levels: 1 = Critical, 2 = Error, 3 = Warning
$levels = if ($IncludeWarnings) { @(1, 2, 3) } else { @(1, 2) }
$since = (Get-Date).AddHours(-$Hours)

# Each source is a log name plus an optional provider-name regex (null = every provider).
$sources = @(
    [pscustomobject]@{ LogName = 'Application'; ProviderPattern = (@('^VSS$', 'Veeam', 'Acronis', 'Datto', 'Backup') + $AdditionalProvider) -join '|' }
    [pscustomobject]@{ LogName = 'System'; ProviderPattern = (@('^volsnap$', '^disk$', '^Ntfs$', '^Microsoft-Windows-Ntfs$', '^iScsiPrt$') + $AdditionalProvider) -join '|' }
    [pscustomobject]@{ LogName = 'Microsoft-Windows-Backup'; ProviderPattern = $null }
    [pscustomobject]@{ LogName = 'Veeam Backup'; ProviderPattern = $null }
    [pscustomobject]@{ LogName = 'Veeam Agent'; ProviderPattern = $null }
)

$events = New-Object System.Collections.Generic.List[object]

foreach ($computer in $ComputerName) {
    foreach ($source in $sources) {
        # Skip logs that do not exist on this machine (for example no Veeam installed).
        $logParams = @{ ListLog = $source.LogName; ComputerName = $computer; ErrorAction = 'SilentlyContinue' }
        if (-not (Get-WinEvent @logParams)) {
            Write-Verbose "[$computer] Log '$($source.LogName)' not found, skipping."
            continue
        }

        $filter = @{ LogName = $source.LogName; Level = $levels; StartTime = $since }
        try {
            $found = @(Get-WinEvent -FilterHashtable $filter -ComputerName $computer -ErrorAction Stop)
        }
        catch {
            if ($_.FullyQualifiedErrorId -like 'NoMatchingEventsFound*') { continue }
            Write-Warning "[$computer] Could not read '$($source.LogName)': $($_.Exception.Message)"
            continue
        }

        if ($source.ProviderPattern) {
            $found = @($found | Where-Object { $_.ProviderName -match $source.ProviderPattern })
        }
        Write-Verbose "[$computer] $($found.Count) matching event(s) in '$($source.LogName)'."

        foreach ($e in $found) {
            $events.Add([pscustomobject]@{
                ComputerName = $computer
                TimeCreated  = $e.TimeCreated
                LogName      = $e.LogName
                ProviderName = $e.ProviderName
                Id           = $e.Id
                Level        = $e.LevelDisplayName
                Message      = if ($e.Message) { ($e.Message -replace '\s+', ' ').Trim() } else { '(no message text)' }
            })
        }
    }
}

if ($Detailed) {
    $events | Sort-Object TimeCreated -Descending
    return
}

$events |
    Group-Object ComputerName, LogName, ProviderName, Id, Level |
    ForEach-Object {
        $sorted = @($_.Group | Sort-Object TimeCreated)
        $latest = $sorted[-1]
        $sample = $latest.Message
        if ($sample.Length -gt 300) { $sample = $sample.Substring(0, 300) + '...' }
        [pscustomobject]@{
            ComputerName  = $latest.ComputerName
            LogName       = $latest.LogName
            ProviderName  = $latest.ProviderName
            Id            = $latest.Id
            Level         = $latest.Level
            Count         = $_.Count
            FirstSeen     = $sorted[0].TimeCreated
            LastSeen      = $latest.TimeCreated
            SampleMessage = $sample
        }
    } |
    Sort-Object Count -Descending
