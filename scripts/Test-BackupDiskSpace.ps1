<#
.SYNOPSIS
    Checks free space on local volumes or backup repository paths against thresholds.

.DESCRIPTION
    Backup jobs, retention merges and synthetic fulls fail when a repository or
    staging volume runs out of space. This script reports total and free capacity
    for each target and gives it a Status of OK, Warning or Critical.

    Targets can be:
      * nothing (the default): every fixed local volume is checked
      * local paths, for example 'D:\Backups' or 'E:\'
      * UNC paths to NAS or SMB repositories, for example '\\nas01\veeam-repo'

    On Windows, capacity is read with the Win32 GetDiskFreeSpaceEx API. That works
    for local paths and UNC shares and respects per-user quotas. On other platforms
    (PowerShell 7 on Linux or macOS) the mount point that holds each path is used.

.PARAMETER Path
    One or more paths to check. If omitted, all fixed local volumes are checked.

.PARAMETER WarningPercent
    Free-space percentage below which a target is reported as Warning. Default 20.

.PARAMETER CriticalPercent
    Free-space percentage below which a target is reported as Critical. Default 10.
    Must be lower than WarningPercent.

.PARAMETER MinFreeGB
    Optional absolute floor in GB. If free space is below this value the target is
    Critical whatever its percentage. Useful for very large repositories where 10%
    can still be many terabytes, or small volumes where it is not enough.

.PARAMETER ExitWithCode
    Exit with code 2 if any target is Critical, 1 if any is Warning, otherwise 0
    (for RMM script monitors).

.EXAMPLE
    .\Test-BackupDiskSpace.ps1

    Checks all fixed local volumes with the default 20% / 10% thresholds.

.EXAMPLE
    .\Test-BackupDiskSpace.ps1 -Path 'D:\Backups', '\\nas01\backup-repo' -WarningPercent 25 -CriticalPercent 15

    Checks a local repository and a NAS share with custom thresholds.

.EXAMPLE
    .\Test-BackupDiskSpace.ps1 -Path 'R:\' -MinFreeGB 500 -ExitWithCode

    Treats less than 500 GB free as Critical and returns an exit code for monitoring.

.OUTPUTS
    PSCustomObject with Path, TotalGB, UsedGB, FreeGB, FreePercent, Status and Message.
#>
[CmdletBinding()]
param(
    [Parameter(ValueFromPipeline, ValueFromPipelineByPropertyName)]
    [Alias('FullName', 'Root')]
    [string[]]$Path,

    [Parameter()]
    [ValidateRange(1, 99)]
    [int]$WarningPercent = 20,

    [Parameter()]
    [ValidateRange(0, 98)]
    [int]$CriticalPercent = 10,

    [Parameter()]
    [ValidateRange(0, [double]::MaxValue)]
    [double]$MinFreeGB = 0,

    [Parameter()]
    [switch]$ExitWithCode
)

