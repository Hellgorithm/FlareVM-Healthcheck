#requires -version 5.1
<#
.SYNOPSIS
    Non-invasive health check for a FLARE-VM installation.

.DESCRIPTION
    Uses the exact configuration saved by the FLARE-VM installer in
    %VM_COMMON_DIR%\config.xml. It verifies the installer completion marker,
    final failed-package list, Chocolatey package registrations, lib-bad,
    FLARE-VM directories, log markers, and broken Tools shortcuts.

    It does not launch analysis tools, change FLARE-VM settings, repair
    packages, or require Internet access. Its only writes are its report files.

.PARAMETER ConfigPath
    Optional path to a FLARE-VM config.xml. By default, the script uses the
    config.xml saved in %VM_COMMON_DIR%. Supplying the config that was actually
    used is more accurate than comparing an older VM to today's online default.

.PARAMETER ReportDirectory
    Directory in which the text and JSON reports are written. Defaults to the
    current directory.

.EXAMPLE
    .\Test-FlareVM.ps1

.EXAMPLE
    .\Test-FlareVM.ps1 -ConfigPath C:\ProgramData\_VM\config.xml

.OUTPUTS
    Exit code 0: healthy
    Exit code 1: failed or incomplete
    Exit code 2: core checks passed, but warnings need review
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigPath,

    [Parameter(Mandatory = $false)]
    [string]$ReportDirectory = (Get-Location).Path
)

$ErrorActionPreference = 'Stop'
$script:Results = @()
$script:Details = [ordered]@{}

function Add-CheckResult {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('PASS', 'WARN', 'FAIL', 'INFO')]
        [string]$Status,

        [Parameter(Mandatory = $true)]
        [string]$Check,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    $script:Results += [pscustomobject]@{
        Status  = $Status
        Check   = $Check
        Message = $Message
    }
}

function Get-MachineEnvironmentValue {
    param([Parameter(Mandatory = $true)][string]$Name)
    return [Environment]::GetEnvironmentVariable(
        $Name,
        [EnvironmentVariableTarget]::Machine
    )
}

function Test-ShortcutTarget {
    param([Parameter(Mandatory = $true)][string]$TargetPath)

    if ([string]::IsNullOrWhiteSpace($TargetPath)) {
        return $true
    }

    $expanded = [Environment]::ExpandEnvironmentVariables($TargetPath.Trim('"'))
    if (Test-Path -LiteralPath $expanded) {
        return $true
    }

    if ($expanded -notmatch '[\\/]') {
        return $null -ne (Get-Command $expanded -ErrorAction SilentlyContinue)
    }

    return $false
}

function Get-ErrorLikeLines {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$Maximum = 20
    )

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return @()
    }

    # FLARE-VM's own logger emits "ERROR :". The additional patterns catch
    # standard Chocolatey/Boxstarter fatal and error records.
    $matches = @(Select-String -LiteralPath $Path -Pattern @(
        'ERROR\s*:',
        '\[ERROR\]',
        '\[FATAL\]',
        '\bFATAL\s*:'
    ) -ErrorAction SilentlyContinue)

    if ($matches.Count -le $Maximum) {
        return @($matches | ForEach-Object { $_.Line.Trim() })
    }

    return @($matches | Select-Object -Last $Maximum | ForEach-Object { $_.Line.Trim() })
}

