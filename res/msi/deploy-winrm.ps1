[CmdletBinding()]
param(
    [string]$ComputerName = "program-2.gubernia.local",
    [string]$MsiPath,
    [string]$Password,
    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($MsiPath)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $MsiPath = Join-Path $scriptRoot "Package\bin\x64\Release\ru-ru\Package.msi"
}

if (-not (Test-Path -LiteralPath $MsiPath)) {
    throw "MSI not found: $MsiPath"
}

$sessionParams = @{
    ComputerName = $ComputerName
}
if ($Credential) {
    $sessionParams.Credential = $Credential
}

$session = $null
try {
    $session = New-PSSession @sessionParams

    $remoteMsiPath = Join-Path $env:WINDIR "Temp\GuberniaDesktop.msi"
    $remoteLogPath = Join-Path $env:WINDIR "Temp\GuberniaDesktop-install.log"
    $localLogPath = Join-Path $env:TEMP ("GuberniaDesktop-{0}-install.log" -f $ComputerName)

    Copy-Item -LiteralPath $MsiPath -Destination $remoteMsiPath -ToSession $session -Force

    $exitCode = Invoke-Command -Session $session -ScriptBlock {
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
        $process.ExitCode
    } -ArgumentList $remoteMsiPath, $remoteLogPath

    try {
        Copy-Item -FromSession $session -LiteralPath $remoteLogPath -Destination $localLogPath -Force
    } catch {
        Write-Warning "Failed to copy remote log back to local host: $($_.Exception.Message)"
    }

    if ($exitCode -in 3010, 1641) {
        Write-Warning "Deployment completed on $ComputerName, but a reboot is required (exit code $exitCode)."
        Write-Host "Local log: $localLogPath"
        return
    }

    if ($exitCode -ne 0) {
        throw "Remote MSI deployment failed with exit code $exitCode. Local log: $localLogPath"
    }

    $afterInstallResult = Invoke-Command -Session $session -ScriptBlock {
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
        $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }

        [pscustomobject]@{
            ExitCode = $exitCode
            ExePath  = $exePath
        }
    }

    if ($afterInstallResult.ExitCode -ne 0) {
        throw "After-install step failed on $ComputerName with exit code $($afterInstallResult.ExitCode)."
    }

    Write-Host "After-install completed on $ComputerName."
    Write-Host "Executable: $($afterInstallResult.ExePath)"

    if (-not [string]::IsNullOrWhiteSpace($Password)) {
        $passwordResult = Invoke-Command -Session $session -ScriptBlock {
            param($Password)

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

        Write-Host "Permanent password set successfully on $ComputerName."
        Write-Host "Executable: $($passwordResult.ExePath)"
        Write-Host "Config: $($passwordResult.ConfigPath)"
    }

    Write-Host "Deployment completed successfully on $ComputerName."
    Write-Host "Local log: $localLogPath"
}
finally {
    if ($session) {
        Remove-PSSession $session
    }
}
