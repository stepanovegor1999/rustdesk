[CmdletBinding()]
param(
    [string]$ComputerName = "program-2.gubernia.local",
    [string]$Password = $env:GUBERNIA_DESKTOP_PASSWORD,
    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($Password)) {
    throw "Password is required. Pass -Password or set GUBERNIA_DESKTOP_PASSWORD in the current process."
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

    $result = Invoke-Command -Session $session -ScriptBlock {
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
        } finally {
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            Remove-Item -LiteralPath $logPath, $exitPath -Force -ErrorAction SilentlyContinue
        }

        [pscustomobject]@{
            ExitCode   = $exitCode
            ExePath    = $exePath
            ConfigPath = $configPath
            Output     = $output
        }
    } -ArgumentList $Password

    if ($result.ExitCode -ne 0) {
        throw "Password deployment failed on $ComputerName with exit code $($result.ExitCode)."
    }

    Write-Host "Permanent password set successfully on $ComputerName."
    Write-Host "Executable: $($result.ExePath)"
    Write-Host "Config: $($result.ConfigPath)"
}
finally {
    if ($session) {
        Remove-PSSession $session
    }
}
