<#
.SYNOPSIS
    Reports the health of Volume Shadow Copy Service (VSS) writers and flags unhealthy ones.

.DESCRIPTION
    Runs 'vssadmin list writers' and converts its text output into objects, one per
    writer, with a computed Status of Healthy, Warning or Failed.

    Most image-level and application-aware backups (Veeam, Cove, Datto, Acronis,
    Windows Server Backup) depend on VSS. A writer stuck in a failed state is one of
    the most common causes of backup failures, so this is a good first check.

    The script can also parse output saved earlier with
    'vssadmin list writers > writers.txt' (see -Path). That is handy for offline
    review of output collected through an RMM tool, and for automated tests.

    Status rules:
      Healthy  - State [1] Stable and Last error 'No error'
      Warning  - a transitional 'Waiting for ...' state, or a stable writer that
                 reports a last error (for example a retryable or timeout error)
      Failed   - any state containing 'Failed' (state codes 6-15) or Unknown [0]

    Note: parsing expects English-language vssadmin output.

.PARAMETER Path
    Optional path to a text file that contains saved 'vssadmin list writers' output.
    If omitted, vssadmin is run live. Running it live needs Windows and an elevated
    (Run as Administrator) session.

.PARAMETER FailedOnly
    Return only writers whose Status is not Healthy.

.PARAMETER ExitWithCode
    After writing the objects, exit with code 1 if any writer is not Healthy, or
    with 0 if all are. This is useful for RMM script monitors (NinjaOne, Datto RMM,
    Syncro, ConnectWise) that alert on a non-zero exit code.

.EXAMPLE
    .\Get-VssWriterHealth.ps1

    Lists every VSS writer with its state, last error and computed status.

.EXAMPLE
    .\Get-VssWriterHealth.ps1 -FailedOnly | Format-Table WriterName, State, LastError

    Shows only the writers that need attention.

.EXAMPLE
    .\Get-VssWriterHealth.ps1 -Path .\writers.txt -FailedOnly

    Parses output that was saved earlier instead of running vssadmin.

.EXAMPLE
    .\Get-VssWriterHealth.ps1 -ExitWithCode

    Use as an RMM monitor: the exit code is 1 when any writer is unhealthy.

.OUTPUTS
    PSCustomObject with WriterName, WriterId, InstanceId, StateCode, State,
    LastError and Status.

.NOTES
    Typical remediation for a failed writer is to restart the service that owns it
    (for example 'SQL Server VSS Writer', 'Hyper-V Virtual Machine Management' or
    'Cryptographic Services'). Do this in a maintenance window, then re-run this
    script to confirm the writer returns to [1] Stable.
#>
[CmdletBinding()]
param(
    [Parameter()]
    [ValidateScript({ Test-Path -LiteralPath $_ -PathType Leaf })]
    [string]$Path,

    [Parameter()]
    [switch]$FailedOnly,

    [Parameter()]
    [switch]$ExitWithCode
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-VssWriterStatus {
    <# Works out Healthy / Warning / Failed from the state code, state text and last error. #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter()][AllowNull()]$StateCode,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$State,
        [Parameter()][AllowNull()][AllowEmptyString()][string]$LastError
    )

    if ($State -match 'Failed' -or ($null -ne $StateCode -and ($StateCode -eq 0 -or $StateCode -ge 6))) {
        return 'Failed'
    }
    if ($StateCode -eq 1 -and $LastError -eq 'No error') {
        return 'Healthy'
    }
    return 'Warning'
}

function ConvertFrom-VssAdminOutput {
    <# Parses the lines of 'vssadmin list writers' into one object per writer. #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string[]]$Line
    )

    $writers = New-Object System.Collections.Generic.List[object]
    $current = $null

    foreach ($text in $Line) {
        if ($text -match "^\s*Writer name:\s*'(?<name>.+)'\s*$") {
            # A new writer block starts here; keep the previous one.
            if ($null -ne $current) { $writers.Add($current) }
            $current = [ordered]@{
                WriterName = $Matches['name']
                WriterId   = $null
                InstanceId = $null
                StateCode  = $null
                State      = $null
                LastError  = $null
            }
            continue
        }

        if ($null -eq $current) { continue }   # skip the vssadmin banner lines

        if ($text -match '^\s*Writer Id:\s*(?<v>\{[0-9a-fA-F-]+\})') {
            $current.WriterId = $Matches['v']
        }
        elseif ($text -match '^\s*Writer Instance Id:\s*(?<v>\{[0-9a-fA-F-]+\})') {
            $current.InstanceId = $Matches['v']
        }
        elseif ($text -match '^\s*State:\s*\[(?<code>\d+)\]\s*(?<state>.+?)\s*$') {
            $current.StateCode = [int]$Matches['code']
            $current.State = $Matches['state']
        }
        elseif ($text -match '^\s*Last error:\s*(?<v>.+?)\s*$') {
            $current.LastError = $Matches['v']
        }
    }
    if ($null -ne $current) { $writers.Add($current) }

    foreach ($w in $writers) {
        $w['Status'] = Get-VssWriterStatus -StateCode $w.StateCode -State $w.State -LastError $w.LastError
        [pscustomobject]$w
    }
}

# --- Collect the raw vssadmin output ------------------------------------------------
if ($Path) {
    Write-Verbose "Parsing saved vssadmin output from '$Path'."
    $raw = Get-Content -LiteralPath $Path
}
else {
    if ([System.Environment]::OSVersion.Platform -ne 'Win32NT') {
        throw 'Running vssadmin needs Windows. Use -Path to parse saved output on other platforms.'
    }
    Write-Verbose "Running 'vssadmin list writers'."
    $raw = & vssadmin.exe list writers 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -ne 0) {
        throw "vssadmin exited with code $LASTEXITCODE. Run PowerShell as Administrator. Output: $($raw -join ' ')"
    }
}

$results = @(ConvertFrom-VssAdminOutput -Line @($raw))
if ($results.Count -eq 0) {
    Write-Warning 'No VSS writers were found in the output. Check that the output is English-language vssadmin output.'
}

$unhealthy = @($results | Where-Object { $_.Status -ne 'Healthy' })
Write-Verbose ("{0} writer(s) found, {1} not healthy." -f $results.Count, $unhealthy.Count)

if ($FailedOnly) { $unhealthy } else { $results }

if ($ExitWithCode) {
    if ($unhealthy.Count -gt 0) { exit 1 } else { exit 0 }
}
