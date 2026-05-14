[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ComputerListPath,
    [switch]$RetryFailed,
    [string]$FailedHostsPath,
    [string]$MsiPath,
    [string]$Password = $env:GUBERNIA_DESKTOP_PASSWORD,
    [int]$ThrottleLimit = 16,
    [pscredential]$Credential,
    [string]$LogRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Password)) {
    throw "Password is required. Pass -Password or set GUBERNIA_DESKTOP_PASSWORD in the current process."
}

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptRoot = $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($ComputerListPath)) {
    $ComputerListPath = Join-Path $scriptRoot "hosts.txt"
}

if ([string]::IsNullOrWhiteSpace($FailedHostsPath)) {
    $FailedHostsPath = Join-Path $scriptRoot "failed-hosts.txt"
}

if ([string]::IsNullOrWhiteSpace($LogRoot)) {
    $LogRoot = Join-Path $scriptRoot "logs"
}

function Resolve-MsiPath {
    param([string]$Path)

    if (-not [string]::IsNullOrWhiteSpace($Path)) {
        return (Resolve-Path -LiteralPath $Path).Path
    }

    $defaultPath = Join-Path $scriptRoot "Package\bin\x64\Release\ru-ru\Package.msi"
    return (Resolve-Path -LiteralPath $defaultPath).Path
}

function Get-TargetHosts {
    param(
        [string[]]$InlineHosts,
        [string]$ListPath,
        [switch]$UseFailed,
        [string]$FailedPath
    )

    if ($InlineHosts -and $InlineHosts.Count -gt 0) {
        return $InlineHosts | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    $pathToUse = $ListPath
    if ($UseFailed) {
        $pathToUse = $FailedPath
    }

    if (-not (Test-Path -LiteralPath $pathToUse)) {
        throw "Host list file not found: $pathToUse"
    }

    if ($pathToUse.ToLowerInvariant().EndsWith(".csv")) {
        $rows = Import-Csv -LiteralPath $pathToUse
        if ($rows.Count -eq 0) {
            return @()
        }

        $properties = $rows[0].PSObject.Properties.Name
        if ($properties -contains "ComputerName") {
            return $rows.ComputerName | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }

        $firstColumn = $properties[0]
        return $rows | ForEach-Object { $_.$firstColumn.ToString().Trim() } | Where-Object { $_ }
    }

    return Get-Content -LiteralPath $pathToUse | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -and -not $_.StartsWith("#")
    }
}

