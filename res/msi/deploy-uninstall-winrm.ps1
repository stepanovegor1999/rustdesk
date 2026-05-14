[CmdletBinding()]
param(
    [string]$ComputerName = "program-2.gubernia.local",
    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

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

        $keys = @(
            "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
            "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
        )

        $app = Get-ItemProperty $keys |
            Where-Object {
                $_.DisplayName -eq "Gubernia Desktop" -or
                $_.DisplayName -like "*RustDesk*" -or
                $_.DisplayName -like "*Gubernia Desktop*"
            } |
            Select-Object -First 1

        if (-not $app) {
            throw "RustDesk/Gubernia Desktop uninstall entry not found."
        }

        if ([string]::IsNullOrWhiteSpace($app.UninstallString)) {
            throw "UninstallString is empty for $($app.DisplayName)."
        }

        $logPath = "C:\Windows\Temp\GuberniaDesktop-uninstall.log"
        $uninstallString = $app.UninstallString

        if ($uninstallString -match 'msiexec') {
            $uninstallString = $uninstallString -replace '(?i)\s/I\s', ' /X '
            $uninstallString = $uninstallString -replace '(?i)\s/I\s', ' /X '
            if ($uninstallString -notmatch '(?i)\s/qn(\s|$)') {
                $uninstallString += ' /qn'
            }
            if ($uninstallString -notmatch '(?i)\s/norestart(\s|$)') {
                $uninstallString += ' /norestart'
            }
            if ($uninstallString -notmatch '(?i)\s/l\*v(\s|$)') {
                $uninstallString += " /l*v `"$logPath`""
            }

            $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c $uninstallString" -Wait -PassThru
            $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
        } else {
            $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$uninstallString`"" -Wait -PassThru
            $exitCode = if ($null -eq $process.ExitCode) { 0 } else { [int]$process.ExitCode }
        }

        [pscustomobject]@{
            DisplayName = $app.DisplayName
            ExitCode    = $exitCode
            LogPath     = $logPath
            Uninstall   = $app.UninstallString
            ConfigRoot  = $appDataRoot
        }
    }

    if ($result.ExitCode -in 0, 3010, 1641) {
        Write-Host "Uninstall completed on $ComputerName."
        Write-Host "Product: $($result.DisplayName)"
        Write-Host "UninstallString: $($result.Uninstall)"
        Write-Host "Config root cleaned: $($result.ConfigRoot)"
        Write-Host "Remote log: $($result.LogPath)"
        if ($result.ExitCode -in 3010, 1641) {
            Write-Warning "Uninstall completed, but a reboot is required (exit code $($result.ExitCode))."
        }
        return
    }

    throw "Uninstall failed on $ComputerName with exit code $($result.ExitCode)."
}
finally {
    if ($session) {
        Remove-PSSession $session
    }
}
