[CmdletBinding()]
param(
    [string]$MsiPath = "\\sup.gubernia.local\SYSVOL\gubernia.local\scripts\GuberniaDesktop\Package.msi",
    [string]$Password = $env:GUBERNIA_DESKTOP_PASSWORD,
    [string]$LogRoot = "C:\ProgramData\GuberniaDesktopDeploy"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Password)) {
    throw "Password is required. Provide it through the -Password parameter or GUBERNIA_DESKTOP_PASSWORD."
}

$ProductName = "Gubernia Desktop"
$ServiceName = "Gubernia Desktop"
$ConfigPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\Gubernia Desktop\config\Gubernia Desktop.toml"
$RunLog = Join-Path $LogRoot "deploy.log"
$InstallLog = Join-Path $LogRoot "msi-install.log"

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-DeployLog {
    param([string]$Message)

    Ensure-Directory -Path $LogRoot
    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $RunLog -Value $line -Encoding UTF8
}

function Get-UninstallEntries {
    param([string]$DisplayNameRegex)

    $roots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )

    foreach ($root in $roots) {
        Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
            try {
                $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                if ($props.DisplayName -and $props.DisplayName -match $DisplayNameRegex) {
                    [pscustomobject]@{
                        KeyPath = $_.PSPath
                        DisplayName = [string]$props.DisplayName
                        DisplayVersion = [string]$props.DisplayVersion
                        InstallLocation = [string]$props.InstallLocation
                        QuietUninstallString = [string]$props.QuietUninstallString
                        UninstallString = [string]$props.UninstallString
                    }
                }
            } catch {
                Write-DeployLog "Failed to read uninstall entry '$($_.PSPath)': $($_.Exception.Message)"
            }
        }
    }
}

function Get-GuberniaInstall {
    $entries = @(Get-UninstallEntries -DisplayNameRegex ("^{0}$" -f [regex]::Escape($ProductName)))
    if ($entries.Count -eq 0) {
        return $null
    }

    foreach ($entry in $entries) {
        $exePath = ""
        if (-not [string]::IsNullOrWhiteSpace($entry.InstallLocation)) {
            $exePath = Join-Path $entry.InstallLocation "$ProductName.exe"
        }

        if ($exePath -and (Test-Path -LiteralPath $exePath)) {
            return [pscustomobject]@{
                Entry = $entry
                ExePath = $exePath
            }
        }
    }

    return [pscustomobject]@{
        Entry = $entries[0]
        ExePath = ""
    }
}

function Stop-OldRustDeskRuntime {
    $serviceNames = @("RustDesk", "rustdesk")
    foreach ($name in $serviceNames) {
        $service = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($service -and $service.Status -ne "Stopped") {
            Write-DeployLog "Stopping old service '$name'."
            Stop-Service -Name $name -Force -ErrorAction SilentlyContinue
            try {
                $service.WaitForStatus("Stopped", [TimeSpan]::FromSeconds(30))
            } catch {
                Write-DeployLog "Service '$name' did not stop cleanly: $($_.Exception.Message)"
            }
        }
    }

    Get-Process -Name "rustdesk", "RustDesk" -ErrorAction SilentlyContinue | ForEach-Object {
        Write-DeployLog "Stopping old process '$($_.ProcessName)' PID $($_.Id)."
        Stop-Process -Id $_.Id -Force -ErrorAction SilentlyContinue
    }
}

function Convert-ToQuietUninstallCommand {
    param([string]$Command)

    if ([string]::IsNullOrWhiteSpace($Command)) {
        return ""
    }

    $result = $Command.Trim()
    if ($result -match "(?i)msiexec(\.exe)?") {
        if ($result -match "(?i)\s/i(\s|`")" -and $result -notmatch "(?i)\s/x(\s|`")") {
            $result = $result -replace "(?i)\s/i(\s|`")", " /x`$1"
        }
        if ($result -notmatch "(?i)\s/qn") {
            $result += " /qn"
        }
        if ($result -notmatch "(?i)\s/norestart") {
            $result += " /norestart"
        }
    }

    return $result
}

function Remove-OldRustDesk {
    Stop-OldRustDeskRuntime

    $entries = @(Get-UninstallEntries -DisplayNameRegex "(?i)^RustDesk(\b|$)" | Where-Object {
        $_.DisplayName -notmatch ("^{0}$" -f [regex]::Escape($ProductName))
    } | Sort-Object DisplayName -Unique)

    if ($entries.Count -eq 0) {
        Write-DeployLog "Old RustDesk is not installed."
        return
    }

    foreach ($entry in $entries) {
        $command = $entry.QuietUninstallString
        if ([string]::IsNullOrWhiteSpace($command)) {
            $command = $entry.UninstallString
        }
        $command = Convert-ToQuietUninstallCommand -Command $command
        if ([string]::IsNullOrWhiteSpace($command)) {
            Write-DeployLog "No uninstall command for '$($entry.DisplayName)'."
            continue
        }

        Write-DeployLog "Uninstalling '$($entry.DisplayName)' with command: $command"
        $process = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $command) -Wait -PassThru -WindowStyle Hidden
        $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
        if ($exitCode -notin 0, 3010, 1641) {
            throw "Uninstall failed for '$($entry.DisplayName)' with exit code $exitCode."
        }
        Write-DeployLog "Uninstalled '$($entry.DisplayName)' with exit code $exitCode."
    }
}

