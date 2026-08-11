# FLARE-VM Health Check

`Test-FlareVM.ps1` is a non-invasive PowerShell health check for a FLARE-VM installation. It determines whether installation reached its final stage, whether the configured packages are registered with Chocolatey, and whether common installation artifacts still exist.

The check works offline and does not launch tools, repair packages, or change FLARE-VM settings. Its only writes are timestamped report files.

## Requirements

- Windows PowerShell 5.1 or later
- An installed FLARE-VM environment
- Administrator PowerShell recommended for complete log and shortcut access

## Quick start

Copy `Test-FlareVM.ps1` into the VM, open Windows PowerShell as Administrator, and run:

```powershell
Unblock-File .\Test-FlareVM.ps1
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-FlareVM.ps1
$LASTEXITCODE
```

The script uses the installation's saved `%VM_COMMON_DIR%\config.xml` by default. This is more accurate than comparing an older VM against today's changing online package list.

To use a specific configuration:

```powershell
.\Test-FlareVM.ps1 -ConfigPath C:\ProgramData\_VM\config.xml
```

To place reports in a specific directory:

```powershell
.\Test-FlareVM.ps1 -ReportDirectory C:\Temp\FlareVM-Reports
```

## What it checks

- `%VM_COMMON_DIR%\failed_packages.txt` exists and contains no failures
- `%VM_COMMON_DIR%\log.txt` contains the final `Install Complete!` marker
- Every configured and infrastructure package is registered with Chocolatey
- Chocolatey's `lib-bad` contains no failed-package directories
- `VM_COMMON_DIR`, `TOOL_LIST_DIR`, and `RAW_TOOLS_DIR` exist
- Tool shortcut targets and working directories exist
- FLARE-VM, Chocolatey, and Boxstarter logs are available
- Recent error-like log records are included for review

## Results

| Exit code | Result | Meaning |
| --- | --- | --- |
| `0` | Pass | Core checks passed without warnings. |
| `1` | Fail | Installation is incomplete, recorded failures, or expected packages are missing. |
| `2` | Pass with warnings | Core checks passed, but logs or shortcut checks need review. |

Log files are cumulative, and FLARE-VM may retry a package successfully. For that reason, old error lines are warnings; the final marker, failed-package file, Chocolatey inventory, and `lib-bad` state determine failure.

## Reports

Each run creates two files in the current directory, or in `-ReportDirectory` when specified:

```text
FlareVM-healthcheck-YYYYMMDD-HHMMSS.txt
FlareVM-healthcheck-YYYYMMDD-HHMMSS.json
```

The text report is intended for quick review. The JSON report contains missing packages, broken shortcuts, and recent error-like log entries for troubleshooting or automation.

## Scope and limitations

The script verifies installation completion, package registration, expected directories, and shortcut targets. It deliberately does not start every GUI, debugger, plugin, or command-line tool, so a passing result cannot guarantee every tool's runtime behavior.

If the result is `FAIL`, review the three logs recommended by FLARE-VM:

```text
%VM_COMMON_DIR%\log.txt
%PROGRAMDATA%\chocolatey\logs\chocolatey.log
%LOCALAPPDATA%\Boxstarter\boxstarter.log
```

## Upstream references

- [FLARE-VM](https://github.com/mandiant/flare-vm)
- [FLARE-VM default configuration](https://github.com/mandiant/flare-vm/blob/main/config.xml)
- [VM-Packages installer](https://github.com/mandiant/VM-Packages/blob/main/packages/installer.vm/tools/chocolateyinstall.ps1)
- [Chocolatey `list` documentation](https://docs.chocolatey.org/en-us/choco/commands/list/)
