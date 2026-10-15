#Requires -Version 5.1
<#
.SYNOPSIS
    Applies the SentinelOne repair DSC v3 configuration with runtime secrets.
.DESCRIPTION
    Supports local checkout execution or execution of content fetched from GitHub.
    Downloads companion files when no local checkout is available, and installs
    standalone DSC under C:\ANS\DSC if dsc.exe is not already available.
    Installs from MSI only if the service or agent/control binaries are missing.
    Otherwise restores Automatic startup and Running state. Reenroll explicitly binds
    once per RequestId; change RequestId to authorize another bind, including token changes.
.PARAMETER SiteToken
    Site token, or SENTINELONE_SITE_TOKEN from this process environment.
.PARAMETER AgentPassphrase
    Optional existing-agent passphrase; otherwise uses SENTINELONE_AGENT_PASSPHRASE.
.PARAMETER Reenroll
    Explicitly requests a bind. Verify the existing console association before using.
.PARAMETER RequestId
    Optional non-secret change/ticket ID. With Reenroll, an omitted, null, or blank
    value generates a new GUID for this invocation. Supply a stable ID to reuse on retries.
.PARAMETER TestOnly
    Runs DSC test without agent changes. Companion files / missing DSC may be downloaded.
.PARAMETER SourceBaseUri
    Raw GitHub repository root including branch, tag, or commit. Use the same revision
    for this runner and its companion files.
.PARAMETER WorkingDirectory
    Parent directory for unique, protected staging directories.
.PARAMETER Mode
    Repair restores service state / optionally binds. Upgrade uses the MSI resource
    to upgrade an existing agent without direct service configuration or ACL changes.
.PARAMETER InstallerPath
    Optional local approved MSI for Upgrade. Otherwise InstallerUri is downloaded.
.PARAMETER ExpectedSha256
    Optional trusted package hash for Upgrade. Signature validation is always required.
.EXAMPLE
    .\Invoke-DscV3SentinelOneRepair.ps1 -SiteToken $SiteToken
.EXAMPLE
    .\Invoke-DscV3SentinelOneRepair.ps1 -SiteToken $SiteToken -Reenroll -RequestId 'CHG-12345' -AgentPassphrase $Passphrase
.EXAMPLE
    .\Invoke-DscV3SentinelOneRepair.ps1 -Mode Upgrade -TestOnly
.EXAMPLE
    .\Invoke-DscV3SentinelOneRepair.ps1 -Mode Upgrade -InstallerPath $ApprovedMsiPath -ExpectedSha256 $ApprovedSha256
.NOTES
    Secrets are scoped to the child process environment and restored afterward. Native
    MSI/SentinelCtl arguments can still be captured by privileged process auditing.
    No uninstall, protection unload, or automatic reboot. Logs: C:\ANS\SentinelOne\Logs.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'Medium')]
