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

    [string] $ResourcePath = (Join-Path $PSScriptRoot '..\Pinned\DSCv3'),

    [string] $DestinationPath = (Join-Path $env:TEMP 'ans-configure.yaml')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$resolvedResourcePath = (Resolve-Path -LiteralPath $ResourcePath).Path
$env:PATH = "$resolvedResourcePath;$env:PATH"

Invoke-WebRequest -Uri $ConfigurationUri -OutFile $DestinationPath -UseBasicParsing

$dscArgs = @(
    'config'
    'set'
    '--file'
    $DestinationPath
)

dsc @dscArgs