begin {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'

    if ($CriticalPercent -ge $WarningPercent) {
        throw "CriticalPercent ($CriticalPercent) must be lower than WarningPercent ($WarningPercent)."
    }

    $onWindows = [System.Environment]::OSVersion.Platform -eq 'Win32NT'

    if ($onWindows -and -not ('BdrToolkit.DiskSpace' -as [type])) {
        # GetDiskFreeSpaceEx works for drive letters, mount points and UNC paths.
        Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace BdrToolkit {
    public static class DiskSpace {
        [DllImport("kernel32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool GetDiskFreeSpaceEx(
            string lpDirectoryName,
            out ulong lpFreeBytesAvailable,
            out ulong lpTotalNumberOfBytes,
            out ulong lpTotalNumberOfFreeBytes);
    }
}
'@
    }

    function Get-SpaceInfo {
        <# Returns total and free bytes for a path, or throws on failure. #>
        param([Parameter(Mandatory)][string]$TargetPath)

        if ($onWindows) {
            $directory = $TargetPath
            if (-not $directory.EndsWith('\')) { $directory += '\' }
            $freeToCaller = [uint64]0; $total = [uint64]0; $totalFree = [uint64]0
            $ok = [BdrToolkit.DiskSpace]::GetDiskFreeSpaceEx($directory, [ref]$freeToCaller, [ref]$total, [ref]$totalFree)
            if (-not $ok) {
                $code = [System.Runtime.InteropServices.Marshal]::GetLastWin32Error()
                throw (New-Object System.ComponentModel.Win32Exception($code)).Message
            }
            return [pscustomobject]@{ TotalBytes = [double]$total; FreeBytes = [double]$freeToCaller }
        }

        # Non-Windows: find the mount point with the longest matching root.
        $full = [System.IO.Path]::GetFullPath($TargetPath)
        $drive = [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.IsReady -and $full.StartsWith($_.RootDirectory.FullName) } |
            Sort-Object { $_.RootDirectory.FullName.Length } -Descending |
            Select-Object -First 1
        if (-not $drive) { throw "No mounted volume found for '$TargetPath'." }
        return [pscustomobject]@{ TotalBytes = [double]$drive.TotalSize; FreeBytes = [double]$drive.AvailableFreeSpace }
    }

    $allResults = New-Object System.Collections.Generic.List[object]
    $targets = New-Object System.Collections.Generic.List[string]
}

process {
    foreach ($p in $Path) { if ($p) { $targets.Add($p) } }
}

end {
    if ($targets.Count -eq 0) {
        # Default: every fixed, ready local volume.
        [System.IO.DriveInfo]::GetDrives() |
            Where-Object { $_.DriveType -eq [System.IO.DriveType]::Fixed -and $_.IsReady -and $_.TotalSize -gt 0 } |
            ForEach-Object { $targets.Add($_.RootDirectory.FullName) }
    }

    foreach ($target in $targets) {
        try {
            if (-not (Test-Path -LiteralPath $target)) {
                throw 'Path not found or not reachable (check the share, credentials and network).'
            }
            $info = Get-SpaceInfo -TargetPath $target
            if ($info.TotalBytes -le 0) { throw 'Volume reported a total size of 0 bytes.' }

            $freeGB = [math]::Round($info.FreeBytes / 1GB, 2)
            $totalGB = [math]::Round($info.TotalBytes / 1GB, 2)
            $freePct = [math]::Round(($info.FreeBytes / $info.TotalBytes) * 100, 1)

            $status = 'OK'
            $message = "Free space ${freePct}% (${freeGB} GB)."
            if ($freePct -lt $CriticalPercent -or ($MinFreeGB -gt 0 -and $freeGB -lt $MinFreeGB)) {
                $status = 'Critical'
                $message = "Free space ${freePct}% (${freeGB} GB) is below the critical threshold ($CriticalPercent% / $MinFreeGB GB)."
            }
            elseif ($freePct -lt $WarningPercent) {
                $status = 'Warning'
                $message = "Free space ${freePct}% (${freeGB} GB) is below the warning threshold ($WarningPercent%)."
            }

            $allResults.Add([pscustomobject]@{
                Path        = $target
                TotalGB     = $totalGB
                UsedGB      = [math]::Round($totalGB - $freeGB, 2)
                FreeGB      = $freeGB
                FreePercent = $freePct
                Status      = $status
                Message     = $message
            })
        }
        catch {
            $allResults.Add([pscustomobject]@{
                Path        = $target
                TotalGB     = $null
                UsedGB      = $null
                FreeGB      = $null
                FreePercent = $null
                Status      = 'Critical'
                Message     = "Unable to read capacity: $($_.Exception.Message)"
            })
        }
    }

    $allResults

    if ($ExitWithCode) {
        if ($allResults | Where-Object Status -eq 'Critical') { exit 2 }
        if ($allResults | Where-Object Status -eq 'Warning') { exit 1 }
        exit 0
    }
}