param(
    [ValidateSet('Repair', 'Upgrade')][string] $Mode = 'Repair',
    [string] $SiteToken = $env:SENTINELONE_SITE_TOKEN,
    [securestring] $AgentPassphrase,
    [switch] $Reenroll,
    [string] $RequestId = '',
    [uri] $InstallerUri = 'https://cwa.connectwise.com/tools/sentinelone/SentinelOneAgent-Windows_64bit.msi',
    [string] $InstallerPath,
    [ValidatePattern('^[a-fA-F0-9]{64}$')][string] $ExpectedSha256,
    [ValidateRange(5, 300)][int] $HealthTimeoutSeconds = 60,
    [ValidateRange(30, 7200)][int] $MsiTimeoutSeconds = 900,
    [switch] $TestOnly,
    [uri] $SourceBaseUri = 'https://raw.githubusercontent.com/AppNetDev/ans-dsc-pinned/master',
    [ValidateNotNullOrEmpty()]
    [string] $WorkingDirectory = 'C:\ANS\SentinelOneDsc'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Initialize-SentinelOneDscSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $BaseUri,
        [Parameter(Mandatory)][string] $DestinationRoot
    )
    # Staging is required for a read-only DSC preview as well as for apply.
    $WhatIfPreference = $false
    $ConfirmPreference = 'None'
    if ($BaseUri.Scheme -ne 'https') { throw 'SourceBaseUri must use HTTPS.' }
    $root = Join-Path $DestinationRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $root -Force
    $acl = New-Object Security.AccessControl.DirectorySecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $rule = New-Object Security.AccessControl.FileSystemAccessRule(
            (New-Object Security.Principal.SecurityIdentifier($sid)), 'FullControl',
            'ContainerInherit,ObjectInherit', 'None', 'Allow')
        $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $root -AclObject $acl
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $relativePaths = @(
        'dscv3/SentinelOne.Repair.ps1',
        'dscv3/SentinelOne.Repair.cmd',
        'dscv3/SentinelOne.Repair.dsc.resource.json',
        '.configurations/dscv3/sentinelone-repair-dscv3.yaml',
        'examples/dscv3/Install-DscV3Standalone.ps1'
    )
    if ($Mode -eq 'Upgrade') {
        $relativePaths += @(
            'Install-SentinelOneAgentDscV3.ps1',
            'dscv3/SentinelOne.Msi.ps1',
            'dscv3/SentinelOne.Msi.Functions.ps1',
            'dscv3/SentinelOne.Msi.dsc.resource.json'
        )
    }
    foreach ($relativePath in $relativePaths) {
        $destination = Join-Path $root $relativePath
        $null = New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force
        $downloadParameters = @{
            Uri = $BaseUri.AbsoluteUri.TrimEnd('/') + '/' + $relativePath
            OutFile = $destination
            UseBasicParsing = $true
            TimeoutSec = 120
        }
        Invoke-WebRequest @downloadParameters
        if (-not (Test-Path -LiteralPath $destination -PathType Leaf) -or
            (Get-Item -LiteralPath $destination).Length -eq 0) { throw "Companion download was empty: $relativePath" }
    }
    return $root
}