try {
    $isAdmin = ([Security.Principal.WindowsPrincipal]
        [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator
        )
    if ($isAdmin) {
        Add-CheckResult 'PASS' 'Privileges' 'Running as Administrator.'
    }
    else {
        Add-CheckResult 'WARN' 'Privileges' 'Not running as Administrator; some log or shortcut checks may be incomplete.'
    }

    $vmCommonDir = Get-MachineEnvironmentValue 'VM_COMMON_DIR'
    if ([string]::IsNullOrWhiteSpace($vmCommonDir)) {
        $fallback = Join-Path $env:ProgramData '_VM'
        if (Test-Path -LiteralPath $fallback -PathType Container) {
            $vmCommonDir = $fallback
            Add-CheckResult 'WARN' 'VM_COMMON_DIR' "Machine environment variable is missing; using default path: $fallback"
        }
        else {
            Add-CheckResult 'FAIL' 'VM_COMMON_DIR' 'Machine environment variable is missing and the default directory does not exist.'
        }
    }
    elseif (Test-Path -LiteralPath $vmCommonDir -PathType Container) {
        Add-CheckResult 'PASS' 'VM_COMMON_DIR' $vmCommonDir
    }
    else {
        Add-CheckResult 'FAIL' 'VM_COMMON_DIR' "Configured directory does not exist: $vmCommonDir"
    }

    if (-not [string]::IsNullOrWhiteSpace($vmCommonDir)) {
        $failedPackagesPath = Join-Path $vmCommonDir 'failed_packages.txt'
        if (Test-Path -LiteralPath $failedPackagesPath -PathType Leaf) {
            $recordedFailures = @(Get-Content -LiteralPath $failedPackagesPath |
                ForEach-Object { $_.Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                Sort-Object -Unique)

            $script:Details['InstallerRecordedFailures'] = $recordedFailures
            if ($recordedFailures.Count -eq 0) {
                Add-CheckResult 'PASS' 'Completion marker' 'failed_packages.txt exists and is empty.'
            }
            else {
                Add-CheckResult 'FAIL' 'Completion marker' ("Installer recorded final package failures: " + ($recordedFailures -join ', '))
            }
        }
        else {
            Add-CheckResult 'FAIL' 'Completion marker' "Missing $failedPackagesPath. Current FLARE-VM creates this file at the end of package processing."
        }

        $flareLog = Join-Path $vmCommonDir 'log.txt'
        if (Test-Path -LiteralPath $flareLog -PathType Leaf) {
            $completeMarker = Select-String -LiteralPath $flareLog -SimpleMatch '[*] Install Complete!' -Quiet
            if ($completeMarker) {
                Add-CheckResult 'PASS' 'Final log marker' 'FLARE-VM logged "Install Complete!".'
            }
            else {
                Add-CheckResult 'FAIL' 'Final log marker' 'The FLARE-VM log does not contain the final "Install Complete!" marker.'
            }
        }
        else {
            Add-CheckResult 'FAIL' 'FLARE-VM log' "Missing $flareLog"
        }
    }

    if ([string]::IsNullOrWhiteSpace($ConfigPath) -and
        -not [string]::IsNullOrWhiteSpace($vmCommonDir)) {
        $ConfigPath = Join-Path $vmCommonDir 'config.xml'
    }

    $expectedPackages = @()
    if (-not [string]::IsNullOrWhiteSpace($ConfigPath) -and
        (Test-Path -LiteralPath $ConfigPath -PathType Leaf)) {
        $ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
        [xml]$config = Get-Content -LiteralPath $ConfigPath -Raw
        $expectedPackages = @($config.config.packages.package |
            ForEach-Object { [string]$_.name } |
            Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

        # These are installed by install.ps1 around the configured package set.
        $expectedPackages += @('common.vm', 'debloat.vm', 'installer.vm')
        $expectedPackages = @($expectedPackages | Sort-Object -Unique)

        $script:Details['ConfigPath'] = $ConfigPath
        $script:Details['ExpectedPackages'] = $expectedPackages
        Add-CheckResult 'PASS' 'Saved configuration' ("Parsed {0} configured/infrastructure packages from {1}" -f $expectedPackages.Count, $ConfigPath)
    }
    else {
        Add-CheckResult 'FAIL' 'Saved configuration' "Configuration file not found: $ConfigPath"
    }

    $choco = Get-Command 'choco.exe' -ErrorAction SilentlyContinue
    $installed = @{}
    if ($null -eq $choco) {
        Add-CheckResult 'FAIL' 'Chocolatey' 'choco.exe is not available on PATH.'
    }
    else {
        $chocoVersion = [string](& $choco.Source --version 2>$null | Select-Object -First 1)
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($chocoVersion)) {
            Add-CheckResult 'FAIL' 'Chocolatey' 'Chocolatey was found but its version query failed.'
        }
        else {
            Add-CheckResult 'PASS' 'Chocolatey' ("Version {0} at {1}" -f $chocoVersion.Trim(), $choco.Source)
        }

        $majorVersion = 2
        $parsedMajor = 0
        if ([int]::TryParse(($chocoVersion -split '\.')[0], [ref]$parsedMajor)) {
            $majorVersion = $parsedMajor
        }

        $listArguments = @('list', '--limit-output', '--no-color')
        if ($majorVersion -lt 2) {
            $listArguments = @('list', '--local-only', '--limit-output', '--no-color')
        }

        $listOutput = @(& $choco.Source @listArguments 2>&1)
        $listExitCode = $LASTEXITCODE
        if ($listExitCode -ne 0) {
            Add-CheckResult 'FAIL' 'Chocolatey inventory' ("choco list failed with exit code {0}." -f $listExitCode)
            $script:Details['ChocolateyListOutput'] = @($listOutput | ForEach-Object { [string]$_ })
        }
        else {
            foreach ($lineObject in $listOutput) {
                $line = [string]$lineObject
                if ($line -match '^([^|]+)\|(.+)$') {
                    $installed[$matches[1].Trim().ToLowerInvariant()] = $matches[2].Trim()
                }
            }
            $script:Details['InstalledPackageCount'] = $installed.Count
            Add-CheckResult 'PASS' 'Chocolatey inventory' ("Read {0} locally registered packages." -f $installed.Count)
        }
    }

    if ($expectedPackages.Count -gt 0 -and $installed.Count -gt 0) {
        $missingPackages = @($expectedPackages | Where-Object {
            -not $installed.ContainsKey($_.ToLowerInvariant())
        })
        $script:Details['MissingPackages'] = $missingPackages

        if ($missingPackages.Count -eq 0) {
            Add-CheckResult 'PASS' 'Expected packages' ("All {0} expected packages are registered with Chocolatey." -f $expectedPackages.Count)
        }
        else {
            Add-CheckResult 'FAIL' 'Expected packages' ("Missing {0}: {1}" -f $missingPackages.Count, ($missingPackages -join ', '))
        }
    }

    $libBad = Join-Path $env:ProgramData 'chocolatey\lib-bad'
    if (Test-Path -LiteralPath $libBad -PathType Container) {
        $badPackages = @(Get-ChildItem -LiteralPath $libBad -Directory -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty Name |
            Sort-Object -Unique)
        $script:Details['ChocolateyLibBad'] = $badPackages
        if ($badPackages.Count -eq 0) {
            Add-CheckResult 'PASS' 'Chocolatey lib-bad' 'No failed-package directories found.'
        }
        else {
            Add-CheckResult 'FAIL' 'Chocolatey lib-bad' ("Failed-package directories found: " + ($badPackages -join ', '))
        }
    }
    else {
        Add-CheckResult 'PASS' 'Chocolatey lib-bad' 'Directory is absent (no failed-package directories found).'
    }

    $toolListDir = Get-MachineEnvironmentValue 'TOOL_LIST_DIR'
    $rawToolsDir = Get-MachineEnvironmentValue 'RAW_TOOLS_DIR'
    foreach ($directoryCheck in @(
        [pscustomobject]@{ Name = 'TOOL_LIST_DIR'; Path = $toolListDir },
        [pscustomobject]@{ Name = 'RAW_TOOLS_DIR'; Path = $rawToolsDir }
    )) {
        if ([string]::IsNullOrWhiteSpace($directoryCheck.Path)) {
            Add-CheckResult 'FAIL' $directoryCheck.Name 'Machine environment variable is missing.'
        }
        elseif (Test-Path -LiteralPath $directoryCheck.Path -PathType Container) {
            Add-CheckResult 'PASS' $directoryCheck.Name $directoryCheck.Path
        }
        else {
            Add-CheckResult 'FAIL' $directoryCheck.Name ("Directory does not exist: " + $directoryCheck.Path)
        }
    }

    if (-not [string]::IsNullOrWhiteSpace($toolListDir) -and
        (Test-Path -LiteralPath $toolListDir -PathType Container)) {
        $shortcuts = @(Get-ChildItem -LiteralPath $toolListDir -Filter '*.lnk' -File -Recurse -ErrorAction SilentlyContinue)
        $brokenShortcuts = @()
        $shell = New-Object -ComObject WScript.Shell

        foreach ($shortcutFile in $shortcuts) {
            try {
                $shortcut = $shell.CreateShortcut($shortcutFile.FullName)
                $targetExists = Test-ShortcutTarget -TargetPath $shortcut.TargetPath
                $shortcutWorkingDirectory = [string]$shortcut.WorkingDirectory
                $workingDirectory = [Environment]::ExpandEnvironmentVariables($shortcutWorkingDirectory)
                $workingDirectoryExists = (
                    [string]::IsNullOrWhiteSpace($workingDirectory) -or
                    (Test-Path -LiteralPath $workingDirectory -PathType Container)
                )

                if (-not $targetExists -or -not $workingDirectoryExists) {
                    $reason = if (-not $targetExists) {
                        'Target does not exist'
                    }
                    else {
                        'Working directory does not exist'
                    }
                    $brokenShortcuts += [pscustomobject]@{
                        Shortcut        = $shortcutFile.FullName
                        Target          = $shortcut.TargetPath
                        WorkingDirectory = $shortcutWorkingDirectory
                        Reason          = $reason
                    }
                }
            }
            catch {
                $brokenShortcuts += [pscustomobject]@{
                    Shortcut         = $shortcutFile.FullName
                    Target           = '<could not read shortcut>'
                    WorkingDirectory = $null
                    Reason           = $_.Exception.Message
                }
            }
        }

        $script:Details['ShortcutCount'] = $shortcuts.Count
        $script:Details['BrokenShortcuts'] = $brokenShortcuts
        if ($shortcuts.Count -eq 0) {
            Add-CheckResult 'WARN' 'Tool shortcuts' 'No .lnk files were found under TOOL_LIST_DIR.'
        }
        elseif ($brokenShortcuts.Count -eq 0) {
            Add-CheckResult 'PASS' 'Tool shortcuts' ("All {0} shortcut targets exist." -f $shortcuts.Count)
        }
        else {
            Add-CheckResult 'WARN' 'Tool shortcuts' ("{0} of {1} shortcut targets are broken; see the JSON report." -f $brokenShortcuts.Count, $shortcuts.Count)
        }
    }

    $logPaths = [ordered]@{}
    if (-not [string]::IsNullOrWhiteSpace($vmCommonDir)) {
        $logPaths['FLARE-VM'] = Join-Path $vmCommonDir 'log.txt'
    }
    $logPaths['Chocolatey'] = Join-Path $env:ProgramData 'chocolatey\logs\chocolatey.log'
    $logPaths['Boxstarter'] = Join-Path $env:LocalAppData 'Boxstarter\boxstarter.log'

    foreach ($logName in $logPaths.Keys) {
        $logPath = $logPaths[$logName]
        if (Test-Path -LiteralPath $logPath -PathType Leaf) {
            Add-CheckResult 'PASS' ("{0} log" -f $logName) $logPath
            $errorLines = @(Get-ErrorLikeLines -Path $logPath -Maximum 20)
            $script:Details[("{0}RecentErrorLikeLines" -f $logName)] = $errorLines
            if ($errorLines.Count -gt 0) {
                # Logs are cumulative and installer retries can recover, so these
                # lines are warnings. The final marker/package checks decide FAIL.
                Add-CheckResult 'WARN' ("{0} log scan" -f $logName) ("Found error-like records; latest {0} saved in JSON report." -f $errorLines.Count)
            }
        }
        else {
            Add-CheckResult 'WARN' ("{0} log" -f $logName) ("Log not found: {0}" -f $logPath)
        }
    }
}
catch {
    Add-CheckResult 'FAIL' 'Health-check script' ("Unhandled check error: " + $_.Exception.Message)
    $script:Details['UnhandledError'] = ($_ | Out-String)
}

if (-not (Test-Path -LiteralPath $ReportDirectory -PathType Container)) {
    New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
}
$ReportDirectory = (Resolve-Path -LiteralPath $ReportDirectory).Path
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$textReportPath = Join-Path $ReportDirectory ("FlareVM-healthcheck-{0}.txt" -f $stamp)
$jsonReportPath = Join-Path $ReportDirectory ("FlareVM-healthcheck-{0}.json" -f $stamp)

$failCount = @($script:Results | Where-Object { $_.Status -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.Status -eq 'WARN' }).Count
$overall = if ($failCount -gt 0) { 'FAIL' } elseif ($warnCount -gt 0) { 'PASS WITH WARNINGS' } else { 'PASS' }

$summary = [pscustomobject]@{
    CheckedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    ComputerName = $env:COMPUTERNAME
    Overall      = $overall
    Failures     = $failCount
    Warnings     = $warnCount
    Results      = $script:Results
    Details      = $script:Details
}

$textLines = @()
$textLines += 'FLARE-VM HEALTH CHECK'
$textLines += ('Overall: {0} ({1} failure(s), {2} warning(s))' -f $overall, $failCount, $warnCount)
$textLines += ''
$textLines += ($script:Results | Format-Table -AutoSize -Wrap | Out-String -Width 240).TrimEnd()
$textLines += ''
$textLines += 'Notes:'
$textLines += '- FAIL means the installer did not reach its final marker, recorded failures, or expected package state is incomplete.'
$textLines += '- WARN log lines can be historical or recovered retries; inspect the JSON details and official logs.'
$textLines += '- This verifies package registration and shortcut targets. It cannot prove that every GUI opens or every plugin works.'
$textLines | Set-Content -LiteralPath $textReportPath -Encoding UTF8
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $jsonReportPath -Encoding UTF8

Write-Host ''
if ($overall -eq 'PASS') {
    Write-Host ("FLARE-VM health: {0}" -f $overall) -ForegroundColor Green
}
elseif ($overall -eq 'PASS WITH WARNINGS') {
    Write-Host ("FLARE-VM health: {0}" -f $overall) -ForegroundColor Yellow
}
else {
    Write-Host ("FLARE-VM health: {0}" -f $overall) -ForegroundColor Red
}

$script:Results | Format-Table -AutoSize -Wrap
Write-Host ("Text report: {0}" -f $textReportPath)
Write-Host ("JSON report: {0}" -f $jsonReportPath)

if ($failCount -gt 0) { exit 1 }
if ($warnCount -gt 0) { exit 2 }
exit 0
