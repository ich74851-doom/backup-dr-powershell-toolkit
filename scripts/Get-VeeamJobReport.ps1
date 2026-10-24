<#
.SYNOPSIS
    Summarises the latest results of Veeam Backup & Replication jobs and exports CSV/HTML.

.DESCRIPTION
    Uses the Veeam Backup & Replication PowerShell module (Veeam.Backup.PowerShell,
    v11 and later) or the legacy VeeamPSSnapIn snap-in (v10 and earlier) to build
    a per-job summary:

      * last session result (Success / Warning / Failed / None) and state
      * last session start time, end time and duration
      * how many sessions succeeded, warned or failed in the look-back window
      * whether the job schedule is enabled

    The summary is returned as objects. It can also be exported to CSV and/or a
    self-contained HTML file for a daily check or a client report.

    Run it on the VBR server, or on a machine with the VBR console installed and
    use -Server to connect remotely.

.PARAMETER Server
    VBR server to connect to. If omitted, the current or local connection is used.

.PARAMETER Credential
    Optional credential for -Server. Never hard-code credentials in the script; use
    Get-Credential or a secret store such as Microsoft.PowerShell.SecretManagement.

.PARAMETER HoursBack
    Look-back window, in hours, for counting sessions. Default 24.

.PARAMETER OutputDirectory
    If given, VeeamJobReport_<timestamp>.csv and .html are written to this folder
    (it is created if missing).

.PARAMETER Format
    Which files to write when -OutputDirectory is used: Csv, Html or Both (default).

.PARAMETER IncludeDisabled
    Include jobs whose schedule is disabled. These are left out by default.

.EXAMPLE
    .\Get-VeeamJobReport.ps1 | Format-Table JobName, LastResult, LastStart, FailedInWindow

    Shows the last result of every enabled job on the local VBR server.

.EXAMPLE
    .\Get-VeeamJobReport.ps1 -HoursBack 72 -OutputDirectory 'C:\Reports\Veeam'

    Counts sessions over the last 3 days and writes CSV and HTML reports.

.EXAMPLE
    .\Get-VeeamJobReport.ps1 -Server vbr01.contoso.local -Credential (Get-Credential) -Format Html -OutputDirectory .\out

    Connects to a remote VBR server and writes only the HTML report.

.OUTPUTS
    PSCustomObject per job.

.NOTES
    Get-VBRJob covers VM backup, replication and backup copy jobs. In Veeam v12,
    agent (computer) backup jobs are managed with Get-VBRComputerBackupJob, and
    Get-VBRJob may warn about them or leave them out. Extend the script if you
    need those jobs in the report.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [string]$Server,

    [Parameter()]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty,

    [Parameter()]
    [ValidateRange(1, 8760)]
    [int]$HoursBack = 24,

    [Parameter()]
    [string]$OutputDirectory,

    [Parameter()]
    [ValidateSet('Csv', 'Html', 'Both')]
    [string]$Format = 'Both',

    [Parameter()]
    [switch]$IncludeDisabled
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Import-VeeamPowerShell {
    <# Loads the Veeam module (v11+) or, failing that, the legacy snap-in (v10 and earlier). #>
    if (Get-Module -Name Veeam.Backup.PowerShell) { return }
    if (Get-Module -ListAvailable -Name Veeam.Backup.PowerShell) {
        Import-Module Veeam.Backup.PowerShell -DisableNameChecking -WarningAction SilentlyContinue
        return
    }
    if (Get-Command -Name Add-PSSnapin -ErrorAction SilentlyContinue) {
        if (Get-PSSnapin -Registered -Name VeeamPSSnapIn -ErrorAction SilentlyContinue) {
            Add-PSSnapin -Name VeeamPSSnapIn
            return
        }
    }
    throw 'Veeam PowerShell is not available. Run this on the VBR server or a machine with the Veeam Backup & Replication console installed.'
}

function Format-Duration {
    param([Nullable[datetime]]$Start, [Nullable[datetime]]$End)
    if ($null -eq $Start -or $null -eq $End -or $End -lt $Start) { return $null }
    $span = $End - $Start
    return '{0:00}:{1:00}:{2:00}' -f [math]::Floor($span.TotalHours), $span.Minutes, $span.Seconds
}

