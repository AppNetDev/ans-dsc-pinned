#Requires -Version 5.1
<#
.SYNOPSIS
    Downloads a DSC v3 configuration and applies it with the Pinned DSC v3 resource.
.DESCRIPTION
    DSC v3 expects --file to reference a local file. This example downloads a
    remote YAML configuration to %TEMP%, makes the Pinned DSC v3 resource
    discoverable for this process, and invokes `dsc config set`.
#>
[CmdletBinding()]
param(
    [string] $ConfigurationUri = 'https://raw.githubusercontent.com/AppNetOnline/ans-dsc-pinned/feature/dsc-v3-resource/.configurations/firefox-dscv3.yaml',

    [string] $ResourcePath,

    [string] $DestinationPath = (Join-Path $env:TEMP 'ans-configure.yaml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ResourcePath)) {
    $repoResourcePath = if (-not [string]::IsNullOrWhiteSpace($PSScriptRoot)) {
        Join-Path $PSScriptRoot '..\Pinned\DSCv3'
    } else {
        $null
    }

    $installedResourcePath = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Pinned\DSCv3'

    if ($repoResourcePath -and (Test-Path -LiteralPath $repoResourcePath)) {
        $ResourcePath = $repoResourcePath
    } elseif (Test-Path -LiteralPath $installedResourcePath) {
        $ResourcePath = $installedResourcePath
    } else {
        throw 'Pinned DSC v3 resource path was not specified and could not be found. Pass -ResourcePath or install the Pinned module first.'
    }
}

$resolvedResourcePath = (Resolve-Path -LiteralPath $ResourcePath).Path
$env:DSC_RESOURCE_PATH = $resolvedResourcePath

Invoke-WebRequest -Uri $ConfigurationUri -OutFile $DestinationPath -UseBasicParsing

$dscArgs = @(
    'config'
    'set'
    '--file'
    $DestinationPath
)

dsc @dscArgs
