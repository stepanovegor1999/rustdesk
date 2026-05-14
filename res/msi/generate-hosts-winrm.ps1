[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ComputerListPath = (Join-Path $PSScriptRoot "hosts-source.txt"),
    [string]$OutputPath,
    [int]$ThrottleLimit = 16,
    [pscredential]$Credential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $OutputPath = Join-Path $scriptRoot "hosts.txt"
}

function Get-TargetHosts {
    param(
        [string[]]$InlineHosts,
        [string]$ListPath
    )

    if ($InlineHosts -and $InlineHosts.Count -gt 0) {
        return $InlineHosts | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }

    if (-not (Test-Path -LiteralPath $ListPath)) {
        throw "Host source file not found: $ListPath"
    }

    return Get-Content -LiteralPath $ListPath | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -and -not $_.StartsWith("#")
    }
}

$hosts = Get-TargetHosts -InlineHosts $ComputerName -ListPath $ComputerListPath
if (-not $hosts -or $hosts.Count -eq 0) {
    throw "No target hosts found."
}

$sessionParams = @{}
if ($Credential) {
    $sessionParams.Credential = $Credential
}

$installedHosts = New-Object System.Collections.Generic.List[string]

$useThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)
if ($useThreadJob) {
    $jobs = @()
    foreach ($computer in $hosts) {
        while (@($jobs | Where-Object State -eq 'Running').Count -ge $ThrottleLimit) {
            Start-Sleep -Milliseconds 250
        }

        Write-Host "Checking $computer ..."
        $jobs += Start-ThreadJob -ArgumentList $computer, ($sessionParams | ConvertTo-Json -Compress) -ScriptBlock {
            param($Computer, $SessionParamsJson)

            $SessionParams = if ([string]::IsNullOrWhiteSpace($SessionParamsJson)) {
                @{}
            } else {
                $SessionParamsJson | ConvertFrom-Json -AsHashtable
            }

            $session = $null
            try {
                $session = New-PSSession -ComputerName $Computer @SessionParams

                $isInstalled = Invoke-Command -Session $session -ScriptBlock {
                    $keys = @(
                        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                    )

                    $app = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                        Where-Object {
                            $_.DisplayName -eq "Gubernia Desktop" -or
                            $_.DisplayName -like "*RustDesk*" -or
                            $_.DisplayName -like "*Gubernia Desktop*"
                        } |
                        Select-Object -First 1

                    [bool]$app
                }

                [pscustomobject]@{
                    Computer = $Computer
                    Installed = [bool]$isInstalled
                    Error = ""
                }
            }
            catch {
                [pscustomobject]@{
                    Computer = $Computer
                    Installed = $false
                    Error = $_.Exception.Message
                }
            }
            finally {
                if ($session) {
                    Remove-PSSession $session
                }
            }
        }
    }

    foreach ($job in $jobs) {
        $result = Receive-Job $job -Wait -AutoRemoveJob
        if ($result.Error) {
            Write-Warning "Failed to check $($result.Computer): $($result.Error)"
            continue
        }

        if ($result.Installed) {
            $installedHosts.Add($result.Computer)
            Write-Host "  installed"
        } else {
            Write-Host "  not installed"
        }
    }
} else {
    foreach ($computer in $hosts) {
        Write-Host "Checking $computer ..."
        $session = $null
        try {
            $session = New-PSSession -ComputerName $computer @sessionParams

            $isInstalled = Invoke-Command -Session $session -ScriptBlock {
                $keys = @(
                    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                )

                $app = Get-ItemProperty $keys -ErrorAction SilentlyContinue |
                    Where-Object {
                        $_.DisplayName -eq "Gubernia Desktop" -or
                        $_.DisplayName -like "*RustDesk*" -or
                        $_.DisplayName -like "*Gubernia Desktop*"
                    } |
                    Select-Object -First 1

                [bool]$app
            }

            if ($isInstalled) {
                $installedHosts.Add($computer)
                Write-Host "  installed"
            } else {
                Write-Host "  not installed"
            }
        }
        catch {
            Write-Warning "Failed to check ${computer}: $($_.Exception.Message)"
        }
        finally {
            if ($session) {
                Remove-PSSession $session
            }
        }
    }
}

$installedHosts | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Wrote $($installedHosts.Count) hosts to $OutputPath"
