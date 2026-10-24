<#
.SYNOPSIS
    Builds a single HTML backup health report and can email it over SMTP.

.DESCRIPTION
    Runs the other toolkit scripts that sit in the same folder and combines their
    results into one self-contained HTML report:

      * VSS writer health           (Get-VssWriterHealth.ps1)
      * Volume / repository space   (Test-BackupDiskSpace.ps1)
      * Backup-related event errors (Get-WindowsBackupEventSummary.ps1)
      * Veeam job results           (Get-VeeamJobReport.ps1, only with -IncludeVeeam)

    Each section is collected on its own, so one failing check (for example the
    Veeam module not being installed) is shown as an error in its section and does
    not stop the report.

    You can also pass results you have already collected with -VssResult,
    -DiskResult, -EventResult and -VeeamResult. A section supplied this way is
    not collected again. This lets you build a report from data gathered on other
    machines, or by an RMM tool.

    The report is saved to -OutputPath. If -SmtpServer is given it is also sent as
    an HTML email. SMTP credentials are only accepted as a PSCredential and are
    never stored by the script.

.PARAMETER OutputPath
    Where to save the HTML file. Default: BackupReport_<timestamp>.html in the
    temp folder.

.PARAMETER Title
    Report title shown in the header and used in the email subject.

.PARAMETER RepositoryPath
    Paths passed to Test-BackupDiskSpace.ps1. If omitted, all fixed local
    volumes are checked.

.PARAMETER WarningPercent
    Free-space warning threshold passed to Test-BackupDiskSpace.ps1. Default 20.

.PARAMETER CriticalPercent
    Free-space critical threshold passed to Test-BackupDiskSpace.ps1. Default 10.

.PARAMETER Hours
    Look-back window for event logs and Veeam sessions. Default 24.

.PARAMETER IncludeVeeam
    Also run Get-VeeamJobReport.ps1. Needs the Veeam PowerShell module.

.PARAMETER VssResult
    Already-collected output of Get-VssWriterHealth.ps1.

.PARAMETER DiskResult
    Already-collected output of Test-BackupDiskSpace.ps1.

.PARAMETER EventResult
    Already-collected output of Get-WindowsBackupEventSummary.ps1.

.PARAMETER VeeamResult
    Already-collected output of Get-VeeamJobReport.ps1.

.PARAMETER SmtpServer
    SMTP relay to send the report through. If omitted, no email is sent.

.PARAMETER Port
    SMTP port. Default 587.

.PARAMETER UseSsl
    Use STARTTLS/SSL for the SMTP connection (recommended).

.PARAMETER From
    Sender address. Required with -SmtpServer.

.PARAMETER To
    One or more recipient addresses. Required with -SmtpServer.

.PARAMETER Credential
    SMTP credential (Get-Credential, or from a secret vault). Optional for
    anonymous or IP-allow-listed relays.

.EXAMPLE
    .\Send-BackupReport.ps1 -OutputPath C:\Reports\backup-health.html

    Builds the report for this server and saves it. No email is sent.

.EXAMPLE
    .\Send-BackupReport.ps1 -RepositoryPath 'D:\Backups', '\\nas01\repo' -IncludeVeeam -Hours 48

    Adds Veeam job results and checks two repositories over a 48-hour window.

.EXAMPLE
    $cred = Get-Credential
    .\Send-BackupReport.ps1 -SmtpServer smtp.office365.com -Port 587 -UseSsl -From 'alerts@example.com' -To 'it-team@example.com' -Credential $cred

    Builds the report and emails it through an authenticated SMTP relay.

.EXAMPLE
    .\Send-BackupReport.ps1 -WhatIf -SmtpServer relay.example.com -From a@example.com -To b@example.com

    Builds and saves the report and shows what would be sent, without sending it.

.OUTPUTS
    PSCustomObject with ReportPath, OverallStatus, per-section status and Emailed.