function Install-GuberniaDesktop {
    if (-not (Test-Path -LiteralPath $MsiPath)) {
        throw "MSI not found: $MsiPath"
    }

    Write-DeployLog "Installing '$ProductName' from '$MsiPath'."
    $args = @(
        "/i"
        "`"$MsiPath`""
        "/qn"
        "/norestart"
        "/l*v"
        "`"$InstallLog`""
        "LAUNCH_TRAY_APP=N"
        "DESKTOPSHORTCUTS=1"
        "STARTMENUSHORTCUTS=1"
        "PRINTER=1"
    ) -join " "

    $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru -WindowStyle Hidden
    $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
    if ($exitCode -notin 0, 3010, 1641) {
        throw "MSI install failed with exit code $exitCode. Log: $InstallLog"
    }
    Write-DeployLog "MSI install completed with exit code $exitCode."
}

function Invoke-AfterInstall {
    param([string]$ExePath)

    if (-not (Test-Path -LiteralPath $ExePath)) {
        throw "Application executable not found: $ExePath"
    }

    Write-DeployLog "Running after-install: '$ExePath --after-install'."
    $process = Start-Process -FilePath $ExePath -ArgumentList "--after-install" -Wait -PassThru -WindowStyle Hidden
    $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
    if ($exitCode -ne 0) {
        throw "After-install failed with exit code $exitCode."
    }
}

function Get-TomlValue {
    param(
        [string]$Path,
        [string]$Name
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return ""
    }

    $pattern = "^\s*$([regex]::Escape($Name))\s*=\s*'([^']*)'"
    foreach ($line in Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue) {
        if ($line -match $pattern) {
            return $matches[1]
        }
    }

    return ""
}

function Get-ExpectedPasswordStorage {
    param(
        [string]$PlainPassword,
        [string]$Salt
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainPassword + $Salt)
        return "01" + [Convert]::ToBase64String($sha.ComputeHash($bytes))
    } finally {
        $sha.Dispose()
    }
}

function Test-PermanentPassword {
    if ([string]::IsNullOrWhiteSpace($Password)) {
        return $true
    }

    $storage = Get-TomlValue -Path $ConfigPath -Name "password"
    $salt = Get-TomlValue -Path $ConfigPath -Name "salt"
    if ([string]::IsNullOrWhiteSpace($storage) -or [string]::IsNullOrWhiteSpace($salt)) {
        return $false
    }

    return $storage -eq (Get-ExpectedPasswordStorage -PlainPassword $Password -Salt $salt)
}

function Ensure-ServiceRunning {
    $service = Get-Service -Name $ServiceName -ErrorAction SilentlyContinue
    if (-not $service) {
        Write-DeployLog "Service '$ServiceName' not found."
        return
    }

    if ($service.Status -ne "Running") {
        Write-DeployLog "Starting service '$ServiceName'."
        Start-Service -Name $ServiceName -ErrorAction Stop
        (Get-Service -Name $ServiceName).WaitForStatus("Running", [TimeSpan]::FromSeconds(30))
    }
}

function Set-PermanentPassword {
    param([string]$ExePath)

    if ([string]::IsNullOrWhiteSpace($Password)) {
        Write-DeployLog "Password is empty; skipping password setup."
        return
    }

    Ensure-ServiceRunning

    Write-DeployLog "Setting permanent password."
    $passwordLog = Join-Path $LogRoot "password.log"
    & $ExePath --password $Password *> $passwordLog
    $exitCode = if ($null -eq $LASTEXITCODE) { 0 } else { [int]$LASTEXITCODE }
    if ($exitCode -ne 0) {
        $output = if (Test-Path -LiteralPath $passwordLog) { Get-Content -LiteralPath $passwordLog -Raw -ErrorAction SilentlyContinue } else { "" }
        throw "Password command failed with exit code $exitCode. Output: $output"
    }

    Start-Sleep -Seconds 2
    if (-not (Test-PermanentPassword)) {
        throw "Password was not persisted or verification failed. Config: $ConfigPath"
    }

    Write-DeployLog "Permanent password verified in '$ConfigPath'."
}

try {
    Ensure-Directory -Path $LogRoot
    Write-DeployLog "----- Deployment run started on $env:COMPUTERNAME as $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name) -----"

    $installed = Get-GuberniaInstall
    if ($installed -and $installed.ExePath -and (Test-PermanentPassword)) {
        Write-DeployLog "'$ProductName' is already installed and password is verified. Nothing to do."
        exit 0
    }

    Remove-OldRustDesk

    $installed = Get-GuberniaInstall
    if (-not $installed -or -not $installed.ExePath) {
        Install-GuberniaDesktop
        $installed = Get-GuberniaInstall
    } else {
        Write-DeployLog "'$ProductName' is already installed; skipping MSI install."
    }

    if (-not $installed -or -not $installed.ExePath) {
        throw "'$ProductName' installation is not registered or executable is missing."
    }

    Invoke-AfterInstall -ExePath $installed.ExePath
    Set-PermanentPassword -ExePath $installed.ExePath

    Write-DeployLog "Deployment completed successfully."
    exit 0
} catch {
    Write-DeployLog "Deployment failed: $($_.Exception.Message)"
    exit 1
}
