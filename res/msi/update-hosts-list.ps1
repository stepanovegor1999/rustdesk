[CmdletBinding()]
param(
    [string[]]$ComputerName,
    [string]$ComputerListPath,
    [string]$OutputPath,
    [int]$ThrottleLimit = 16,
    [pscredential]$Credential,
    [switch]$IncludeInstalled,
    [switch]$IncludeRustDeskOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
} else {
    $scriptRoot = $PSScriptRoot
}

if ([string]::IsNullOrWhiteSpace($ComputerListPath)) {
    $ComputerListPath = Join-Path $scriptRoot "hosts-source.txt"
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = $ComputerListPath
}

function Get-ExistingHosts {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    return Get-Content -LiteralPath $Path | ForEach-Object { $_.Trim() } | Where-Object {
        $_ -and -not $_.StartsWith("#")
    }
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

function Write-HostList {
    param(
        [string[]]$Hosts,
        [string]$Path
    )

    $existingHosts = Get-ExistingHosts -Path $Path
    $allHosts = ($existingHosts + $Hosts) | Sort-Object -Unique
    $allHosts | Set-Content -LiteralPath $Path -Encoding UTF8
    Write-Host "Updated $Path with $($allHosts.Count) total hosts (added $($Hosts.Count))"
}

$existingHosts = Get-ExistingHosts -Path $ComputerListPath
Write-Host "Existing hosts: $($existingHosts.Count)"

$hostsToCheck = Get-TargetHosts -InlineHosts $ComputerName -ListPath $ComputerListPath
if (-not $hostsToCheck -or $hostsToCheck.Count -eq 0) {
    throw "No target hosts found."
}

Write-Host "Checking $($hostsToCheck.Count) hosts..."

$sessionParams = @{}
if ($Credential) {
    $sessionParams.Credential = $Credential
}

$hostsToAdd = New-Object System.Collections.Generic.List[string]
$checkResults = @{}

$useThreadJob = [bool](Get-Command Start-ThreadJob -ErrorAction SilentlyContinue)

if ($useThreadJob) {
    $jobs = @()
    foreach ($computer in $hostsToCheck) {
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
                $session = New-PSSession -ComputerName $Computer @SessionParams -ErrorAction Stop

                $appInfo = Invoke-Command -Session $session -ScriptBlock {
                    $keys = @(
                        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                    )

                    $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {
                        $_.DisplayName -and (
                            $_.DisplayName -eq "Gubernia Desktop" -or
                            $_.DisplayName -like "*RustDesk*" -or
                            $_.DisplayName -like "*Gubernia Desktop*"
                        )
                    }

                    $hasGubernia = [bool]($apps | Where-Object { $_.DisplayName -eq "Gubernia Desktop" })
                    $hasRustDesk = [bool]($apps | Where-Object { $_.DisplayName -like "*RustDesk*" -and $_.DisplayName -notlike "*Gubernia*" })

                    [pscustomobject]@{
                        HasGubernia = $hasGubernia
                        HasRustDesk = $hasRustDesk
                    }
                }

                [pscustomobject]@{
                    Computer = $Computer
                    HasGubernia = $appInfo.HasGubernia
                    HasRustDesk = $appInfo.HasRustDesk
                    Error = ""
                }
            }
            catch {
                [pscustomobject]@{
                    Computer = $Computer
                    HasGubernia = $false
                    HasRustDesk = $false
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

        $checkResults[$result.Computer] = @{
            HasGubernia = $result.HasGubernia
            HasRustDesk = $result.HasRustDesk
        }

        $shouldAdd = $false

        if (-not $result.HasGubernia) {
            if ($IncludeRustDeskOnly -and $result.HasRustDesk) {
                $shouldAdd = $true
                Write-Host "  has RustDesk only -> will add"
            } elseif (-not $IncludeInstalled -and -not $result.HasGubernia -and -not $result.HasRustDesk) {
                $shouldAdd = $true
                Write-Host "  no installation -> will add"
            } elseif ($IncludeInstalled -and -not $result.HasGubernia) {
                $shouldAdd = $true
                Write-Host "  Gubernia not installed -> will add"
            } else {
                Write-Host "  has Gubernia -> skip"
            }
        } else {
            Write-Host "  has Gubernia -> skip"
        }

        if ($shouldAdd -and $result.Computer -notin $existingHosts) {
            $hostsToAdd.Add($result.Computer)
        }
    }
} else {
    foreach ($computer in $hostsToCheck) {
        Write-Host "Checking $computer ..."
        $session = $null
        try {
            $session = New-PSSession -ComputerName $computer @sessionParams -ErrorAction Stop

            $appInfo = Invoke-Command -Session $session -ScriptBlock {
                $keys = @(
                    "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*",
                    "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*"
                )

                $apps = Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object {
                    $_.DisplayName -and (
                        $_.DisplayName -eq "Gubernia Desktop" -or
                        $_.DisplayName -like "*RustDesk*" -or
                        $_.DisplayName -like "*Gubernia Desktop*"
                    )
                }

                $hasGubernia = [bool]($apps | Where-Object { $_.DisplayName -eq "Gubernia Desktop" })
                $hasRustDesk = [bool]($apps | Where-Object { $_.DisplayName -like "*RustDesk*" -and $_.DisplayName -notlike "*Gubernia*" })

                [pscustomobject]@{
                    HasGubernia = $hasGubernia
                    HasRustDesk = $hasRustDesk
                }
            }

            $checkResults[$computer] = @{
                HasGubernia = $appInfo.HasGubernia
                HasRustDesk = $appInfo.HasRustDesk
            }

            $shouldAdd = $false

            if (-not $appInfo.HasGubernia) {
                if ($IncludeRustDeskOnly -and $appInfo.HasRustDesk) {
                    $shouldAdd = $true
                    Write-Host "  has RustDesk only -> will add"
                } elseif (-not $IncludeInstalled -and -not $appInfo.HasGubernia -and -not $appInfo.HasRustDesk) {
                    $shouldAdd = $true
                    Write-Host "  no installation -> will add"
                } elseif ($IncludeInstalled -and -not $appInfo.HasGubernia) {
                    $shouldAdd = $true
                    Write-Host "  Gubernia not installed -> will add"
                } else {
                    Write-Host "  has Gubernia -> skip"
                }
            } else {
                Write-Host "  has Gubernia -> skip"
            }

            if ($shouldAdd -and $computer -notin $existingHosts) {
                $hostsToAdd.Add($computer)
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

if ($hostsToAdd.Count -gt 0) {
    Write-HostList -Hosts $hostsToAdd.ToArray() -Path $OutputPath
    Write-Host "New hosts added:"
    $hostsToAdd.ToArray() | ForEach-Object { Write-Host "  $_" }
} else {
    Write-Host "No new hosts to add."
}

Write-Host "`nSummary:"
Write-Host "  Existing hosts: $($existingHosts.Count)"
Write-Host "  New hosts added: $($hostsToAdd.Count)"
Write-Host "  Total hosts: $(($existingHosts + $hostsToAdd.ToArray()).Count)"
