#Requires -Version 5.1
<#
.SYNOPSIS
    Recovers an existing SentinelOne agent using the default signed MSI.
.DESCRIPTION
    No parameters or enrollment secrets are required. Uses the MSI upgrade path,
    bootstraps DSC if missing, and returns health, restart, and diagnostic paths.
    A healthy agent at the target version or newer is unchanged. An unhealthy
    agent requires a newer package; same-version reinstall is not forced.
.EXAMPLE
    Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Repair-SentinelOneAgent.ps1' -UseBasicParsing | Invoke-Expression
.EXAMPLE
    .\Repair-SentinelOneAgent.ps1 -WhatIf
.NOTES
    Run elevated or as SYSTEM in 64-bit PowerShell. Preserves enrollment and
    does not restart Windows automatically. Uses the current ConnectWise MSI
    at the default URL, with vendor signature and package metadata validation.
    Logs and staging: C:\ANS\SentinelOneDsc. Verify portal protection afterward.
    WhatIf can download/stage files and requires DSC to be installed already.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param()

# Keep downloaded execution from replacing variables/preferences in the caller.
& {
    Set-StrictMode -Version Latest
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'
    if (-not [Environment]::Is64BitProcess) { throw 'Run recovery in 64-bit PowerShell.' }
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $sourceBaseUri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master'
    $recoveryParameters = @{
        Mode = 'Upgrade'
        SourceBaseUri = $sourceBaseUri
        WhatIf = [bool] $WhatIfPreference
        Confirm = $false
    }
    if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        $localRunner = Join-Path $PSScriptRoot 'examples\dscv3\Invoke-DscV3SentinelOneRepair.ps1'
        if (Test-Path -LiteralPath $localRunner -PathType Leaf) {
            & $localRunner @recoveryParameters
            return
        }
    }

    $runnerText = (Invoke-WebRequest -Uri "$sourceBaseUri/examples/dscv3/Invoke-DscV3SentinelOneRepair.ps1" -UseBasicParsing -TimeoutSec 120).Content
    if ([string]::IsNullOrWhiteSpace($runnerText)) { throw 'Downloaded SentinelOne recovery runner was empty.' }
    & ([scriptblock]::Create($runnerText)) @recoveryParameters
}