if ($Mode -eq 'Upgrade' -and $Reenroll) { throw 'Upgrade preserves enrollment. Run a separate explicit Repair/Reenroll only after the agent is healthy.' }
if ($Mode -eq 'Repair' -and ($InstallerPath -or $ExpectedSha256)) { throw 'InstallerPath and ExpectedSha256 require Mode Upgrade.' }
if ($Reenroll -and [string]::IsNullOrWhiteSpace($RequestId)) {
    $RequestId = [guid]::NewGuid().ToString('D')
}
if ($InstallerUri.Scheme -ne 'https') { throw 'InstallerUri must use HTTPS.' }
if ($SourceBaseUri.Scheme -ne 'https') { throw 'SourceBaseUri must use HTTPS.' }
$repositoryRoot = $null
if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    $candidateRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
    if (-not [string]::IsNullOrWhiteSpace($candidateRoot)) {
        $requiredFiles = @(
            'dscv3\SentinelOne.Repair.ps1',
            'dscv3\SentinelOne.Repair.cmd',
            'dscv3\SentinelOne.Repair.dsc.resource.json',
            '.configurations\dscv3\sentinelone-repair-dscv3.yaml',
            'examples\dscv3\Install-DscV3Standalone.ps1'
        )
        if ($Mode -eq 'Upgrade') {
            $requiredFiles += @(
                'Install-SentinelOneAgentDscV3.ps1',
                'dscv3\SentinelOne.Msi.ps1',
                'dscv3\SentinelOne.Msi.Functions.ps1',
                'dscv3\SentinelOne.Msi.dsc.resource.json'
            )
        }
        $missingFiles = @($requiredFiles | Where-Object { -not (Test-Path -LiteralPath (Join-Path $candidateRoot $_) -PathType Leaf) })
        if ($missingFiles.Count -eq 0) { $repositoryRoot = $candidateRoot }
    }
}
if ([string]::IsNullOrWhiteSpace($repositoryRoot)) {
    $repositoryRoot = Initialize-SentinelOneDscSource -BaseUri $SourceBaseUri -DestinationRoot $WorkingDirectory
}
$resourceDirectory = Join-Path $repositoryRoot 'dscv3'
$configurationPath = Join-Path $repositoryRoot '.configurations\dscv3\sentinelone-repair-dscv3.yaml'
$dscCommand = Get-Command -Name dsc.exe -CommandType Application -ErrorAction SilentlyContinue
if ($null -eq $dscCommand) {
    $dscPath = 'C:\ANS\DSC\dsc.exe'
    if (-not (Test-Path -LiteralPath $dscPath -PathType Leaf)) {
        if ($WhatIfPreference) { throw 'DSC is missing. Install DSC first, or run without WhatIf to bootstrap it.' }
        & (Join-Path $repositoryRoot 'examples\dscv3\Install-DscV3Standalone.ps1') -Scope AllUsers -InstallDirectory 'C:\ANS\DSC' | Out-Null
        if (-not (Test-Path -LiteralPath $dscPath -PathType Leaf)) { throw 'DSC bootstrap did not produce dsc.exe.' }
    }
} else {
    $dscPath = $dscCommand.Source
}
if ($Mode -eq 'Upgrade') {
    $upgradeParameters = @{
        InstallerUri = $InstallerUri
        Operation = $(if ($TestOnly) { 'Test' } else { 'Set' })
        DscPath = $dscPath
        WorkingDirectory = $WorkingDirectory
        SourceBaseUri = $SourceBaseUri
        HealthTimeoutSeconds = $HealthTimeoutSeconds
        MsiTimeoutSeconds = $MsiTimeoutSeconds
        WhatIf = [bool] $WhatIfPreference
    }
    if ($InstallerPath) { $upgradeParameters.InstallerPath = $InstallerPath }
    if ($ExpectedSha256) { $upgradeParameters.ExpectedSha256 = $ExpectedSha256 }
    & (Join-Path $repositoryRoot 'Install-SentinelOneAgentDscV3.ps1') @upgradeParameters
    return
}
$oldToken = $env:SENTINELONE_SITE_TOKEN
$oldPassphrase = $env:SENTINELONE_AGENT_PASSPHRASE
$oldResourcePath = $env:DSC_RESOURCE_PATH
try {
    $env:SENTINELONE_SITE_TOKEN = $SiteToken
    if ($null -ne $AgentPassphrase) {
        $env:SENTINELONE_AGENT_PASSPHRASE = (New-Object Management.Automation.PSCredential('SentinelOne', $AgentPassphrase)).GetNetworkCredential().Password
    }
    $env:DSC_RESOURCE_PATH = $resourceDirectory
    if (-not [string]::IsNullOrWhiteSpace($oldResourcePath)) { $env:DSC_RESOURCE_PATH += ";$oldResourcePath" }
    $parameters = @{ parameters = @{ Reenroll = [bool] $Reenroll; RequestId = $RequestId; InstallerUri = $InstallerUri.AbsoluteUri } } | ConvertTo-Json -Depth 4 -Compress
    $operation = 'test'
    if (-not $TestOnly -and $PSCmdlet.ShouldProcess($env:COMPUTERNAME, 'Apply SentinelOne recovery configuration')) { $operation = 'set' }
    $parameters | & $dscPath config --parameters-file - $operation --file $configurationPath
    if ($LASTEXITCODE -ne 0) { throw "DSC $operation failed (exit $LASTEXITCODE)." }
} finally {
    $env:SENTINELONE_SITE_TOKEN = $oldToken
    $env:SENTINELONE_AGENT_PASSPHRASE = $oldPassphrase
    $env:DSC_RESOURCE_PATH = $oldResourcePath
}
