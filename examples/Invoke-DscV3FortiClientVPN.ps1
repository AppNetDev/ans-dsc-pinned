#Requires -Version 5.1
<#
.SYNOPSIS
    Installs the Pinned DSC v3 resource package and applies the FortiClient VPN config.
.EXAMPLE
    irm "https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Invoke-DscV3FortiClientVPN.ps1" | iex
#>
[CmdletBinding()]
param(
    [string] $ConfigurationUri = 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/.configurations/forticlientvpn-dscv3.yaml',

    [string] $BootstrapUri = 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/examples/Install-PinnedDscV3.ps1',

    [string] $ResourcePackageUri = 'https://github.com/AppNetOnline/ans-dsc-pinned/releases/latest/download/Pinned.DSCv3.zip',

    [string] $ResourcePackagePath,

    [ValidateSet('CurrentUser', 'AllUsers')]
    [string] $Scope = 'CurrentUser',

    [switch] $PersistDscPath,

    [switch] $SkipDscInstall
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$bootstrapParameters = @{
    ConfigurationUri = $ConfigurationUri
    ResourcePackageUri = $ResourcePackageUri
    Scope = $Scope
    PersistDscPath = $PersistDscPath
    SkipDscInstall = $SkipDscInstall
}

if ($ResourcePackagePath) {
    $bootstrapParameters.ResourcePackagePath = $ResourcePackagePath
}

$localBootstrap = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
    Join-Path $PSScriptRoot 'Install-PinnedDscV3.ps1'
} else {
    $null
}

if ($localBootstrap -and (Test-Path -LiteralPath $localBootstrap)) {
    & $localBootstrap @bootstrapParameters
    return
}

$bootstrapScript = Invoke-RestMethod -Uri $BootstrapUri
& ([scriptblock]::Create($bootstrapScript)) @bootstrapParameters