.NOTES
    Send-MailMessage is marked obsolete by Microsoft but still works on Windows
    PowerShell 5.1 and PowerShell 7. For Microsoft 365 tenants with SMTP AUTH
    turned off, use an SMTP relay connector or swap in Microsoft Graph sendMail.
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter()]
    [string]$OutputPath = (Join-Path ([System.IO.Path]::GetTempPath()) ("BackupReport_{0}.html" -f (Get-Date -Format 'yyyyMMdd_HHmmss'))),

    [Parameter()]
    [string]$Title = 'Backup Health Report',

    [Parameter()]
    [string[]]$RepositoryPath,

    [Parameter()]
    [ValidateRange(1, 99)]
    [int]$WarningPercent = 20,

    [Parameter()]
    [ValidateRange(0, 98)]
    [int]$CriticalPercent = 10,

    [Parameter()]
    [ValidateRange(1, 8760)]
    [int]$Hours = 24,

    [Parameter()]
    [switch]$IncludeVeeam,

    [Parameter()] [object[]]$VssResult,
    [Parameter()] [object[]]$DiskResult,
    [Parameter()] [object[]]$EventResult,
    [Parameter()] [object[]]$VeeamResult,

    [Parameter()]
    [string]$SmtpServer,

    [Parameter()]
    [ValidateRange(1, 65535)]
    [int]$Port = 587,

    [Parameter()]
    [switch]$UseSsl,

    [Parameter()]
    [string]$From,

    [Parameter()]
    [string[]]$To,

    [Parameter()]
    [System.Management.Automation.PSCredential]
    [System.Management.Automation.Credential()]
    $Credential = [System.Management.Automation.PSCredential]::Empty
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ($SmtpServer -and (-not $From -or -not $To)) {
    throw '-From and -To are required when -SmtpServer is given.'
}

$computer = if ($env:COMPUTERNAME) { $env:COMPUTERNAME } else { [System.Net.Dns]::GetHostName() }

function Invoke-ToolkitScript {
    <# Runs a sibling script and returns @{ Data; Error }, so one failing check never stops the report. #>
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter()][hashtable]$Arguments = @{}
    )
    $scriptPath = Join-Path $PSScriptRoot $Name
    try {
        if (-not (Test-Path -LiteralPath $scriptPath)) { throw "Script not found: $scriptPath" }
        $data = @(& $scriptPath @Arguments -ErrorAction Stop)
        return @{ Data = $data; Error = $null }
    }
    catch {
        return @{ Data = @(); Error = $_.Exception.Message }
    }
}

