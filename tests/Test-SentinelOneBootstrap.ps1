#Requires -Version 5.1
<#
.SYNOPSIS
    Tests downloaded-script execution with simulated GitHub downloads and DSC.
#>
[CmdletBinding()]
param()
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$script:FixtureRepositoryRoot = $repositoryRoot
$runnerText = Get-Content -LiteralPath (Join-Path $repositoryRoot 'examples\dscv3\Invoke-DscV3SentinelOneRepair.ps1') -Raw
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ('ANS-SentinelOneBootstrapTest-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $testRoot
$passed = 0
$script:Downloads = @()
$script:AclCalls = 0
function Assert-Condition {
    param([bool] $Condition, [string] $Message)
    if (-not $Condition) { throw $Message }
    $script:passed++
}
function Set-Acl { param($LiteralPath, $AclObject) $script:AclCalls++ }
function Invoke-WebRequest {
    param([string] $Uri, [string] $OutFile, [switch] $UseBasicParsing, [int] $TimeoutSec)
    $prefix = 'https://example.invalid/repository/pinned-revision/'
    if (-not $Uri.StartsWith($prefix)) { throw 'Unexpected source revision.' }
    $relativePath = $Uri.Substring($prefix.Length)
    $script:Downloads += $relativePath
    if ($relativePath -eq 'Install-SentinelOneAgentDscV3.ps1') {
        # Isolate the main runner's routing from the separately tested MSI wrapper.
        @'
[CmdletBinding(SupportsShouldProcess)]
param($InstallerUri, $Operation, $DscPath, $WorkingDirectory, $SourceBaseUri,
    $HealthTimeoutSeconds, $MsiTimeoutSeconds, $InstallerPath, $ExpectedSha256)
$global:SentinelOneUpgradeRoutingTest = @{} + $PSBoundParameters
'@ | Set-Content -LiteralPath $OutFile
        return
    }
    Copy-Item -LiteralPath (Join-Path $script:FixtureRepositoryRoot $relativePath) -Destination $OutFile
}
function Get-Command {
    param($Name, $CommandType, $ErrorAction)
    if ($Name -ne 'dsc.exe') { throw 'Unexpected command lookup.' }
    [pscustomobject]@{ Source = 'Invoke-TestDsc' }
}
function Invoke-TestDsc {
    [CmdletBinding(PositionalBinding = $false)]
    param(
        [Parameter(ValueFromPipeline)][string] $InputObject,
        [Parameter(ValueFromRemainingArguments)][string[]] $Arguments
    )
    process {
        $script:DscArguments = $Arguments
        $script:DscParameters = $InputObject
        $script:ObservedToken = $env:SENTINELONE_SITE_TOKEN
        $script:ObservedPassphrase = $env:SENTINELONE_AGENT_PASSPHRASE
        $script:ObservedResourcePath = $env:DSC_RESOURCE_PATH
        $global:LASTEXITCODE = 0
    }
}
$oldToken = $env:SENTINELONE_SITE_TOKEN
$oldPassphrase = $env:SENTINELONE_AGENT_PASSPHRASE
$oldResourcePath = $env:DSC_RESOURCE_PATH
try {
    $env:SENTINELONE_SITE_TOKEN = 'prior-token-fixture'
    $env:SENTINELONE_AGENT_PASSPHRASE = 'prior-passphrase-fixture'
    $env:DSC_RESOURCE_PATH = 'prior-resource-fixture'
    $parameters = @{
        SiteToken = 'runtime-token-fixture'
        AgentPassphrase = (ConvertTo-SecureString -String 'runtime-passphrase-fixture' -AsPlainText -Force)
        Reenroll = $true
        RequestId = 'CHG-TEST'
        SourceBaseUri = 'https://example.invalid/repository/pinned-revision'
        WorkingDirectory = $testRoot
        TestOnly = $true
    }
    # Create() mirrors execution of (iwr ...).Content without a script file path.
    & ([scriptblock]::Create($runnerText)) @parameters
    Assert-Condition ($script:Downloads.Count -eq 5) 'Downloaded runner must stage all five companion files.'
    Assert-Condition ($script:AclCalls -eq 1) 'Staging directory must be protected before downloads.'
    Assert-Condition ($script:DscArguments -contains 'test') 'TestOnly must invoke DSC test.'
    Assert-Condition ($script:ObservedToken -eq 'runtime-token-fixture') 'Token parameter must reach the DSC environment.'
    Assert-Condition ($script:ObservedPassphrase -eq 'runtime-passphrase-fixture') 'SecureString passphrase must reach the DSC environment.'
    Assert-Condition ($script:DscParameters -notmatch 'runtime-token|runtime-passphrase') 'DSC parameters must not contain secrets.'
    $parsedParameters = $script:DscParameters | ConvertFrom-Json
    Assert-Condition ($parsedParameters.parameters.Reenroll -and $parsedParameters.parameters.RequestId -eq 'CHG-TEST') 'Bind intent must survive downloaded execution.'
    Assert-Condition ($script:ObservedResourcePath.StartsWith($testRoot)) 'Resource discovery must use the downloaded resource.'
    Assert-Condition ($env:SENTINELONE_SITE_TOKEN -eq 'prior-token-fixture' -and
        $env:SENTINELONE_AGENT_PASSPHRASE -eq 'prior-passphrase-fixture' -and
        $env:DSC_RESOURCE_PATH -eq 'prior-resource-fixture') 'Caller environment must be restored.'
    $parameters.Remove('TestOnly')
    & ([scriptblock]::Create($runnerText)) @parameters -WhatIf
    Assert-Condition ($script:DscArguments -contains 'test') 'WhatIf must invoke read-only DSC test.'
    Assert-Condition ($script:Downloads.Count -eq 10) 'WhatIf must still stage required companion files.'
    $parameters.TestOnly = $true
    $parameters.Remove('RequestId')
    $generatedIds = @()
    foreach ($case in @('Omitted', 'Null', 'Blank')) {
        if ($case -eq 'Null') { $parameters.RequestId = $null }
        if ($case -eq 'Blank') { $parameters.RequestId = '   ' }
        & ([scriptblock]::Create($runnerText)) @parameters
        $requestId = ($script:DscParameters | ConvertFrom-Json).parameters.RequestId
        $parsedGuid = [guid]::Empty
        Assert-Condition ([guid]::TryParse($requestId, [ref] $parsedGuid) -and $parsedGuid -ne [guid]::Empty) "$case RequestId must generate a GUID."
        $generatedIds += $requestId
    }
    Assert-Condition (@($generatedIds | Select-Object -Unique).Count -eq 3) 'Separate invocations must generate different request IDs.'
    $upgradeParameters = @{
        Mode = 'Upgrade'
        InstallerPath = 'C:\ANS\Approved.msi'
        ExpectedSha256 = ('a' * 64)
        TestOnly = $true
        SourceBaseUri = 'https://example.invalid/repository/pinned-revision'
        WorkingDirectory = $testRoot
    }
    $downloadCount = $script:Downloads.Count
    & ([scriptblock]::Create($runnerText)) @upgradeParameters
    Assert-Condition (($script:Downloads.Count - $downloadCount) -eq 9) 'Upgrade mode must download the wrapper and all MSI resource dependencies.'
    Assert-Condition ($global:SentinelOneUpgradeRoutingTest.Operation -eq 'Test') 'Upgrade TestOnly must forward Operation Test.'
    Assert-Condition ($global:SentinelOneUpgradeRoutingTest.InstallerPath -eq 'C:\ANS\Approved.msi' -and
        $global:SentinelOneUpgradeRoutingTest.ExpectedSha256 -eq ('a' * 64)) 'Approved package selection must reach the upgrade wrapper.'
    Assert-Condition (-not $global:SentinelOneUpgradeRoutingTest.ContainsKey('SiteToken') -and
        -not $global:SentinelOneUpgradeRoutingTest.ContainsKey('AgentPassphrase')) 'Upgrade must not forward enrollment credentials.'
    & ([scriptblock]::Create($runnerText)) @upgradeParameters -WhatIf
    Assert-Condition ($global:SentinelOneUpgradeRoutingTest.WhatIf) 'Upgrade must forward WhatIf.'
    $rejected = $false
    try { & ([scriptblock]::Create($runnerText)) @upgradeParameters -Reenroll } catch { $rejected = $_.Exception.Message -like '*Upgrade preserves enrollment*' }
    Assert-Condition $rejected 'Upgrade and Reenroll must not be combined.'
    [pscustomobject]@{ Passed = $passed; Failed = 0; NetworkUsed = $false; AgentModified = $false }
} finally {
    $env:SENTINELONE_SITE_TOKEN = $oldToken
    $env:SENTINELONE_AGENT_PASSPHRASE = $oldPassphrase
    $env:DSC_RESOURCE_PATH = $oldResourcePath
    Remove-Variable -Name SentinelOneUpgradeRoutingTest -Scope Global -ErrorAction SilentlyContinue
    $resolvedRoot = [IO.Path]::GetFullPath($testRoot)
    $expectedParent = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
    if (-not $resolvedRoot.StartsWith($expectedParent, [StringComparison]::OrdinalIgnoreCase) -or
        (Split-Path -Leaf $resolvedRoot) -notlike 'ANS-SentinelOneBootstrapTest-*') { throw 'Unsafe test cleanup path.' }
    Remove-Item -LiteralPath $resolvedRoot -Recurse -Force
}