function Ensure-Directory {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-RunLog {
    param(
        [string]$Message,
        [string]$LogPath
    )

    $line = "[{0}] {1}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Message
    Add-Content -LiteralPath $LogPath -Value $line
    Write-Host $Message
}

function New-ServiceGuardScript {
    param([string]$ServiceName)

    @"
`$service = Get-Service -Name '$ServiceName' -ErrorAction Stop
if (`$service.Status -ne 'Stopped') {
    Stop-Service -Name '$ServiceName' -Force -ErrorAction Stop
    `$service.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30))
}
Start-Service -Name '$ServiceName' -ErrorAction Stop
(Get-Service -Name '$ServiceName').WaitForStatus('Running', [TimeSpan]::FromSeconds(30))
"@
}

$msiPathResolved = Resolve-MsiPath -Path $MsiPath
$runStamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path $LogRoot $runStamp
Ensure-Directory -Path $runDir

$summaryCsv = Join-Path $runDir "summary.csv"
$runLog = Join-Path $runDir "run.log"
$localFailedHostsPath = if ([string]::IsNullOrWhiteSpace($FailedHostsPath)) {
    Join-Path $runDir "failed-hosts.txt"
} else {
    $FailedHostsPath
}

$hosts = Get-TargetHosts -InlineHosts $ComputerName -ListPath $ComputerListPath -UseFailed:$RetryFailed -FailedPath $localFailedHostsPath
if (-not $hosts -or $hosts.Count -eq 0) {
    throw "No target hosts found."
}

Write-RunLog -LogPath $runLog -Message "MSI: $msiPathResolved"
Write-RunLog -LogPath $runLog -Message "Targets: $($hosts -join ', ')"
Write-RunLog -LogPath $runLog -Message "Run directory: $runDir"

$results = New-Object System.Collections.Generic.List[object]
$failedHosts = New-Object System.Collections.Generic.List[string]
$successHosts = New-Object System.Collections.Generic.List[string]

$sessionParams = @{}
if ($Credential) {
    $sessionParams.Credential = $Credential
}

$jobScript = {
    param(
        [string]$TargetHost,
        [string]$MsiPathResolved,
        [string]$Password,
        [hashtable]$SessionParams,
        [string]$RunDir
    )

    $startTime = Get-Date
    $status = "Failed"
    $stage = "init"
    $errorText = ""
    $remoteLogCopy = ""
    $installedExe = ""
    $uninstalled = @()
    $installExitCode = $null
    $passwordExitCode = $null
    $afterInstallExitCode = $null

    $emit = {
        param([string]$Message)
        [pscustomobject]@{ Kind = "log"; Text = $Message }
    }

    & $emit "[$TargetHost] starting"

    $session = $null
    try {
        $session = New-PSSession -ComputerName $TargetHost @SessionParams
        $stage = "copy-msi"

        $remoteMsiPath = Join-Path $env:WINDIR "Temp\GuberniaDesktop.msi"
        $remoteLogPath = Join-Path $env:WINDIR "Temp\GuberniaDesktop-install.log"

        Copy-Item -LiteralPath $MsiPathResolved -Destination $remoteMsiPath -ToSession $session -Force

        $stage = "remove-old"
        $uninstallResult = Invoke-Command -Session $session -ScriptBlock {
            $appDataRoot = Join-Path $env:APPDATA "Gubernia Desktop"
            $configFiles = @(
                (Join-Path $appDataRoot "Gubernia Desktop.toml"),
                (Join-Path $appDataRoot "Gubernia Desktop2.toml")
            )

            foreach ($file in $configFiles) {
                if (Test-Path -LiteralPath $file) {
                    Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
                }
            }

            if (Test-Path -LiteralPath $appDataRoot) {
                Remove-Item -LiteralPath $appDataRoot -Recurse -Force -ErrorAction SilentlyContinue
            }

            $pattern = '(?i)RustDesk|Gubernia Desktop'
            $roots = @(
                "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
                "HKLM:\Software\Wow6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
            )

            $items = foreach ($root in $roots) {
                Get-ChildItem -LiteralPath $root -ErrorAction SilentlyContinue | ForEach-Object {
                    try {
                        $props = Get-ItemProperty -LiteralPath $_.PSPath -ErrorAction Stop
                        if ($props.DisplayName -and $props.DisplayName -match $pattern) {
                            [pscustomobject]@{
                                DisplayName = $props.DisplayName
                                QuietUninstallString = $props.QuietUninstallString
                                UninstallString = $props.UninstallString
                            }
                        }
                    } catch {
                    }
                }
            }

            $unique = $items | Sort-Object DisplayName -Unique
            $removed = New-Object System.Collections.Generic.List[string]

            foreach ($entry in $unique) {
                $command = $entry.QuietUninstallString
                if ([string]::IsNullOrWhiteSpace($command)) {
                    $command = $entry.UninstallString
                }
                if ([string]::IsNullOrWhiteSpace($command)) {
                    continue
                }

                if ($command -match '(?i)msiexec(\.exe)?') {
                    if ($command -match '(?i)\s/i(\s|")' -and $command -notmatch '(?i)\s/x(\s|")') {
                        $command = $command -replace '(?i)\s/i(\s|")', ' /x$1'
                    }
                    if ($command -notmatch '(?i)\s/qn') {
                        $command += ' /qn'
                    }
                    if ($command -notmatch '(?i)\s/norestart') {
                        $command += ' /norestart'
                    }
                }

                $process = Start-Process -FilePath "cmd.exe" -ArgumentList @("/c", $command) -Wait -PassThru
                $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
                if ($exitCode -notin 0, 3010, 1641) {
                    throw "Uninstall failed for $($entry.DisplayName) with exit code $exitCode"
                }
                $removed.Add($entry.DisplayName)
            }

            [pscustomobject]@{
                Removed = $removed
                ConfigRoot = $appDataRoot
            }
        }
        $uninstalled = @($uninstallResult.Removed)

        $stage = "install-msi"
        $installExitCode = Invoke-Command -Session $session -ScriptBlock {
            param($RemoteMsiPath, $RemoteLogPath)
            $args = @(
                "/i"
                "`"$RemoteMsiPath`""
                "/qn"
                "/norestart"
                "/l*v"
                "`"$RemoteLogPath`""
                "LAUNCH_TRAY_APP=N"
                "DESKTOPSHORTCUTS=1"
                "STARTMENUSHORTCUTS=1"
                "PRINTER=1"
            ) -join " "

            $process = Start-Process -FilePath "msiexec.exe" -ArgumentList $args -Wait -PassThru
            if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
        } -ArgumentList $remoteMsiPath, $remoteLogPath

        if ($installExitCode -notin 0, 3010, 1641) {
            throw "MSI install failed with exit code $installExitCode"
        }

        try {
            Copy-Item -FromSession $session -LiteralPath $remoteLogPath -Destination (Join-Path $RunDir "$TargetHost-install.log") -Force
            $remoteLogCopy = Join-Path $RunDir "$TargetHost-install.log"
        } catch {
            & $emit "[$TargetHost] failed to copy install log: $($_.Exception.Message)"
        }

        if ($installExitCode -in 3010, 1641) {
            $status = "Success"
            & $emit "[$TargetHost] install completed with reboot required ($installExitCode)"
            return [pscustomobject]@{
                ComputerName = $TargetHost
                Status = $status
                Stage = "install-msi"
                InstallExitCode = $installExitCode
                AfterInstallExitCode = $null
                PasswordExitCode = $null
                Removed = ($uninstalled -join "; ")
                ExePath = ""
                LogFile = $remoteLogCopy
                Error = ""
                DurationSec = [int]((Get-Date) - $startTime).TotalSeconds
                Log = @()
            }
        }

        $stage = "after-install"
        $afterInstallExitCode = Invoke-Command -Session $session -ScriptBlock {
            $uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Gubernia Desktop"
            if (-not (Test-Path -LiteralPath $uninstallKey)) {
                throw "Uninstall key not found: $uninstallKey"
            }

            $installLocation = (Get-ItemProperty -LiteralPath $uninstallKey).InstallLocation
            if ([string]::IsNullOrWhiteSpace($installLocation)) {
                throw "InstallLocation is empty in $uninstallKey"
            }

            $exePath = Join-Path $installLocation "Gubernia Desktop.exe"
            if (-not (Test-Path -LiteralPath $exePath)) {
                throw "Application executable not found: $exePath"
            }

            $process = Start-Process -FilePath $exePath -ArgumentList "--after-install" -Wait -PassThru
            if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
        }

        if ($afterInstallExitCode -ne 0) {
            throw "After-install step failed with exit code $afterInstallExitCode"
        }

        $stage = "password"
        if (-not [string]::IsNullOrWhiteSpace($Password)) {
            $passwordResult = Invoke-Command -Session $session -ScriptBlock {
                param($Password)
                $uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Gubernia Desktop"
                $installLocation = (Get-ItemProperty -LiteralPath $uninstallKey).InstallLocation
                $exePath = Join-Path $installLocation "Gubernia Desktop.exe"

                if (-not (Test-Path -LiteralPath $exePath)) {
                    throw "Application executable not found: $exePath"
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
                    foreach ($line in Get-Content -LiteralPath $Path) {
                        if ($line -match $pattern) {
                            return $matches[1]
                        }
                    }
                    ""
                }

                function Get-ExpectedPasswordStorage {
                    param(
                        [string]$PlainPassword,
                        [string]$Salt
                    )

                    $sha = [System.Security.Cryptography.SHA256]::Create()
                    try {
                        $bytes = [System.Text.Encoding]::UTF8.GetBytes($PlainPassword + $Salt)
                        "01" + [Convert]::ToBase64String($sha.ComputeHash($bytes))
                    } finally {
                        $sha.Dispose()
                    }
                }

                $taskName = "GuberniaDesktopSetPassword-$([guid]::NewGuid().ToString('N'))"
                $logPath = Join-Path $env:WINDIR "Temp\$taskName.log"
                $exitPath = Join-Path $env:WINDIR "Temp\$taskName.exit"
                Remove-Item -LiteralPath $logPath, $exitPath -Force -ErrorAction SilentlyContinue

                $exeLiteral = $exePath.Replace("'", "''")
                $passwordLiteral = $Password.Replace("'", "''")
                $logLiteral = $logPath.Replace("'", "''")
                $exitLiteral = $exitPath.Replace("'", "''")

                $command = @"
`$ErrorActionPreference = 'Continue'
& '$exeLiteral' --password '$passwordLiteral' *> '$logLiteral'
`$code = if (`$null -eq `$LASTEXITCODE) { 0 } else { [int]`$LASTEXITCODE }
Set-Content -LiteralPath '$exitLiteral' -Value `$code -Encoding ASCII
exit `$code
"@
                $encodedCommand = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($command))
                $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument "-NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedCommand"
                $principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

                try {
                    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
                    Start-ScheduledTask -TaskName $taskName

                    $deadline = (Get-Date).AddSeconds(30)
                    while ((Get-Date) -lt $deadline -and -not (Test-Path -LiteralPath $exitPath)) {
                        Start-Sleep -Milliseconds 500
                    }

                    if (-not (Test-Path -LiteralPath $exitPath)) {
                        throw "Password task did not finish within timeout."
                    }

                    $exitCode = [int](Get-Content -LiteralPath $exitPath -Raw)
                    $output = if (Test-Path -LiteralPath $logPath) {
                        $rawOutput = Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
                        if ($null -eq $rawOutput) { "" } else { $rawOutput.Trim() }
                    } else {
                        ""
                    }

                    if ($exitCode -ne 0) {
                        throw "Password task failed with exit code $exitCode. Output: $output"
                    }

                    $configPath = "C:\Windows\ServiceProfiles\LocalService\AppData\Roaming\Gubernia Desktop\config\Gubernia Desktop.toml"
                    $storage = Get-TomlValue -Path $configPath -Name "password"
                    $salt = Get-TomlValue -Path $configPath -Name "salt"
                    if ([string]::IsNullOrWhiteSpace($storage) -or [string]::IsNullOrWhiteSpace($salt)) {
                        throw "Password was not persisted to $configPath"
                    }

                    $expectedStorage = Get-ExpectedPasswordStorage -PlainPassword $Password -Salt $salt
                    if ($storage -ne $expectedStorage) {
                        throw "Password verification failed in $configPath"
                    }

                    [pscustomobject]@{
                        ExitCode   = $exitCode
                        ExePath    = $exePath
                        ConfigPath = $configPath
                        Output     = $output
                    }
                } finally {
                    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $logPath, $exitPath -Force -ErrorAction SilentlyContinue
                }
            } -ArgumentList $Password

            $passwordExitCode = $passwordResult.ExitCode
            & $emit "[$TargetHost] password verified in $($passwordResult.ConfigPath)"
        }

        $installedExe = Invoke-Command -Session $session -ScriptBlock {
            $uninstallKey = "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\Gubernia Desktop"
            $installLocation = (Get-ItemProperty -LiteralPath $uninstallKey).InstallLocation
            Join-Path $installLocation "Gubernia Desktop.exe"
        }

        $status = "Success"
        & $emit "[$TargetHost] success"
        return [pscustomobject]@{
            ComputerName = $TargetHost
            Status = $status
            Stage = "complete"
            InstallExitCode = $installExitCode
            AfterInstallExitCode = $afterInstallExitCode
            PasswordExitCode = $passwordExitCode
            Removed = ($uninstalled -join "; ")
            ExePath = $installedExe
            LogFile = $remoteLogCopy
            Error = ""
            DurationSec = [int]((Get-Date) - $startTime).TotalSeconds
            Log = @()
        }
    }
    catch {
        $errorText = $_.Exception.Message
        & $emit "[$TargetHost] failed at stage '$stage': $errorText"
        return [pscustomobject]@{
            ComputerName = $TargetHost
            Status = "Failed"
            Stage = $stage
            InstallExitCode = $installExitCode
            AfterInstallExitCode = $afterInstallExitCode
            PasswordExitCode = $passwordExitCode
            Removed = ($uninstalled -join "; ")
            ExePath = $installedExe
            LogFile = $remoteLogCopy
            Error = $errorText
            DurationSec = [int]((Get-Date) - $startTime).TotalSeconds
            Log = @()
        }
    }
    finally {
        if ($session) {
            Remove-PSSession $session
        }
    }
}