function ConvertTo-SafeHtml {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-HtmlTable {
    <# Builds an HTML table from objects. Columns are HTML-encoded and status cells get a CSS class. #>
    param(
        [Parameter()][AllowNull()][object[]]$Rows,
        [Parameter(Mandatory)][string[]]$Columns,
        [Parameter()][string]$StatusColumn
    )
    if (-not $Rows -or $Rows.Count -eq 0) { return "<p class='empty'>No items to report.</p>" }

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('<table><thead><tr>')
    foreach ($c in $Columns) { [void]$sb.Append("<th>$(ConvertTo-SafeHtml $c)</th>") }
    [void]$sb.Append('</tr></thead><tbody>')
    foreach ($row in $Rows) {
        [void]$sb.Append('<tr>')
        foreach ($c in $Columns) {
            $value = if ($row.PSObject.Properties[$c]) { $row.$c } else { $null }
            if ($value -is [datetime]) { $value = $value.ToString('yyyy-MM-dd HH:mm') }
            $class = if ($StatusColumn -and $c -eq $StatusColumn) { " class='s-$(ConvertTo-SafeHtml $value)'" } else { '' }
            [void]$sb.Append("<td$class>$(ConvertTo-SafeHtml $value)</td>")
        }
        [void]$sb.Append('</tr>')
    }
    [void]$sb.Append('</tbody></table>')
    return $sb.ToString()
}

function Get-SectionStatus {
    <# Reduces a section's rows to one status: Failed > Warning > OK. #>
    param([object[]]$Rows, [string]$StatusColumn, [string]$ErrorText, [string[]]$BadValues, [string[]]$WarnValues)
    if ($ErrorText) { return 'Error' }
    if (-not $Rows) { return 'OK' }
    $values = @($Rows | ForEach-Object { [string]$_.$StatusColumn })
    if ($values | Where-Object { $_ -in $BadValues }) { return 'Failed' }
    if ($values | Where-Object { $_ -in $WarnValues }) { return 'Warning' }
    return 'OK'
}

# --- Collect each section (unless results were passed in) -----------------------------
$sections = New-Object System.Collections.Generic.List[object]

# VSS writers
$vss = if ($PSBoundParameters.ContainsKey('VssResult')) { @{ Data = @($VssResult); Error = $null } }
       else { Invoke-ToolkitScript -Name 'Get-VssWriterHealth.ps1' }
$sections.Add([pscustomobject]@{
    Name   = 'VSS writers'
    Status = Get-SectionStatus -Rows $vss.Data -StatusColumn 'Status' -ErrorText $vss.Error -BadValues 'Failed' -WarnValues 'Warning'
    Error  = $vss.Error
    Html   = ConvertTo-HtmlTable -Rows @($vss.Data | Where-Object { $_.Status -ne 'Healthy' }) -Columns WriterName, State, LastError, Status -StatusColumn Status
    Note   = '{0} writer(s) checked; only writers that are not healthy are listed.' -f @($vss.Data).Count
})

# Disk / repository space
$diskArgs = @{ WarningPercent = $WarningPercent; CriticalPercent = $CriticalPercent }
if ($RepositoryPath) { $diskArgs.Path = $RepositoryPath }
$disk = if ($PSBoundParameters.ContainsKey('DiskResult')) { @{ Data = @($DiskResult); Error = $null } }
        else { Invoke-ToolkitScript -Name 'Test-BackupDiskSpace.ps1' -Arguments $diskArgs }
$sections.Add([pscustomobject]@{
    Name   = 'Storage capacity'
    Status = Get-SectionStatus -Rows $disk.Data -StatusColumn 'Status' -ErrorText $disk.Error -BadValues 'Critical' -WarnValues 'Warning'
    Error  = $disk.Error
    Html   = ConvertTo-HtmlTable -Rows $disk.Data -Columns Path, TotalGB, FreeGB, FreePercent, Status -StatusColumn Status
    Note   = "Thresholds: warning below $WarningPercent% free, critical below $CriticalPercent% free."
})

# Event log errors
$evt = if ($PSBoundParameters.ContainsKey('EventResult')) { @{ Data = @($EventResult); Error = $null } }
       else { Invoke-ToolkitScript -Name 'Get-WindowsBackupEventSummary.ps1' -Arguments @{ Hours = $Hours } }
$sections.Add([pscustomobject]@{
    Name   = "Backup / VSS event errors (last $Hours h)"
    Status = if ($evt.Error) { 'Error' } elseif (@($evt.Data).Count -gt 0) { 'Warning' } else { 'OK' }
    Error  = $evt.Error
    Html   = ConvertTo-HtmlTable -Rows $evt.Data -Columns Count, LogName, ProviderName, Id, LastSeen, SampleMessage
    Note   = 'Grouped by provider and event ID.'
})

# Veeam (optional)
if ($IncludeVeeam -or $PSBoundParameters.ContainsKey('VeeamResult')) {
    $veeam = if ($PSBoundParameters.ContainsKey('VeeamResult')) { @{ Data = @($VeeamResult); Error = $null } }
             else { Invoke-ToolkitScript -Name 'Get-VeeamJobReport.ps1' -Arguments @{ HoursBack = $Hours } }
    $sections.Add([pscustomobject]@{
        Name   = 'Veeam jobs'
        Status = Get-SectionStatus -Rows $veeam.Data -StatusColumn 'LastResult' -ErrorText $veeam.Error -BadValues 'Failed' -WarnValues 'Warning', 'None'
        Error  = $veeam.Error
        Html   = ConvertTo-HtmlTable -Rows $veeam.Data -Columns JobName, JobType, LastResult, LastStart, LastDuration, FailedInWindow -StatusColumn LastResult
        Note   = 'Last session result for each job; FailedInWindow counts failed sessions in the look-back window.'
    })
}

# --- Overall status and HTML --------------------------------------------------------------
$overall = 'OK'
if ($sections | Where-Object { $_.Status -in 'Failed', 'Error' }) { $overall = 'Failed' }
elseif ($sections | Where-Object Status -eq 'Warning') { $overall = 'Warning' }

$css = @'
body { font-family: Segoe UI, Arial, sans-serif; font-size: 13px; color: #222; margin: 24px; background: #f6f8fa; }
.wrap { max-width: 1000px; margin: auto; background: #fff; padding: 24px; border: 1px solid #d0d7de; border-radius: 6px; }
h1 { font-size: 20px; margin: 0 0 4px 0; }
h2 { font-size: 15px; margin: 24px 0 6px 0; border-bottom: 1px solid #d0d7de; padding-bottom: 4px; }
.meta, .note, .empty { color: #57606a; }
.badge { display: inline-block; padding: 2px 8px; border-radius: 10px; color: #fff; font-weight: 600; font-size: 12px; }
.b-OK { background: #1a7f37; } .b-Warning { background: #9a6700; } .b-Failed, .b-Error { background: #cf222e; }
table { border-collapse: collapse; width: 100%; margin-top: 6px; }
th { background: #1f3b57; color: #fff; text-align: left; padding: 6px 8px; font-weight: 600; }
td { border-bottom: 1px solid #eaeef2; padding: 5px 8px; vertical-align: top; }
.s-Healthy, .s-OK, .s-Success { color: #1a7f37; font-weight: 600; }
.s-Warning, .s-None { color: #9a6700; font-weight: 600; }
.s-Failed, .s-Critical { color: #cf222e; font-weight: 600; }
.error { color: #cf222e; }
'@

$body = New-Object System.Text.StringBuilder
[void]$body.Append("<!DOCTYPE html><html><head><meta charset='utf-8'><title>$(ConvertTo-SafeHtml $Title)</title><style>$css</style></head><body><div class='wrap'>")
[void]$body.Append("<h1>$(ConvertTo-SafeHtml $Title) <span class='badge b-$overall'>$overall</span></h1>")
[void]$body.Append("<p class='meta'>Computer: $(ConvertTo-SafeHtml $computer) | Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm zzz')</p>")
foreach ($s in $sections) {
    [void]$body.Append("<h2>$(ConvertTo-SafeHtml $s.Name) <span class='badge b-$($s.Status)'>$($s.Status)</span></h2>")
    if ($s.Error) {
        [void]$body.Append("<p class='error'>Check could not run: $(ConvertTo-SafeHtml $s.Error)</p>")
    }
    else {
        [void]$body.Append("<p class='note'>$(ConvertTo-SafeHtml $s.Note)</p>")
        [void]$body.Append($s.Html)
    }
}
[void]$body.Append("<p class='note' style='margin-top:24px'>Generated by backup-dr-powershell-toolkit.</p></div></body></html>")
$html = $body.ToString()

$outDir = Split-Path -Path $OutputPath -Parent
if ($outDir -and -not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force -WhatIf:$false | Out-Null }
Set-Content -LiteralPath $OutputPath -Value $html -Encoding UTF8 -WhatIf:$false
Write-Verbose "Report saved to $OutputPath"

# --- Optional email -----------------------------------------------------------------
$emailed = $false
if ($SmtpServer) {
    $subject = "[$overall] $Title - $computer - $(Get-Date -Format 'yyyy-MM-dd')"
    if ($PSCmdlet.ShouldProcess(($To -join ', '), "Send '$subject' via $SmtpServer")) {
        $mail = @{
            SmtpServer  = $SmtpServer
            Port        = $Port
            From        = $From
            To          = $To
            Subject     = $subject
            Body        = $html
            BodyAsHtml  = $true
            UseSsl      = [bool]$UseSsl
            ErrorAction = 'Stop'
        }
        if ($Credential -ne [System.Management.Automation.PSCredential]::Empty) { $mail.Credential = $Credential }
        try {
            Send-MailMessage @mail -WarningAction SilentlyContinue
            $emailed = $true
        }
        catch {
            Write-Error "Report saved to '$OutputPath' but the email failed: $($_.Exception.Message)"
        }
    }
}

[pscustomobject]@{
    ReportPath    = (Resolve-Path -LiteralPath $OutputPath).Path
    OverallStatus = $overall
    Sections      = ($sections | ForEach-Object { "$($_.Name): $($_.Status)" }) -join '; '
    Emailed       = $emailed
}