$connectedHere = $false
try {
    Import-VeeamPowerShell

    if ($Server) {
        $connectParams = @{ Server = $Server }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $connectParams.Credential = $Credential }
        Write-Verbose "Connecting to VBR server '$Server'."
        Connect-VBRServer @connectParams
        $connectedHere = $true
    }

    $since = (Get-Date).AddHours(-$HoursBack)

    Write-Verbose 'Reading jobs.'
    $jobs = @(Get-VBRJob -WarningAction SilentlyContinue)
    if (-not $IncludeDisabled) { $jobs = @($jobs | Where-Object { $_.IsScheduleEnabled }) }

    Write-Verbose "Reading backup sessions since $since."
    $sessionsByJob = @{}
    Get-VBRBackupSession | Where-Object { $_.CreationTime -ge $since } | ForEach-Object {
        if (-not $sessionsByJob.ContainsKey($_.JobName)) {
            $sessionsByJob[$_.JobName] = New-Object System.Collections.Generic.List[object]
        }
        $sessionsByJob[$_.JobName].Add($_)
    }

    $report = foreach ($job in $jobs) {
        $last = $job.FindLastSession()
        $windowSessions = if ($sessionsByJob.ContainsKey($job.Name)) { @($sessionsByJob[$job.Name]) } else { @() }

        $lastStart = $null; $lastEnd = $null; $lastResult = 'None'; $lastState = 'Never run'
        if ($null -ne $last) {
            $lastStart = $last.CreationTime
            # A running session reports an EndTime in 1900; treat that as "no end yet".
            if ($last.EndTime -gt $last.CreationTime) { $lastEnd = $last.EndTime }
            $lastResult = "$($last.Result)"
            $lastState = "$($last.State)"
        }

        [pscustomobject]@{
            JobName          = $job.Name
            JobType          = "$($job.JobType)"
            ScheduleEnabled  = [bool]$job.IsScheduleEnabled
            LastResult       = $lastResult
            LastState        = $lastState
            LastStart        = $lastStart
            LastEnd          = $lastEnd
            LastDuration     = Format-Duration -Start $lastStart -End $lastEnd
            SessionsInWindow = $windowSessions.Count
            SuccessInWindow  = @($windowSessions | Where-Object { "$($_.Result)" -eq 'Success' }).Count
            WarningInWindow  = @($windowSessions | Where-Object { "$($_.Result)" -eq 'Warning' }).Count
            FailedInWindow   = @($windowSessions | Where-Object { "$($_.Result)" -eq 'Failed' }).Count
        }
    }
    $report = @($report | Sort-Object @{ Expression = { switch ($_.LastResult) { 'Failed' { 0 } 'Warning' { 1 } 'None' { 2 } default { 3 } } } }, JobName)

    if ($OutputDirectory) {
        if (-not (Test-Path -LiteralPath $OutputDirectory)) {
            New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
        }
        $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
        $baseName = Join-Path $OutputDirectory "VeeamJobReport_$stamp"

        if ($Format -in 'Csv', 'Both') {
            $report | Export-Csv -LiteralPath "$baseName.csv" -NoTypeInformation -Encoding UTF8
            Write-Verbose "CSV written to $baseName.csv"
        }
        if ($Format -in 'Html', 'Both') {
            $total = $report.Count
            $failed = @($report | Where-Object LastResult -eq 'Failed').Count
            $warning = @($report | Where-Object LastResult -eq 'Warning').Count
            $success = @($report | Where-Object LastResult -eq 'Success').Count
            $rate = if ($total -gt 0) { [math]::Round(($success / $total) * 100, 1) } else { 0 }

            $css = @'
<style>
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; color: #222; margin: 24px; }
h1 { font-size: 20px; margin-bottom: 4px; }
p.meta { color: #666; margin-top: 0; }
table { border-collapse: collapse; width: 100%; }
th { background: #1f3b57; color: #fff; text-align: left; padding: 6px 8px; }
td { border-bottom: 1px solid #ddd; padding: 5px 8px; }
td.Success { color: #1a7f37; font-weight: 600; }
td.Warning { color: #9a6700; font-weight: 600; }
td.Failed  { color: #cf222e; font-weight: 600; }
</style>
'@
            $pre = "<h1>Veeam job report</h1><p class='meta'>Generated $(Get-Date -Format 'yyyy-MM-dd HH:mm') | Window: last $HoursBack h | " +
                "Jobs: $total | Success: $success | Warning: $warning | Failed: $failed | Last-run success rate: $rate%</p>"
            $html = $report | ConvertTo-Html -Head $css -PreContent $pre -Title 'Veeam job report' |
                ForEach-Object { $_ -replace '<td>(Success|Warning|Failed)</td>', '<td class="$1">$1</td>' }
            $html | Out-File -LiteralPath "$baseName.html" -Encoding utf8
            Write-Verbose "HTML written to $baseName.html"
        }
    }

    $report
}
catch {
    Write-Error "Get-VeeamJobReport failed: $($_.Exception.Message)"
}
finally {
    if ($connectedHere) {
        Disconnect-VBRServer -ErrorAction SilentlyContinue
    }
}
