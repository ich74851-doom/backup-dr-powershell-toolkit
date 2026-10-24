#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }
<#
    Pester tests that run on any platform (Windows, Linux, macOS).
    Run with:  Invoke-Pester -Path ./tests -Output Detailed
#>

BeforeAll {
    $script:root = Split-Path -Parent $PSScriptRoot
    $script:scripts = Join-Path $script:root 'scripts'
    $script:fixture = Join-Path $PSScriptRoot 'fixtures/vssadmin-writers-sample.txt'
}

Describe 'All scripts' {
    It '<_> parses without syntax errors' -ForEach @(
        Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') -Filter *.ps1 | ForEach-Object Name
    ) {
        $tokens = $null; $errors = $null
        [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $script:scripts $_), [ref]$tokens, [ref]$errors) | Out-Null
        $errors | Should -BeNullOrEmpty
    }

    It '<_> has comment-based help with a synopsis' -ForEach @(
        Get-ChildItem -Path (Join-Path (Split-Path -Parent $PSScriptRoot) 'scripts') -Filter *.ps1 | ForEach-Object Name
    ) {
        (Get-Content -Raw (Join-Path $script:scripts $_)) | Should -Match '\.SYNOPSIS'
    }
}

Describe 'Get-VssWriterHealth.ps1 (fixture parsing)' {
    BeforeAll {
        $script:writers = @(& (Join-Path $script:scripts 'Get-VssWriterHealth.ps1') -Path $script:fixture)
    }

    It 'finds every writer in the fixture' {
        $script:writers.Count | Should -Be 4
    }

    It 'marks a stable writer with no error as Healthy' {
        ($script:writers | Where-Object WriterName -eq 'Task Scheduler Writer').Status | Should -Be 'Healthy'
    }

    It 'marks a failed writer as Failed and keeps the last error' {
        $w = $script:writers | Where-Object WriterName -eq 'SqlServerWriter'
        $w.Status | Should -Be 'Failed'
        $w.StateCode | Should -Be 8
        $w.LastError | Should -Be 'Timed out'
    }

    It 'marks a waiting writer as Warning' {
        ($script:writers | Where-Object WriterName -eq 'Microsoft Hyper-V VSS Writer').Status | Should -Be 'Warning'
    }

    It 'marks a stable writer that reports an error as Warning' {
        ($script:writers | Where-Object WriterName -eq 'Registry Writer').Status | Should -Be 'Warning'
    }

    It '-FailedOnly returns only writers that are not healthy' {
        $failed = @(& (Join-Path $script:scripts 'Get-VssWriterHealth.ps1') -Path $script:fixture -FailedOnly)
        $failed.Count | Should -Be 3
        $failed.Status | Should -Not -Contain 'Healthy'
    }
}

Describe 'Test-BackupDiskSpace.ps1' {
    It 'returns a result for an existing path' {
        $r = & (Join-Path $script:scripts 'Test-BackupDiskSpace.ps1') -Path $PSScriptRoot
        $r.Status | Should -BeIn 'OK', 'Warning', 'Critical'
        $r.TotalGB | Should -BeGreaterThan 0
    }

    It 'reports an unreachable path as Critical instead of throwing' {
        $missing = Join-Path $PSScriptRoot 'does-not-exist-12345'
        $r = & (Join-Path $script:scripts 'Test-BackupDiskSpace.ps1') -Path $missing
        $r.Status | Should -Be 'Critical'
    }

    It 'rejects a critical threshold that is not below the warning threshold' {
        { & (Join-Path $script:scripts 'Test-BackupDiskSpace.ps1') -WarningPercent 10 -CriticalPercent 20 } | Should -Throw
    }
}

Describe 'Send-BackupReport.ps1 (pre-collected data)' {
    It 'writes an HTML report and works out the overall status' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-report-{0}.html" -f [guid]::NewGuid())
        try {
            $vss = & (Join-Path $script:scripts 'Get-VssWriterHealth.ps1') -Path $script:fixture
            $disk = [pscustomobject]@{ Path = 'X:\'; TotalGB = 100; FreeGB = 50; FreePercent = 50; Status = 'OK' }
            $r = & (Join-Path $script:scripts 'Send-BackupReport.ps1') -OutputPath $out -VssResult $vss -DiskResult $disk -EventResult @()
            $r.OverallStatus | Should -Be 'Failed'
            $out | Should -Exist
            (Get-Content -Raw $out) | Should -Match 'SqlServerWriter'
        }
        finally {
            Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
        }
    }

    It 'HTML-encodes values' {
        $out = Join-Path ([System.IO.Path]::GetTempPath()) ("pester-report-{0}.html" -f [guid]::NewGuid())
        try {
            $disk = [pscustomobject]@{ Path = '<script>x</script>'; TotalGB = 1; FreeGB = 1; FreePercent = 100; Status = 'OK' }
            & (Join-Path $script:scripts 'Send-BackupReport.ps1') -OutputPath $out -VssResult @() -DiskResult $disk -EventResult @() | Out-Null
            (Get-Content -Raw $out) | Should -Not -Match '<script>x</script>'
        }
        finally {
            Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue
        }
    }
}
