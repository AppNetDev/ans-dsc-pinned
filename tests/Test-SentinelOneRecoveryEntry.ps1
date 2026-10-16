#Requires -Version 5.1
<# .SYNOPSIS
    Verifies the no-parameter IEX entry point without network or agent changes.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$entryPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Repair-SentinelOneAgent.ps1'
$entryText = Get-Content -LiteralPath $entryPath -Raw
$script:Passed = 0
$script:ReturnEmpty = $false
$script:RunnerFails = $false
function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:Passed++
}
function Invoke-WebRequest {
    param([string] $Uri, [switch] $UseBasicParsing, [int] $TimeoutSec)
    if ($Uri -eq 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Repair-SentinelOneAgent.ps1') {
        return $entryText
    }
    Assert-Condition ($Uri -eq 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/examples/dscv3/Invoke-DscV3SentinelOneRepair.ps1') 'Entry must fetch the intended runner revision.'
    Assert-Condition ($UseBasicParsing -and $TimeoutSec -eq 120) 'Download must be noninteractive and bounded.'
    if ($script:ReturnEmpty) { return [pscustomobject]@{ Content = '' } }
    [pscustomobject]@{ Content = @'
[CmdletBinding(SupportsShouldProcess)]
param([string] $Mode, [uri] $SourceBaseUri)
if ($script:RunnerFails) { throw 'Simulated recovery failure.' }
[pscustomobject]@{
    Mode = $Mode
    Source = $SourceBaseUri.AbsoluteUri
    Preview = [bool] $WhatIfPreference
    Confirmation = $ConfirmPreference.ToString()
    BoundParameters = @($PSBoundParameters.Keys)
    Healthy = $true
}
'@ }
}
try {
    # Run as downloaded text: no local checkout can be selected by PSScriptRoot.
    $runnerText = 'caller-value'
    $priorProgress = $ProgressPreference
    $result = Invoke-Expression $entryText
    Assert-Condition ($result.Mode -eq 'Upgrade' -and $result.Healthy -and -not $result.Preview) 'No-parameter IEX must apply MSI recovery and return the result.'
    Assert-Condition ($result.Source -eq 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master') 'Companion source must match the runner revision.'
    Assert-Condition ($result.Confirmation -eq 'None') 'Unattended recovery must suppress confirmation prompts.'
    Assert-Condition (-not ($result.BoundParameters -contains 'SiteToken') -and -not ($result.BoundParameters -contains 'Reenroll')) 'Recovery must not request enrollment changes.'
    Assert-Condition ($runnerText -eq 'caller-value' -and $ProgressPreference -eq $priorProgress) 'IEX must preserve caller variables and preferences.'
    $result = iwr 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master/Repair-SentinelOneAgent.ps1' -UseBasicParsing | iex
    Assert-Condition ($result.Mode -eq 'Upgrade' -and $result.Healthy) 'The documented iwr | iex command must work without parameters.'
    $result = & ([scriptblock]::Create($entryText)) -WhatIf
    Assert-Condition $result.Preview 'WhatIf must reach the recovery runner.'
    $script:ReturnEmpty = $true
    $message = ''
    try { Invoke-Expression $entryText | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Condition ($message -like '*runner was empty*') 'Empty runner downloads must fail.'
    $script:ReturnEmpty = $false
    $script:RunnerFails = $true
    $message = ''
    try { Invoke-Expression $entryText | Out-Null } catch { $message = $_.Exception.Message }
    Assert-Condition ($message -like '*Simulated recovery failure*') 'Recovery failure must propagate to the caller.'
    [pscustomobject]@{ Passed = $script:Passed; Failed = 0; NetworkUsed = $false; AgentModified = $false }
}
finally {
    Remove-Item -LiteralPath Function:\Invoke-WebRequest
}
