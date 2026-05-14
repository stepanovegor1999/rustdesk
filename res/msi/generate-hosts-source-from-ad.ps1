[CmdletBinding()]
param(
    [string]$DomainName = "gubernia.local",
    [string]$SearchBase,
    [string]$OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $scriptRoot = $PSScriptRoot
    if ([string]::IsNullOrWhiteSpace($scriptRoot)) {
        $scriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
    }
    $OutputPath = Join-Path $scriptRoot "hosts-source.txt"
}

if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
    throw "ActiveDirectory module is not available. Install RSAT or run on a host with the AD module."
}

Import-Module ActiveDirectory

$params = @{
    Filter = '*'
    Properties = @('DNSHostName', 'Enabled')
}

if (-not [string]::IsNullOrWhiteSpace($SearchBase)) {
    $params.SearchBase = $SearchBase
}

$computers = Get-ADComputer @params |
    Where-Object {
        $_.Enabled -and
        -not [string]::IsNullOrWhiteSpace($_.DNSHostName) -and
        $_.DNSHostName.EndsWith($DomainName, [System.StringComparison]::OrdinalIgnoreCase)
    } |
    Sort-Object DNSHostName -Unique |
    Select-Object -ExpandProperty DNSHostName

if (-not $computers -or $computers.Count -eq 0) {
    throw "No enabled AD computers with DNSHostName matching $DomainName were found."
}

$computers | Set-Content -LiteralPath $OutputPath -Encoding UTF8
Write-Host "Wrote $($computers.Count) hosts to $OutputPath"