if (Get-Command Start-ThreadJob -ErrorAction SilentlyContinue) {
    $jobs = @()
    foreach ($targetHost in $hosts) {
        while (@($jobs | Where-Object State -eq 'Running').Count -ge $ThrottleLimit) {
            Start-Sleep -Milliseconds 250
        }
        Write-RunLog -LogPath $runLog -Message "[$targetHost] queued"
        $jobs += Start-ThreadJob -ArgumentList $targetHost, $msiPathResolved, $Password, $sessionParams, $runDir -ScriptBlock $jobScript
    }

    foreach ($job in $jobs) {
        $jobOutput = @(Receive-Job $job -Wait -AutoRemoveJob)
        foreach ($item in $jobOutput) {
            if ($item.PSObject.Properties.Name -contains "Kind" -and $item.Kind -eq "log") {
                Write-RunLog -LogPath $runLog -Message $item.Text
            }
        }
        $result = $jobOutput | Where-Object {
            -not ($_.PSObject.Properties.Name -contains "Kind" -and $_.Kind -eq "log")
        } | Select-Object -Last 1
        if (-not $result) {
            $result = [pscustomobject]@{
                ComputerName = $job.Name
                Status = "Failed"
                Stage = "thread-job"
                InstallExitCode = $null
                AfterInstallExitCode = $null
                PasswordExitCode = $null
                Removed = ""
                ExePath = ""
                LogFile = ""
                Error = "Thread job returned no result."
                DurationSec = 0
            }
        }
        $results.Add($result)
        if ($result.Status -eq "Success") { $successHosts.Add($result.ComputerName) } else { $failedHosts.Add($result.ComputerName) }
    }
} else {
    foreach ($targetHost in $hosts) {
        $jobOutput = @(& $jobScript $targetHost $msiPathResolved $Password $sessionParams $runDir)
        foreach ($item in $jobOutput) {
            if ($item.PSObject.Properties.Name -contains "Kind" -and $item.Kind -eq "log") {
                Write-RunLog -LogPath $runLog -Message $item.Text
            }
        }
        $result = $jobOutput | Where-Object {
            -not ($_.PSObject.Properties.Name -contains "Kind" -and $_.Kind -eq "log")
        } | Select-Object -Last 1
        $results.Add($result)
        if ($result.Status -eq "Success") { $successHosts.Add($result.ComputerName) } else { $failedHosts.Add($result.ComputerName) }
        if ($result.Error) {
            Write-RunLog -LogPath $runLog -Message "[$targetHost] $($result.Error)"
        }
    }
}

$results | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8
$failedHosts | Set-Content -LiteralPath $localFailedHostsPath -Encoding UTF8
if ($successHosts.Count -gt 0) {
    $successHosts | Set-Content -LiteralPath (Join-Path $runDir "success-hosts.txt") -Encoding UTF8
}

Write-RunLog -LogPath $runLog -Message "Completed. Success: $($successHosts.Count), Failed: $($failedHosts.Count)"
Write-Host "Summary CSV: $summaryCsv"
Write-Host "Run log: $runLog"
Write-Host "Failed hosts: $localFailedHostsPath"

if ($failedHosts.Count -gt 0) {
    exit 1
}
